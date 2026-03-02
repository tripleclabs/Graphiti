@testable import Graphiti
import GraphQL
import Testing

struct DynamicEnumTests {
    /// A Codable wrapper that encodes/decodes as a single string value,
    /// simulating types like ValidatedStatus<T>.
    private struct Status: Codable, Equatable {
        let rawValue: String

        init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        init(from decoder: Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    private struct StatusOutput {
        let status: Status
    }

    private struct StatusArguments: Codable {
        let status: Status
    }

    private struct TestResolver {
        func getStatus(context _: NoContext, arguments _: NoArguments) -> StatusOutput {
            StatusOutput(status: Status("ACTIVE"))
        }

        func echoStatus(context _: NoContext, arguments: StatusArguments) -> StatusOutput {
            StatusOutput(status: arguments.status)
        }
    }

    // MARK: - Output

    @Test func dynamicEnumOutput() async throws {
        let schema = try Schema<TestResolver, NoContext> {
            DynamicEnum(Status.self, as: "Status", values: [
                (name: "ACTIVE", description: "Active status"),
                (name: "INACTIVE", description: "Inactive status"),
            ])
            Type(StatusOutput.self) {
                Field("status", at: \.status)
            }
            Query {
                Field("getStatus", at: TestResolver.getStatus)
            }
        }
        let api = TestAPI<TestResolver, NoContext>(
            resolver: TestResolver(),
            schema: schema
        )

        let result = try await api.execute(
            request: "{ getStatus { status } }",
            context: NoContext()
        )
        #expect(
            result == GraphQLResult(data: [
                "getStatus": ["status": "ACTIVE"],
            ])
        )
    }

    // MARK: - Argument input

    @Test func dynamicEnumArgument() async throws {
        let schema = try Schema<TestResolver, NoContext> {
            DynamicEnum(Status.self, as: "Status", values: [
                (name: "ACTIVE", description: "Active status"),
                (name: "INACTIVE", description: "Inactive status"),
            ])
            Type(StatusOutput.self) {
                Field("status", at: \.status)
            }
            Query {
                Field("echoStatus", at: TestResolver.echoStatus) {
                    Argument("status", at: \.status)
                }
            }
        }
        let api = TestAPI<TestResolver, NoContext>(
            resolver: TestResolver(),
            schema: schema
        )

        let result = try await api.execute(
            request: "{ echoStatus(status: INACTIVE) { status } }",
            context: NoContext()
        )
        #expect(
            result == GraphQLResult(data: [
                "echoStatus": ["status": "INACTIVE"],
            ])
        )
    }

    // MARK: - Invalid enum value is rejected

    @Test func dynamicEnumInvalidValue() async throws {
        let schema = try Schema<TestResolver, NoContext> {
            DynamicEnum(Status.self, as: "Status", values: [
                (name: "ACTIVE", description: nil),
                (name: "INACTIVE", description: nil),
            ])
            Type(StatusOutput.self) {
                Field("status", at: \.status)
            }
            Query {
                Field("echoStatus", at: TestResolver.echoStatus) {
                    Argument("status", at: \.status)
                }
            }
        }
        let api = TestAPI<TestResolver, NoContext>(
            resolver: TestResolver(),
            schema: schema
        )

        let result = try await api.execute(
            request: "{ echoStatus(status: UNKNOWN) { status } }",
            context: NoContext()
        )
        #expect(!result.errors.isEmpty)
    }

    // MARK: - Custom name

    @Test func dynamicEnumCustomName() async throws {
        let schema = try Schema<TestResolver, NoContext> {
            DynamicEnum(Status.self, as: "WorkflowStatus", values: [
                (name: "ACTIVE", description: nil),
            ])
            Type(StatusOutput.self) {
                Field("status", at: \.status)
            }
            Query {
                Field("getStatus", at: TestResolver.getStatus)
            }
        }

        let result = try await schema.execute(
            request: """
            {
                __type(name: "WorkflowStatus") {
                    kind
                    enumValues { name }
                }
            }
            """,
            resolver: TestResolver(),
            context: NoContext()
        )
        let typeInfo = result.data?.dictionary?["__type"]?.dictionary
        #expect(typeInfo?["kind"] == "ENUM")
        let enumValues = typeInfo?["enumValues"]?.array
        #expect(enumValues?.count == 1)
        #expect(enumValues?.first?.dictionary?["name"] == "ACTIVE")
    }

    // MARK: - Deprecation reason

    @Test func dynamicEnumDeprecation() async throws {
        let schema = try Schema<TestResolver, NoContext> {
            DynamicEnum(Status.self, as: "Status", values: [
                (name: "ACTIVE", description: "Active", deprecationReason: nil),
                (name: "INACTIVE", description: "Inactive", deprecationReason: "Use ARCHIVED instead"),
            ])
            Type(StatusOutput.self) {
                Field("status", at: \.status)
            }
            Query {
                Field("getStatus", at: TestResolver.getStatus)
            }
        }

        let result = try await schema.execute(
            request: """
            {
                __type(name: "Status") {
                    enumValues(includeDeprecated: true) {
                        name
                        isDeprecated
                        deprecationReason
                    }
                }
            }
            """,
            resolver: TestResolver(),
            context: NoContext()
        )
        let enumValues = result.data?.dictionary?["__type"]?.dictionary?["enumValues"]?.array
        #expect(enumValues?.count == 2)

        let inactive = enumValues?.first { $0.dictionary?["name"] == "INACTIVE" }
        #expect(inactive?.dictionary?["isDeprecated"] == true)
        #expect(inactive?.dictionary?["deprecationReason"] == "Use ARCHIVED instead")

        let active = enumValues?.first { $0.dictionary?["name"] == "ACTIVE" }
        #expect(active?.dictionary?["isDeprecated"] == false)
    }
}

private class TestAPI<Resolver: Sendable, ContextType: Sendable>: API {
    let resolver: Resolver
    let schema: Schema<Resolver, ContextType>

    init(resolver: Resolver, schema: Schema<Resolver, ContextType>) {
        self.resolver = resolver
        self.schema = schema
    }
}
