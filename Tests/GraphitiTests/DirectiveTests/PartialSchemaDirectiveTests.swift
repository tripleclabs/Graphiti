import Graphiti
import GraphQL
import Testing

private struct PartialDirectiveUser: Codable, Sendable {
    let email: String
}

private struct PartialDirectiveResolver: Sendable {
    func me(context _: NoContext, arguments _: NoArguments) -> PartialDirectiveUser {
        PartialDirectiveUser(email: "a@b.c")
    }
}

/// A directive declared by a partial schema must reach the built schema.
///
/// `SchemaBuilder` collects `TypeComponent`s from partials, so a `Directive` that is only
/// a `Component` cannot be contributed this way — applications would then fail validation
/// against a declaration the builder never saw. Applications that live on partial-schema
/// fields have no other place to declare their directive.
@Suite struct PartialSchemaDirectiveTests {
    private final class DirectivePartial: PartialSchema<PartialDirectiveResolver, NoContext> {
        @TypeDefinitions
        override var types: Types {
            Directive("topic", on: .fieldDefinition) {
                DirectiveArgument("names", at: [String].self)
            }
            Type(PartialDirectiveUser.self) {
                Field("email", at: \.email)
            }
        }

        @FieldDefinitions
        override var query: Fields {
            Field("me", at: PartialDirectiveResolver.me)
                .directive("topic", ("names", ["accounts"]))
        }
    }

    @Test func declaresDirectivesFromPartialSchemas() throws {
        let schema = try SchemaBuilder(PartialDirectiveResolver.self, NoContext.self)
            .use(partials: [DirectivePartial()])
            .build()

        let sdl = schema.sdl()
        #expect(sdl.contains("directive @topic(names: [String!]!) on FIELD_DEFINITION"))
        #expect(sdl.contains("@topic(names: [\"accounts\"])"))
    }

    @Test func projectsPartialSchemaFieldsByDirective() throws {
        let schema = try SchemaBuilder(PartialDirectiveResolver.self, NoContext.self)
            .use(partials: [DirectivePartial()])
            .build()

        let view = try schema.projection { _, _, directives in
            directives.contains { $0.name == "topic" && $0.argument("names", contains: "accounts") }
        }
        #expect(view.sdl().contains("me"))
    }
}
