@testable import Graphiti
import GraphQL
import Testing

private struct ProbeUser: Codable, Sendable {
    let email: String
}

private struct ProbeResolver: Sendable {
    func publicUser(context _: NoContext, arguments _: NoArguments) -> ProbeUser {
        ProbeUser(email: "a@b.c")
    }

    func adminUser(context _: NoContext, arguments _: NoArguments) -> ProbeUser {
        ProbeUser(email: "a@b.c")
    }

    func internalUser(context _: NoContext, arguments _: NoArguments) -> ProbeUser {
        ProbeUser(email: "a@b.c")
    }
}

/// Root operation types reach the schema through `Query`, `Mutation` and
/// `Subscription` rather than `Type`, so their field directives need their own
/// registration. These pin that — the first implementation registered fields
/// only for `Type` and `Interface`, leaving root fields silently unannotated.
@Suite struct RootOperationDirectiveTests {
    @Test func rootQueryFieldDirectivesAreQueryableByNameAndValue() throws {
        let schema = try Schema<ProbeResolver, NoContext> {
            Directive("scope", on: .fieldDefinition) {
                DirectiveArgument("level", at: String.self)
            }
            Type(ProbeUser.self) { Field("email", at: \.email) }
            Query {
                Field("publicUser", at: ProbeResolver.publicUser)
                    .directive("scope", ("level", "public"))
                Field("adminUser", at: ProbeResolver.adminUser)
                    .directive("scope", ("level", "admin"))
                Field("internalUser", at: ProbeResolver.internalUser)
                    .directive("scope", ("level", "admin"))
            }
        }

        // "All root query fields with @scope(level: "admin")"
        let rootName = schema.schema.queryType?.name
        let matches = schema.appliedDirectives
            .compactMap { target, directives -> String? in
                guard
                    case let .member(type, member) = target,
                    type == rootName,
                    directives.contains(where: { directive in
                        directive.name == "scope" &&
                            directive.arguments.contains { $0.0 == "level" && $0.1 == "admin" }
                    })
                else { return nil }
                return member
            }
            .sorted()

        #expect(matches == ["adminUser", "internalUser"])
    }

    @Test func rootQueryFieldDirectivesAreRendered() throws {
        let schema = try Schema<ProbeResolver, NoContext> {
            Directive("scope", on: .fieldDefinition) {
                DirectiveArgument("level", at: String.self)
            }
            Type(ProbeUser.self) { Field("email", at: \.email) }
            Query {
                Field("publicUser", at: ProbeResolver.publicUser)
                    .directive("scope", ("level", "public"))
            }
        }
        #expect(schema.sdl().contains("publicUser: ProbeUser! @scope(level: \"public\")"))
    }
}
