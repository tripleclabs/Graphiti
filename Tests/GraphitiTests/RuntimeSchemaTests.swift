import Foundation
import Graphiti
import GraphQL
import Testing

private struct RuntimeNative: Codable, Sendable { let name: String }
private struct RuntimeRecord: Sendable { let title: String }
private struct RuntimeResolver: Sendable {
    func native(context: NoContext, arguments: NoArguments) -> RuntimeNative { .init(name: "native") }
}

@Suite struct RuntimeSchemaTests {
    @Test func executesRelationshipsInBothDirectionsAndPreservesDirectives() async throws {
        let schema = try Schema<RuntimeResolver, NoContext>(runtime: { runtime in
            let native = try runtime.types.output("Native")
            let dynamic = try GraphQLObjectType(name: "Dynamic", fields: [
                "title": GraphQLField(type: GraphQLNonNull(GraphQLString), resolve: { source, _, _, _ in
                    (source as? RuntimeRecord)?.title
                }),
                "native": GraphQLField(type: native, resolve: { _, _, _, _ in RuntimeNative(name: "adapted") }),
            ])
            try runtime.addType(dynamic)
            try runtime.addQueryField("dynamic", field: GraphQLField(type: dynamic, resolve: { _, _, _, _ in RuntimeRecord(title: "root") }))
            try runtime.apply([AppliedDirective(name: "topic", arguments: [("name", "runtime")])], at: .type("Dynamic"))
        }) {
            Directive("topic", on: .object) { DirectiveArgument("name", at: String.self) }
            Type(RuntimeNative.self, as: "Native") {
                Field("name", at: \.name)
                RuntimeField("dynamic") { types in
                    GraphQLField(type: try types.output("Dynamic"), resolve: { source, _, _, _ in
                        guard let native = source as? RuntimeNative else { throw GraphQLError(message: "Wrong native source") }
                        return RuntimeRecord(title: native.name + " child")
                    })
                }
            }
            Query { Field("native", at: RuntimeResolver.native) }
        }
        let result = try await schema.execute(request: "{ native { name dynamic { title native { name } } } dynamic { title native { name } } }", resolver: RuntimeResolver(), context: NoContext())
        #expect(result.errors.isEmpty)
        #expect(result.data == [
            "native": ["name": "native", "dynamic": ["title": "native child", "native": ["name": "adapted"]]],
            "dynamic": ["title": "root", "native": ["name": "adapted"]],
        ])
        #expect(schema.sdl().contains("type Dynamic @topic(name: \"runtime\")"))
        #expect(schema.appliedDirectives[.type("Dynamic")]?.count == 1)
    }

    @Test func dynamicOnlySchemaAndMutation() async throws {
        let schema = try Schema<RuntimeResolver, NoContext>(components: [], runtime: { runtime in
            try runtime.addQueryField("hello", field: GraphQLField(type: GraphQLString, resolve: { _, _, _, _ in "hello" }))
            try runtime.addMutationField("echo", field: GraphQLField(type: GraphQLString, args: ["text": GraphQLArgument(type: GraphQLString)], resolve: { _, args, _, _ in args["text"] }))
        })
        let result = try await schema.execute(request: "mutation { echo(text: \"hi\") }", resolver: RuntimeResolver(), context: NoContext())
        #expect(result.errors.isEmpty)
        #expect(result.data == ["echo": "hi"])
    }

    @Test func rejectsDuplicateNativeFieldsTypesAndBuiltins() throws {
        #expect(throws: (any Error).self) {
            try Schema<RuntimeResolver, NoContext>(runtime: { runtime in
                try runtime.addQueryField("native", field: GraphQLField(type: GraphQLString))
            }) {
                Type(RuntimeNative.self) { Field("name", at: \.name) }
                Query { Field("native", at: RuntimeResolver.native) }
            }
        }
        #expect(throws: (any Error).self) {
            try Schema<RuntimeResolver, NoContext>(runtime: { runtime in
                try runtime.addType(GraphQLObjectType(name: "Native", fields: ["other": GraphQLField(type: GraphQLString)]))
            }) {
                Type(RuntimeNative.self, as: "Native") { Field("name", at: \.name) }
                Query { Field("native", at: RuntimeResolver.native) }
            }
        }
        #expect(throws: (any Error).self) {
            try Schema<RuntimeResolver, NoContext>(components: [], runtime: { try $0.addType(GraphQLString) })
        }
    }

    @Test func rejectsUnknownAndNativeOwnedDirectiveTargets() throws {
        #expect(throws: (any Error).self) {
            try Schema<RuntimeResolver, NoContext>(runtime: { runtime in
                try runtime.apply([AppliedDirective(name: "deprecated")], at: .member(type: "Native", member: "name"))
            }) {
                Type(RuntimeNative.self, as: "Native") { Field("name", at: \.name) }
                Query { Field("native", at: RuntimeResolver.native) }
            }
        }
        #expect(throws: (any Error).self) {
            try Schema<RuntimeResolver, NoContext>(components: [], runtime: { runtime in
                try runtime.addType(GraphQLObjectType(name: "Dynamic", fields: ["name": GraphQLField(type: GraphQLString)]))
                try runtime.addQueryField("hello", field: GraphQLField(type: GraphQLString))
                try runtime.apply([AppliedDirective(name: "deprecated")], at: .member(type: "Dynamic", member: "missing"))
            })
        }
    }

    @Test func validatesRuntimeDirectiveValuesAndLocations() throws {
        #expect(throws: (any Error).self) {
            try Schema<RuntimeResolver, NoContext>(components: [], runtime: { runtime in
                try runtime.addQueryField("hello", field: GraphQLField(type: GraphQLString))
                try runtime.apply([AppliedDirective(name: "deprecated", arguments: [("reason", 42)])], at: .member(type: "Query", member: "hello"))
            })
        }
        #expect(throws: (any Error).self) {
            try Schema<RuntimeResolver, NoContext>(components: [], runtime: { runtime in
                try runtime.addQueryField("hello", field: GraphQLField(type: GraphQLString))
                try runtime.apply([AppliedDirective(name: "skip", arguments: [("if", true)])], at: .member(type: "Query", member: "hello"))
            })
        }
    }

    @Test func builderSupportsRuntimeAndConstructionScopeCloses() throws {
        var escaped: RuntimeSchemaBuilder?
        let schema = try SchemaBuilder(RuntimeResolver.self, NoContext.self).build(runtime: { runtime in
            escaped = runtime
            try runtime.addQueryField("hello", field: GraphQLField(type: GraphQLString))
        })
        #expect(schema.schema.queryType?.name == "Query")
        #expect(throws: (any Error).self) { try escaped?.addQueryField("late", field: GraphQLField(type: GraphQLString)) }
    }

    @Test func lookupPreservesNativeScalarIdentity() throws {
        let schema = try Schema<RuntimeResolver, NoContext>(components: [], runtime: { runtime in
            let type = try runtime.types.output("String")
            #expect((type as? GraphQLScalarType) === GraphQLString)
            #expect(throws: (any Error).self) { try runtime.types.named("Missing") }
            try runtime.addQueryField("hello", field: GraphQLField(type: type))
        })
        #expect((schema.schema.getType(name: "String") as? GraphQLScalarType) === GraphQLString)
    }
    @Test func runtimeFieldsRetainNativeCustomScalarCoercion() async throws {
        let id = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
        let schema = try Schema<RuntimeResolver, NoContext>(runtime: { runtime in
            try runtime.addQueryField("id", field: GraphQLField(type: try runtime.types.output("UUID"), resolve: { _, _, _, _ in id }))
        }) {
            Scalar(UUID.self, as: "UUID")
        }
        let result = try await schema.execute(request: "{ id }", resolver: RuntimeResolver(), context: NoContext())
        #expect(result.errors.isEmpty)
        #expect(result.data == ["id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"])
    }

    @Test func preservesOriginalBuilderMethodReference() throws {
        let builder = SchemaBuilder(RuntimeResolver.self, NoContext.self)
        let build: () throws -> Schema<RuntimeResolver, NoContext> = builder.build
        // Empty schema still fails through the original zero-argument entry point.
        #expect(throws: (any Error).self) { try build() }
    }

}
