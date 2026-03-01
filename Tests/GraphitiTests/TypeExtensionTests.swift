import Graphiti
import GraphQL
import Testing

struct TypeExtensionTests {
    private struct ExtendedObject: Codable {
        let id: String
        let kind: String
        let replacementKind: String
    }

    private struct TestResolver {
        func object(context _: NoContext, arguments _: NoArguments) -> ExtendedObject {
            ExtendedObject(id: "1", kind: "base", replacementKind: "extension")
        }
    }

    private struct TestAPI: API {
        let resolver: TestResolver
        let schema: Schema<TestResolver, NoContext>
    }

    @Test func extendsExistingTypeWithNewField() async throws {
        let schema = try Schema<TestResolver, NoContext> {
            Type(ExtendedObject.self) {
                Field("id", at: \.id)
            }
            TypeExtension(ExtendedObject.self) {
                Field("kind", at: \.kind)
            }
            Query {
                Field("object", at: TestResolver.object)
            }
        }

        let api = TestAPI(resolver: TestResolver(), schema: schema)
        let result = try await api.execute(
            request: """
            query {
                object {
                    id
                    kind
                }
            }
            """,
            context: NoContext()
        )

        #expect(
            result ==
                GraphQLResult(data: [
                    "object": [
                        "id": "1",
                        "kind": "base",
                    ],
                ])
        )
    }

    @Test func lastTypeExtensionWinsOnFieldNameCollision() async throws {
        let schema = try Schema<TestResolver, NoContext> {
            Type(ExtendedObject.self) {
                Field("id", at: \.id)
                Field("kind", at: \.kind)
            }
            TypeExtension(ExtendedObject.self) {
                Field("kind", at: \.replacementKind)
            }
            Query {
                Field("object", at: TestResolver.object)
            }
        }

        let api = TestAPI(resolver: TestResolver(), schema: schema)
        let result = try await api.execute(
            request: """
            query {
                object {
                    id
                    kind
                }
            }
            """,
            context: NoContext()
        )

        #expect(
            result ==
                GraphQLResult(data: [
                    "object": [
                        "id": "1",
                        "kind": "extension",
                    ],
                ])
        )
    }

    @Test func typeExtensionBeforeBaseTypeThrows() {
        do {
            _ = try Schema<TestResolver, NoContext> {
                TypeExtension(ExtendedObject.self) {
                    Field("kind", at: \.kind)
                }
                Type(ExtendedObject.self) {
                    Field("id", at: \.id)
                }
                Query {
                    Field("object", at: TestResolver.object)
                }
            }
            #expect(Bool(false))
        } catch {
            guard let graphQLError = error as? GraphQLError else {
                #expect(Bool(false))
                return
            }

            #expect(graphQLError.message.contains("Cannot use type"))
            #expect(graphQLError.message.contains("as object"))
        }
    }

    @Test func partialSchemaOrderMattersForTypeExtension() {
        let core = PartialSchema<TestResolver, NoContext>(
            types: {
                Type(ExtendedObject.self) {
                    Field("id", at: \.id)
                }
            },
            query: {
                Field("object", at: TestResolver.object)
            }
        )

        let extensionSchema = PartialSchema<TestResolver, NoContext>(
            types: {
                TypeExtension(ExtendedObject.self) {
                    Field("kind", at: \.kind)
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
            #expect(graphQLError.message.contains("as object"))
        }
    }
}
