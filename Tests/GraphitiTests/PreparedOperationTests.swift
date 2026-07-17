@testable import Graphiti
import GraphQL
import Testing

@Suite struct PreparedOperationTests {
    @Test func executionMatchesRequestAPI() async throws {
        let api = try PreparedAPI()
        let operation = try api.prepare(request: "{ greeting }")

        let preparedResult = try await api.execute(
            prepared: operation,
            context: PreparedContext(prefix: "Hello")
        )
        let requestResult = try await api.execute(
            request: "{ greeting }",
            context: PreparedContext(prefix: "Hello")
        )

        #expect(preparedResult == requestResult)
    }

    @Test func variablesAndOperationName() async throws {
        let api = try PreparedAPI()
        let operation = try api.prepare(
            request: """
            query First { greeting }
            query Selected($name: String!) { greeting(name: $name) }
            """,
            operationName: "Selected"
        )

        let result = try await api.execute(
            prepared: operation,
            context: PreparedContext(prefix: "Hello"),
            variables: ["name": .string("Swift")]
        )

        #expect(result.data == ["greeting": "Hello, Swift"])
        #expect(result.errors.isEmpty)
    }

    @Test func invalidDocumentIsRejectedDuringPreparation() throws {
        let api = try PreparedAPI()

        do {
            _ = try api.prepare(request: "{ missingField }")
            Issue.record("Expected document validation to fail")
        } catch let errors as GraphQLErrors {
            #expect(errors.errors.count == 1)
            #expect(errors.errors[0].message.contains("missingField"))
        }
    }

    @Test func operationCannotBeUsedWithAnotherSchema() async throws {
        let first = try PreparedAPI()
        let second = try PreparedAPI()
        let operation = try first.prepare(request: "{ greeting }")

        await #expect(throws: PreparedOperationError.schemaMismatch) {
            try await second.execute(
                prepared: operation,
                context: PreparedContext(prefix: "Hello")
            )
        }
    }

    @Test func operationCanBeReusedConcurrently() async throws {
        let api = try PreparedAPI()
        let operation = try api.prepare(request: "{ greeting }")

        let results = try await withThrowingTaskGroup(
            of: GraphQLResult.self,
            returning: [GraphQLResult].self
        ) { group in
            for _ in 0 ..< 32 {
                group.addTask {
                    try await api.execute(
                        prepared: operation,
                        context: PreparedContext(prefix: "Hello")
                    )
                }
            }

            var results: [GraphQLResult] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }

        #expect(results.count == 32)
        #expect(results.allSatisfy { $0.data == ["greeting": "Hello, World"] })
        #expect(results.allSatisfy { $0.errors.isEmpty })
    }
}

private struct PreparedContext: Sendable {
    let prefix: String
}

private struct PreparedArguments: Codable, Sendable {
    let name: String?
}

private struct PreparedResolver: Sendable {
    func greeting(context: PreparedContext, arguments: PreparedArguments) -> String {
        "\(context.prefix), \(arguments.name ?? "World")"
    }
}

private struct PreparedAPI: API, Sendable {
    let resolver = PreparedResolver()
    let schema: Schema<PreparedResolver, PreparedContext>

    init() throws {
        schema = try Schema {
            Query {
                Field("greeting", at: PreparedResolver.greeting) {
                    Argument("name", at: \.name)
                }
            }
        }
    }
}
