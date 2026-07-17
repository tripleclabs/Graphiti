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
    let operation: @Sendable () async throws -> Void
}

private struct Statistics {
    let mean: Double
    let median: Double
    let p95: Double
    let p99: Double

    init(samples: [Double]) {
        let sorted = samples.sorted()
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
        let variables: [String: Map] = ["id": .int(configuration.itemCount / 2)]
        let siblingQuery = "{ " + (0 ..< 20).map { "field\($0): keyPath" }.joined(separator: " ") + " }"

        let keyPathDocument = try preparedDocument(keyPathQuery, for: api.schema.schema)
        let syncDocument = try preparedDocument(syncQuery, for: api.schema.schema)
        let asyncDocument = try preparedDocument(asyncQuery, for: api.schema.schema)
        let listDocument = try preparedDocument(listQuery, for: api.schema.schema)
        let argumentDocument = try preparedDocument(argumentQuery, for: api.schema.schema)
        let siblingDocument = try preparedDocument(siblingQuery, for: api.schema.schema)
        let directSchema = try makeDirectSchema()
        let directDocument = try preparedDocument(keyPathQuery, for: directSchema)

        let prepared: @Sendable (Document, [String: Map]) async throws -> Void = { document, variables in
            try check(
                await execute(
                    schema: api.schema.schema,
                    documentAST: document,
                    rootValue: api.resolver,
                    context: context,
                    variableValues: variables
                )
            )
        }

        let cases = [
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
                try await prepared(keyPathDocument, [:])
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
                try await prepared(syncDocument, [:])
            },
            BenchmarkCase(name: "prepared.graphiti.async", operationsPerSample: 1) {
                try await prepared(asyncDocument, [:])
            },
            BenchmarkCase(name: "prepared.graphiti.siblings-20", operationsPerSample: 1) {
                try await prepared(siblingDocument, [:])
            },
            BenchmarkCase(name: "request.graphiti.list-\(configuration.itemCount)", operationsPerSample: 1) {
                try check(await api.execute(request: listQuery, context: context))
            },
            BenchmarkCase(name: "prepared.graphiti.list-\(configuration.itemCount)", operationsPerSample: 1) {
                try await prepared(listDocument, [:])
            },
            BenchmarkCase(name: "prepared.graphiti.arguments", operationsPerSample: 1) {
                try await prepared(argumentDocument, variables)
            },
            BenchmarkCase(
                name: "prepared.graphiti.keypath.concurrent-\(configuration.concurrency)",
                operationsPerSample: configuration.concurrency
            ) {
                try await concurrently(configuration.concurrency) {
                    try await prepared(keyPathDocument, [:])
                }
            },
            BenchmarkCase(
                name: "prepared.graphiti.list-\(configuration.itemCount).concurrent-\(configuration.concurrency)",
                operationsPerSample: configuration.concurrency
            ) {
                try await concurrently(configuration.concurrency) {
                    try await prepared(listDocument, [:])
                }
            },
        ].filter { benchmark in
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
                + padded("ops/s", to: 12, rightAligned: true)
        )
        print(String(repeating: "-", count: 117))

        for benchmark in cases {
            let statistics = try await measure(benchmark, configuration: configuration)
            printResult(benchmark.name, statistics: statistics)
        }
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
        for _ in 0 ..< configuration.warmup {
            try await benchmark.operation()
        }

        var samples: [Double] = []
        samples.reserveCapacity(configuration.samples)

        for _ in 0 ..< configuration.samples {
            let start = DispatchTime.now().uptimeNanoseconds
            try await benchmark.operation()
            let nanoseconds = Double(DispatchTime.now().uptimeNanoseconds - start)
            samples.append(nanoseconds / Double(benchmark.operationsPerSample))
        }

        return Statistics(samples: samples)
    }

    private static func printResult(_ name: String, statistics: Statistics) {
        let operationsPerSecond = 1_000_000_000 / statistics.mean
        print(
            padded(name, to: 54) + " "
                + padded(formattedDuration(statistics.mean), to: 11, rightAligned: true) + " "
                + padded(formattedDuration(statistics.median), to: 11, rightAligned: true) + " "
                + padded(formattedDuration(statistics.p95), to: 11, rightAligned: true) + " "
                + padded(formattedDuration(statistics.p99), to: 11, rightAligned: true) + " "
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
