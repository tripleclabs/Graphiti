@testable import Graphiti
import GraphQL
import Testing

private struct SDLUser: Codable, Sendable {
    let email: String
    let role: SDLRole
}

private enum SDLRole: String, Codable, Sendable {
    case admin = "ADMIN"
    case member = "MEMBER"
}

private struct SDLResolver: Sendable {
    func user(context _: NoContext, arguments _: NoArguments) -> SDLUser {
        SDLUser(email: "a@b.c", role: .admin)
    }
}

@Suite struct SDLRenderingTests {
    private func schema() throws -> Schema<SDLResolver, NoContext> {
        try Schema<SDLResolver, NoContext> {
            Enum(SDLRole.self) {
                Value(SDLRole.admin)
                Value(SDLRole.member)
            }
            Directive("model", on: .object) {
                DirectiveArgument("table", at: String.self)
            }
            Directive("auth", on: .fieldDefinition) {
                DirectiveArgument("role", at: SDLRole.self)
            }
            Directive("tag", on: .fieldDefinition, repeatable: true) {
                DirectiveArgument("name", at: String.self)
            }
            Type(SDLUser.self) {
                Field("email", at: \.email)
                    .directive("auth", ("role", "ADMIN"))
                    .directive("tag", ("name", "pii"))
                Field("role", at: \.role)
            }
            .directive("model", ("table", "users"))
            Query {
                Field("user", at: SDLResolver.user)
            }
        }
    }

    @Test func rendersDirectiveDefinitions() throws {
        let sdl = try schema().sdl()
        #expect(sdl.contains("directive @model(table: String!) on OBJECT"))
        #expect(sdl.contains("directive @tag(name: String!) repeatable on FIELD_DEFINITION"))
    }

    @Test func rendersTypeAndFieldApplications() throws {
        let sdl = try schema().sdl()
        #expect(sdl.contains("type SDLUser @model(table: \"users\") {"))
        #expect(sdl.contains("email: String! @auth(role: ADMIN) @tag(name: \"pii\")"))
    }

    @Test func rendersEnumArgumentUnquotedAndStringQuoted() throws {
        let sdl = try schema().sdl()
        #expect(sdl.contains("@auth(role: ADMIN)"))
        #expect(!sdl.contains("@auth(role: \"ADMIN\")"))
        #expect(sdl.contains("@tag(name: \"pii\")"))
    }

    @Test func emittedSDLParses() throws {
        _ = try parse(source: Source(body: try schema().sdl()))
    }

    @Test func outputIsDeterministic() throws {
        #expect(try schema().sdl() == schema().sdl())
    }

    @Test func rawPrintSchemaDoesNotSeeApplications() throws {
        let schema = try schema()
        // The definition line is printed either way; only the *application*
        // on the type distinguishes the two entry points.
        #expect(!printSchema(schema: schema.schema).contains("type SDLUser @model"))
        #expect(schema.sdl().contains("type SDLUser @model(table: \"users\")"))
    }
}
