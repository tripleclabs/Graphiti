import Foundation
import Dispatch
import Graphiti
import GraphQL

private struct BenchmarkContext: Sendable {}

private struct BenchmarkItem: Sendable {
    let id: Int
    let name: String
    let score: Double
    let active: Bool
}

private struct ItemArguments: Codable, Sendable {
    let id: Int
}

private struct BenchmarkResolver: Sendable {
    let value = "Graphiti"
    let items: [BenchmarkItem]

    init(itemCount: Int) {
        items = (0 ..< itemCount).map {
            BenchmarkItem(
                id: $0,
                name: "Item \($0)",
                score: Double($0) / 10,
                active: $0.isMultiple(of: 2)
            )
        }
    }

    func syncValue(context _: BenchmarkContext, arguments _: NoArguments) -> String {
        value
    }

    func asyncValue(context _: BenchmarkContext, arguments _: NoArguments) async -> String {
        value
    }

    func allItems(context _: BenchmarkContext, arguments _: NoArguments) -> [BenchmarkItem] {
        items
    }

    func item(context _: BenchmarkContext, arguments: ItemArguments) -> BenchmarkItem? {
        guard !items.isEmpty else {
            return nil
        }
        return items[arguments.id % items.count]
    }
}

private struct BenchmarkAPI: API, Sendable {
    let resolver: BenchmarkResolver
    let schema: Schema<BenchmarkResolver, BenchmarkContext>

    init(itemCount: Int) throws {
        resolver = BenchmarkResolver(itemCount: itemCount)
        schema = try Schema {
            Type(BenchmarkItem.self) {
                Field("id", at: \.id)
                Field("name", at: \.name)
                Field("score", at: \.score)
                Field("active", at: \.active)
            }

            Query {
                Field("keyPath", at: \.value)
                Field("sync", at: BenchmarkResolver.syncValue)
                Field("async", at: BenchmarkResolver.asyncValue)
                Field("items", at: BenchmarkResolver.allItems)
                Field("item", at: BenchmarkResolver.item) {
                    Argument("id", at: \.id)
                }
            }
        }
    }
}

private struct Configuration {
    var samples = 250
    var warmup = 25
    var itemCount = 100
    var concurrency = 8
    var filter: String?

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard index + 1 < arguments.count else {
                throw BenchmarkError.invalidOption("Missing value for \(option)")
            }
            let value = arguments[index + 1]

            switch option {
            case "--samples":
                samples = try Self.positiveInteger(value, option: option)
            case "--warmup":
                warmup = try Self.nonnegativeInteger(value, option: option)
            case "--items":
                itemCount = try Self.positiveInteger(value, option: option)
            case "--concurrency":
                concurrency = try Self.positiveInteger(value, option: option)
            case "--filter":
                filter = value
            default:
                throw BenchmarkError.invalidOption("Unknown option: \(option)")
            }

            index += 2
        }
    }

    private static func positiveInteger(_ value: String, option: String) throws -> Int {
        let result = try nonnegativeInteger(value, option: option)
        guard result > 0 else {
            throw BenchmarkError.invalidOption("\(option) must be greater than zero")
        }
        return result
    }

    private static func nonnegativeInteger(_ value: String, option: String) throws -> Int {
        guard let result = Int(value), result >= 0 else {
            throw BenchmarkError.invalidOption("Invalid integer for \(option): \(value)")
        }
        return result
    }
}

private enum BenchmarkError: Error, CustomStringConvertible {
    case executionFailed(String)
    case invalidOption(String)

    var description: String {
        switch self {
        case let .executionFailed(message), let .invalidOption(message):
            message
        }
    }
}

private struct BenchmarkCase: Sendable {
    let name: String
    let operationsPerSample: Int
    let sampleLimit: Int?
    let warmupLimit: Int?
    let operation: @Sendable () async throws -> Void

    init(
        name: String,
        operationsPerSample: Int = 1,
        sampleLimit: Int? = nil,
        warmupLimit: Int? = nil,
        operation: @escaping @Sendable () async throws -> Void
    ) {
        self.name = name
        self.operationsPerSample = operationsPerSample
        self.sampleLimit = sampleLimit
        self.warmupLimit = warmupLimit
        self.operation = operation
    }
}

private struct Statistics {
    let sampleCount: Int
    let mean: Double
    let median: Double
    let p95: Double
    let p99: Double

    init(samples: [Double]) {
        let sorted = samples.sorted()
        sampleCount = sorted.count
        mean = sorted.reduce(0, +) / Double(sorted.count)
        median = Self.percentile(0.50, in: sorted)
        p95 = Self.percentile(0.95, in: sorted)
        p99 = Self.percentile(0.99, in: sorted)
    }

    private static func percentile(_ percentile: Double, in sorted: [Double]) -> Double {
        let index = Int((Double(sorted.count - 1) * percentile).rounded(.up))
        return sorted[index]
    }
}

@main
private enum GraphitiBenchmarks {
    static func main() async throws {
        let configuration = try Configuration(arguments: Array(CommandLine.arguments.dropFirst()))

        #if DEBUG
        print("warning: benchmarks should be run with -c release\n")
        #endif

        let api = try BenchmarkAPI(itemCount: configuration.itemCount)
        let context = BenchmarkContext()
        let keyPathQuery = "{ keyPath }"
        let syncQuery = "{ sync }"
        let asyncQuery = "{ async }"
        let listQuery = "{ items { id name score active } }"
        let argumentQuery = "query Item($id: Int!) { item(id: $id) { id name score active } }"
        let invalidTypeQuery = "{ keyPath } fragment Invalid on BenchmarkItex { id }"
        let introspectionQuery = "{ __schema { types { name fields { name } } } }"
        let variables: [String: Map] = ["id": .int(configuration.itemCount / 2)]
        let siblingQuery = "{ " + (0 ..< 20).map { "field\($0): keyPath" }.joined(separator: " ") + " }"

        let keyPathOperation = try api.prepare(request: keyPathQuery)
        let syncOperation = try api.prepare(request: syncQuery)
        let asyncOperation = try api.prepare(request: asyncQuery)
        let listOperation = try api.prepare(request: listQuery)
        let argumentOperation = try api.prepare(request: argumentQuery)
        let siblingOperation = try api.prepare(request: siblingQuery)
        let introspectionOperation = try api.prepare(request: introspectionQuery)
        let directSchema = try makeDirectSchema()
        let directDocument = try preparedDocument(keyPathQuery, for: directSchema)

        let prepared: @Sendable (PreparedOperation, [String: Map]) async throws -> Void = { operation, variables in
            try check(
                await api.execute(
                    prepared: operation,
                    context: context,
                    variables: variables
                )
            )
        }

        var cases = [
            BenchmarkCase(name: "request.graphiti.keypath", operationsPerSample: 1) {
                try check(await api.execute(request: keyPathQuery, context: context))
            },
            BenchmarkCase(name: "request.graphql-direct.keypath", operationsPerSample: 1) {
                try check(
                    await graphql(
                        schema: directSchema,
                        request: keyPathQuery,
                        rootValue: api.resolver,
                        context: context
                    )
                )
            },
            BenchmarkCase(name: "prepared.graphiti.keypath", operationsPerSample: 1) {
                try await prepared(keyPathOperation, [:])
            },
            BenchmarkCase(name: "prepared.graphql-direct.keypath", operationsPerSample: 1) {
                try check(
                    await execute(
                        schema: directSchema,
                        documentAST: directDocument,
                        rootValue: api.resolver,
                        context: context
                    )
                )
            },
            BenchmarkCase(name: "prepared.graphiti.sync", operationsPerSample: 1) {
                try await prepared(syncOperation, [:])
            },
            BenchmarkCase(name: "prepared.graphiti.async", operationsPerSample: 1) {
                try await prepared(asyncOperation, [:])
            },
            BenchmarkCase(name: "prepared.graphiti.siblings-20", operationsPerSample: 1) {
                try await prepared(siblingOperation, [:])
            },
            BenchmarkCase(name: "request.graphiti.list-\(configuration.itemCount)", operationsPerSample: 1) {
                try check(await api.execute(request: listQuery, context: context))
            },
            BenchmarkCase(name: "prepared.graphiti.list-\(configuration.itemCount)", operationsPerSample: 1) {
                try await prepared(listOperation, [:])
            },
            BenchmarkCase(name: "prepared.graphiti.arguments", operationsPerSample: 1) {
                try await prepared(argumentOperation, variables)
            },
            BenchmarkCase(
                name: "request.graphiti.invalid-type",
                sampleLimit: 25,
                warmupLimit: 5
            ) {
                try checkExpectedErrors(await api.execute(request: invalidTypeQuery, context: context))
            },
            BenchmarkCase(
                name: "request.graphiti.introspection",
                sampleLimit: 10,
                warmupLimit: 1
            ) {
                try check(await api.execute(request: introspectionQuery, context: context))
            },
            BenchmarkCase(
                name: "prepared.graphiti.introspection",
                sampleLimit: 10,
                warmupLimit: 1
            ) {
                try check(await api.execute(prepared: introspectionOperation, context: context))
            },
            BenchmarkCase(
                name: "prepared.graphiti.keypath.concurrent-\(configuration.concurrency)",
                operationsPerSample: configuration.concurrency
            ) {
                try await concurrently(configuration.concurrency) {
                    try await prepared(keyPathOperation, [:])
                }
            },
            BenchmarkCase(
                name: "prepared.graphiti.list-\(configuration.itemCount).concurrent-\(configuration.concurrency)",
                operationsPerSample: configuration.concurrency
            ) {
                try await concurrently(configuration.concurrency) {
                    try await prepared(listOperation, [:])
                }
            },
        ]

        let massiveCaseNames = [
            "request.massive.hot",
            "prepared.massive.hot",
            "request.massive.selected-type",
            "prepared.massive.selected-type",
            "request.massive.invalid-type",
            "request.massive.introspection",
            "prepared.massive.introspection",
            "prepared.massive.hot.concurrent-\(configuration.concurrency)",
        ]
        let includeMassiveFixture = configuration.filter.map { filter in
            massiveCaseNames.contains { $0.localizedCaseInsensitiveContains(filter) }
        } ?? true

        if includeMassiveFixture {
            print("Building and validating the 2,000-type massive schema fixture...")
            let massiveAPI = try MassiveAPI()
            let massiveContext = MassiveContext()
            try verifyMassiveSchema(massiveAPI.schema.schema)

            let massiveHotQuery = "{ hot }"
            let massiveSelectedTypeQuery = "{ sample { field0 field1 field2 field3 field4 } }"
            let massiveInvalidTypeQuery = "{ hot } fragment Invalid on MassiveType199X { field0 }"
            let massiveIntrospectionQuery = "{ __schema { types { name fields { name } } } }"
            let massiveHotOperation = try massiveAPI.prepare(request: massiveHotQuery)
            let massiveSelectedTypeOperation = try massiveAPI.prepare(request: massiveSelectedTypeQuery)
            let massiveIntrospectionOperation = try massiveAPI.prepare(request: massiveIntrospectionQuery)

            cases += [
                BenchmarkCase(name: "request.massive.hot") {
                    try check(await massiveAPI.execute(request: massiveHotQuery, context: massiveContext))
                },
                BenchmarkCase(name: "prepared.massive.hot") {
                    try check(await massiveAPI.execute(prepared: massiveHotOperation, context: massiveContext))
                },
                BenchmarkCase(name: "request.massive.selected-type") {
                    try check(
                        await massiveAPI.execute(
                            request: massiveSelectedTypeQuery,
                            context: massiveContext
                        )
                    )
                },
                BenchmarkCase(name: "prepared.massive.selected-type") {
                    try check(
                        await massiveAPI.execute(
                            prepared: massiveSelectedTypeOperation,
                            context: massiveContext
                        )
                    )
                },
                BenchmarkCase(
                    name: "request.massive.invalid-type",
                    sampleLimit: 25,
                    warmupLimit: 5
                ) {
                    try checkExpectedErrors(
                        await massiveAPI.execute(
                            request: massiveInvalidTypeQuery,
                            context: massiveContext
                        )
                    )
                },
                BenchmarkCase(
                    name: "request.massive.introspection",
                    sampleLimit: 10,
                    warmupLimit: 1
                ) {
                    try check(
                        await massiveAPI.execute(
                            request: massiveIntrospectionQuery,
                            context: massiveContext
                        )
                    )
                },
                BenchmarkCase(
                    name: "prepared.massive.introspection",
                    sampleLimit: 10,
                    warmupLimit: 1
                ) {
                    try check(
                        await massiveAPI.execute(
                            prepared: massiveIntrospectionOperation,
                            context: massiveContext
                        )
                    )
                },
                BenchmarkCase(
                    name: "prepared.massive.hot.concurrent-\(configuration.concurrency)",
                    operationsPerSample: configuration.concurrency
                ) {
                    try await concurrently(configuration.concurrency) {
                        try check(
                            await massiveAPI.execute(
                                prepared: massiveHotOperation,
                                context: massiveContext
                            )
                        )
                    }
                },
            ]
        }

        cases = cases.filter { benchmark in
            configuration.filter.map { benchmark.name.localizedCaseInsensitiveContains($0) } ?? true
        }

        guard !cases.isEmpty else {
            throw BenchmarkError.invalidOption("No benchmarks matched the requested filter")
        }

        print("Graphiti query execution benchmarks")
        print("samples: \(configuration.samples), warmup: \(configuration.warmup), items: \(configuration.itemCount), concurrency: \(configuration.concurrency)")
        print("")
        print(
            padded("benchmark", to: 54) + " "
                + padded("mean", to: 11, rightAligned: true) + " "
                + padded("p50", to: 11, rightAligned: true) + " "
                + padded("p95", to: 11, rightAligned: true) + " "
                + padded("p99", to: 11, rightAligned: true) + " "
                + padded("n", to: 6, rightAligned: true) + " "
                + padded("ops/s", to: 12, rightAligned: true)
        )
        print(String(repeating: "-", count: 124))

        var results: [String: Statistics] = [:]
        for benchmark in cases {
            let statistics = try await measure(benchmark, configuration: configuration)
            results[benchmark.name] = statistics
            printResult(benchmark.name, statistics: statistics)
        }

        printMassiveSchemaRatios(results, concurrency: configuration.concurrency)
    }

    private static func preparedDocument(_ query: String, for schema: GraphQLSchema) throws -> Document {
        let document = try parse(source: query)
        let errors = validate(schema: schema, ast: document)
        guard errors.isEmpty else {
            throw BenchmarkError.executionFailed(errors.map(\.message).joined(separator: "; "))
        }
        return document
    }

    private static func makeDirectSchema() throws -> GraphQLSchema {
        let query = try GraphQLObjectType(
            name: "Query",
            fields: [
                "keyPath": GraphQLField(type: GraphQLString, resolve: { source, _, _, _ in
                    guard let resolver = source as? BenchmarkResolver else {
                        throw BenchmarkError.executionFailed("Unexpected direct resolver source")
                    }
                    return resolver.value
                }),
            ]
        )
        return try GraphQLSchema(query: query)
    }

    private static func check(_ result: GraphQLResult) throws {
        guard result.errors.isEmpty else {
            throw BenchmarkError.executionFailed(result.errors.map(\.message).joined(separator: "; "))
        }
        guard result.data != nil else {
            throw BenchmarkError.executionFailed("Execution returned no data")
        }
    }

    private static func checkExpectedErrors(_ result: GraphQLResult) throws {
        guard !result.errors.isEmpty else {
            throw BenchmarkError.executionFailed("Execution unexpectedly succeeded")
        }
    }

    private static func verifyMassiveSchema(_ schema: GraphQLSchema) throws {
        let modelTypes = schema.typeMap.values.compactMap { $0 as? GraphQLObjectType }
            .filter { $0.name.hasPrefix("MassiveType") }
        let fieldCount = try modelTypes.reduce(into: 0) { count, type in
            count += try type.fields().count
        }

        guard modelTypes.count == MassiveSchemaFixture.typeCount else {
            throw BenchmarkError.executionFailed(
                "Massive fixture has \(modelTypes.count) model types; expected \(MassiveSchemaFixture.typeCount)"
            )
        }
        guard fieldCount == MassiveSchemaFixture.modelFieldCount else {
            throw BenchmarkError.executionFailed(
                "Massive fixture has \(fieldCount) model fields; expected \(MassiveSchemaFixture.modelFieldCount)"
            )
        }

        print("Verified \(modelTypes.count) model types and \(fieldCount) model fields.\n")
    }

    private static func concurrently(
        _ count: Int,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< count {
                group.addTask(operation: operation)
            }
            try await group.waitForAll()
        }
    }

    private static func measure(
        _ benchmark: BenchmarkCase,
        configuration: Configuration
    ) async throws -> Statistics {
        let warmupCount = min(configuration.warmup, benchmark.warmupLimit ?? configuration.warmup)
        for _ in 0 ..< warmupCount {
            try await benchmark.operation()
        }

        let sampleCount = min(configuration.samples, benchmark.sampleLimit ?? configuration.samples)
        var samples: [Double] = []
        samples.reserveCapacity(sampleCount)

        for _ in 0 ..< sampleCount {
            let start = DispatchTime.now().uptimeNanoseconds
            try await benchmark.operation()
            let nanoseconds = Double(DispatchTime.now().uptimeNanoseconds - start)
            samples.append(nanoseconds / Double(benchmark.operationsPerSample))
        }

        return Statistics(samples: samples)
    }

    private static func printMassiveSchemaRatios(
        _ results: [String: Statistics],
        concurrency: Int
    ) {
        let comparisons = [
            ("full request hot query", "request.graphiti.keypath", "request.massive.hot"),
            ("prepared hot query", "prepared.graphiti.keypath", "prepared.massive.hot"),
            (
                "concurrent prepared hot query",
                "prepared.graphiti.keypath.concurrent-\(concurrency)",
                "prepared.massive.hot.concurrent-\(concurrency)"
            ),
            (
                "invalid type validation",
                "request.graphiti.invalid-type",
                "request.massive.invalid-type"
            ),
            (
                "full request introspection",
                "request.graphiti.introspection",
                "request.massive.introspection"
            ),
            (
                "prepared introspection",
                "prepared.graphiti.introspection",
                "prepared.massive.introspection"
            ),
        ]

        let ratios = comparisons.compactMap { label, smallName, massiveName -> (String, Double)? in
            guard let small = results[smallName], let massive = results[massiveName] else {
                return nil
            }
            return (label, massive.mean / small.mean)
        }
        guard !ratios.isEmpty else {
            return
        }

        print("\nMassive/small mean latency ratios (lower is better):")
        for (label, ratio) in ratios {
            print("  \(padded(label, to: 38)) \(String(format: "%.2fx", ratio))")
        }
    }

    private static func printResult(_ name: String, statistics: Statistics) {
        let operationsPerSecond = 1_000_000_000 / statistics.mean
        print(
            padded(name, to: 54) + " "
                + padded(formattedDuration(statistics.mean), to: 11, rightAligned: true) + " "
                + padded(formattedDuration(statistics.median), to: 11, rightAligned: true) + " "
                + padded(formattedDuration(statistics.p95), to: 11, rightAligned: true) + " "
                + padded(formattedDuration(statistics.p99), to: 11, rightAligned: true) + " "
                + padded(String(statistics.sampleCount), to: 6, rightAligned: true) + " "
                + padded(String(format: "%.0f", operationsPerSecond), to: 12, rightAligned: true)
        )
    }

    private static func padded(_ value: String, to width: Int, rightAligned: Bool = false) -> String {
        guard value.count < width else {
            return value
        }
        let padding = String(repeating: " ", count: width - value.count)
        return rightAligned ? padding + value : value + padding
    }

    private static func formattedDuration(_ nanoseconds: Double) -> String {
        if nanoseconds < 1_000 {
            return String(format: "%.0f ns", nanoseconds)
        }
        if nanoseconds < 1_000_000 {
            return String(format: "%.2f us", nanoseconds / 1_000)
        }
        if nanoseconds < 1_000_000_000 {
            return String(format: "%.2f ms", nanoseconds / 1_000_000)
        }
        return String(format: "%.2f s", nanoseconds / 1_000_000_000)
    }
}
