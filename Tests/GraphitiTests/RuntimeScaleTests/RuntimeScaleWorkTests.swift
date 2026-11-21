import Graphiti
import GraphQL
import Testing

/// Counts the evaluations of the native `Query` field thunk. Every evaluation
/// of the runtime root-field chain bottoms out in it, so it also counts those.
private final class EvaluationCounter {
    var nativeQueryEvaluations = 0
}

/// Construction work must grow linearly with the schema. Nothing here times
/// anything; it counts what the builder does.
@Suite struct RuntimeScaleWorkTests {
    private struct Work {
        let targets: Int
        let types: Int
        let nativeQueryEvaluations: Int
        let counts: RuntimeSchemaBuilder.WorkCounts
    }

    private func work(_ n: Int) throws -> Work {
        let counter = EvaluationCounter()
        var shape = SyntheticRuntimeSchema.sized(n)
        shape.nativeRootFields = n / 4
        var builder: RuntimeSchemaBuilder?
        let counted: FieldComponent<SyntheticRoot, NoContext> = RuntimeField("counted") { types in
            counter.nativeQueryEvaluations += 1
            return GraphQLField(type: try types.output("SynthObj0"))
        }
        let native: [FieldComponent<SyntheticRoot, NoContext>] = (0 ..< shape.nativeRootFields).map {
            Field("native\($0)", at: SyntheticRoot.native)
        }
        let fields = { native + [counted] }
        let schema = try SchemaBuilder(SyntheticRoot.self, NoContext.self)
            .add { Type(SyntheticNative.self, as: "Native") { Field("id", at: \.id) } }
            .addQuery(fields)
            .build(runtime: { runtime in
                builder = runtime
                try shape.install(into: runtime)
                // As many lookups as root fields, as a resource engine
                // resolving each field's type by name might make.
                for i in 0 ..< n { _ = try runtime.types.named("SynthObj\(i % shape.objectTypes)") }
            })
        #expect(schema.appliedDirectives.count >= shape.directiveTargetCount)
        let types = shape.objectTypes + shape.enums + shape.inputs + 4 // scalar, interface, union, Native
        return Work(
            targets: shape.directiveTargetCount, types: types,
            nativeQueryEvaluations: counter.nativeQueryEvaluations,
            counts: try #require(builder).workCounts
        )
    }

    @Test func rootFieldChainIsEvaluatedAConstantNumberOfTimes() throws {
        let small = try work(100)
        let large = try work(800)
        // Before: once per root-field or root-argument target, plus schema
        // construction's own evaluation.
        #expect(small.nativeQueryEvaluations == large.nativeQueryEvaluations)
        #expect(large.nativeQueryEvaluations <= 3)
    }

    @Test func locatingTargetsEvaluatesEachTypeAtMostOnce() throws {
        for n in [100, 200, 400, 800] {
            let work = try work(n)
            // Object, interface and input types plus the two runtime roots.
            #expect(work.counts.fieldMapEvaluations <= work.types + 2)
            #expect(work.counts.fieldMapEvaluations < work.targets / 4)
        }
    }

    @Test func lookupsShareTheIndexInsteadOfRereadingTheTypeList() throws {
        for n in [100, 400] {
            // n lookups through `runtime.types`, a RuntimeField evaluation and
            // n/4-odd `addType` duplicate checks: only schema construction's
            // own read of the list remains. Rebuilding per lookup reads it
            // once per lookup.
            #expect(try work(n).counts.typeListReads == 1)
        }
    }

    @Test func typeIndexGrowsWithTypesNotLookups() throws {
        let sizes = [100, 200, 400, 800]
        let runs = try sizes.map { try work($0) }
        for run in runs {
            // Each type is indexed once (the federated query can append a few).
            #expect(run.counts.typeIndexInsertions <= run.types + 4)
        }
        // Doubling the schema at most doubles the work, give or take a constant.
        for (smaller, larger) in zip(runs, runs.dropFirst()) {
            #expect(larger.counts.typeIndexInsertions <= 2 * smaller.counts.typeIndexInsertions + 8)
            #expect(larger.counts.fieldMapEvaluations <= 2 * smaller.counts.fieldMapEvaluations + 8)
        }
    }
}
