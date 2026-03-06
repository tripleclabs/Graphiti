import Graphiti
import GraphQL
import Testing

struct InputExtensionTests {
    private struct CreateUserInput: Codable {
        let name: String
        let nickname: String?
    }

    private struct TestResolver {
        struct CreateUserArguments: Codable {
            let input: CreateUserInput
        }

        func createUser(context _: NoContext, arguments: CreateUserArguments) -> String {
            let nick = arguments.input.nickname ?? "none"
            return "\(arguments.input.name):\(nick)"
        }
    }

    private struct TestAPI: API {
        let resolver: TestResolver
        let schema: Schema<TestResolver, NoContext>
    }

    @Test func extendsExistingInputWithNewField() async throws {
        let schema = try Schema<TestResolver, NoContext> {
            Input(CreateUserInput.self) {
                InputField("name", at: \.name)
            }
            InputExtension(CreateUserInput.self) {
                InputField("nickname", at: \.nickname)
            }
            Query {
                Field("createUser", at: TestResolver.createUser) {
                    Argument("input", at: \.input)
                }
            }
        }

        let api = TestAPI(resolver: TestResolver(), schema: schema)
        let result = try await api.execute(
            request: """
            query {
                createUser(input: { name: "Alice", nickname: "Ali" })
            }
            """,
            context: NoContext()
        )

        #expect(
            result ==
                GraphQLResult(data: [
                    "createUser": "Alice:Ali",
                ])
        )
    }

    @Test func extensionFieldIsOptionalAndOmittable() async throws {
        let schema = try Schema<TestResolver, NoContext> {
            Input(CreateUserInput.self) {
                InputField("name", at: \.name)
            }
            InputExtension(CreateUserInput.self) {
                InputField("nickname", at: \.nickname)
            }
            Query {
                Field("createUser", at: TestResolver.createUser) {
                    Argument("input", at: \.input)
                }
            }
        }

        let api = TestAPI(resolver: TestResolver(), schema: schema)
        let result = try await api.execute(
            request: """
            query {
                createUser(input: { name: "Bob" })
            }
            """,
            context: NoContext()
        )

        #expect(
            result ==
                GraphQLResult(data: [
                    "createUser": "Bob:none",
                ])
        )
    }

    @Test func extensionFieldOverridesExistingFieldName() async throws {
        // When InputExtension re-declares a field name that already exists on the
        // base Input, the extension's definition replaces the original. Here we
        // verify the schema still builds and resolves without error.
        let schema = try Schema<TestResolver, NoContext> {
            Input(CreateUserInput.self) {
                InputField("name", at: \.name)
                InputField("nickname", at: \.nickname)
            }
            InputExtension(CreateUserInput.self) {
                InputField("nickname", at: \.nickname)
            }
            Query {
                Field("createUser", at: TestResolver.createUser) {
                    Argument("input", at: \.input)
                }
            }
        }

        let api = TestAPI(resolver: TestResolver(), schema: schema)
        let result = try await api.execute(
            request: """
            query {
                createUser(input: { name: "Alice", nickname: "Override" })
            }
            """,
            context: NoContext()
        )

        #expect(
            result ==
                GraphQLResult(data: [
                    "createUser": "Alice:Override",
                ])
        )
    }

    @Test func inputExtensionBeforeBaseInputThrows() {
        do {
            _ = try Schema<TestResolver, NoContext> {
                InputExtension(CreateUserInput.self) {
                    InputField("nickname", at: \.nickname)
                }
                Input(CreateUserInput.self) {
                    InputField("name", at: \.name)
                }
                Query {
                    Field("createUser", at: TestResolver.createUser) {
                        Argument("input", at: \.input)
                    }
                }
            }
            #expect(Bool(false))
        } catch {
            guard let graphQLError = error as? GraphQLError else {
                #expect(Bool(false))
                return
            }

            #expect(graphQLError.message.contains("Cannot use type"))
            #expect(graphQLError.message.contains("input object"))
        }
    }

    @Test func partialSchemaOrderMattersForInputExtension() {
        let core = PartialSchema<TestResolver, NoContext>(
            types: {
                Input(CreateUserInput.self) {
                    InputField("name", at: \.name)
                }
            },
            query: {
                Field("createUser", at: TestResolver.createUser) {
                    Argument("input", at: \.input)
                }
            }
        )

        let extensionSchema = PartialSchema<TestResolver, NoContext>(
            types: {
                InputExtension(CreateUserInput.self) {
                    InputField("nickname", at: \.nickname)
                }
            }
        )

        do {
            _ = try Schema.create(from: [extensionSchema, core])
            #expect(Bool(false))
        } catch {
            guard let graphQLError = error as? GraphQLError else {
                #expect(Bool(false))
                return
            }

            #expect(graphQLError.message.contains("Cannot use type"))
            #expect(graphQLError.message.contains("input object"))
        }
    }
}
