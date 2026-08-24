import Graphiti
import GraphQL
import Testing

private struct SchemaDirectiveUser: Codable, Sendable {
    let email: String
}

private struct SchemaDirectiveResolver: Sendable {
    func me(context _: NoContext, arguments _: NoArguments) -> SchemaDirectiveUser {
        SchemaDirectiveUser(email: "a@b.c")
    }
}

/// Directives applied to the schema definition itself.
///
/// GraphQL allows directives on the `schema { }` block, and the printer renders
/// them, but no component corresponded to that location — every other component
/// declares a named type, so `DirectiveTarget.schema` was never populated and a
/// directive declared `on: .schema` could be declared and never applied.
///
/// `SchemaDirectives` is the component for that location. It declares no type of
/// its own; it exists only to carry applications.
@Suite struct SchemaDirectiveTests {
    private final class SchemaDirectivePartial: PartialSchema<SchemaDirectiveResolver, NoContext> {
        @TypeDefinitions
        override var types: Types {
            Directive("validator", on: .schema, repeatable: true) {
                DirectiveArgument("name", at: String.self)
                DirectiveArgument("operation", at: String?.self)
            }
            SchemaDirectives()
                .directive("validator", ("name", "lua"), ("operation", "validate"))
                .directive("validator", ("name", "sql"), ("operation", "validate"))
            Type(SchemaDirectiveUser.self) {
                Field("email", at: \.email)
            }
        }

        @FieldDefinitions
        override var query: Fields {
            Field("me", at: SchemaDirectiveResolver.me)
        }
    }

    private func build() throws -> Schema<SchemaDirectiveResolver, NoContext> {
        try SchemaBuilder(SchemaDirectiveResolver.self, NoContext.self)
            .use(partials: [SchemaDirectivePartial()])
            .build()
    }

    @Test func rendersDirectivesOnTheSchemaBlock() throws {
        let sdl = try build().sdl()

        #expect(sdl.contains("directive @validator"))
        #expect(sdl.contains(#"@validator(name: "lua", operation: "validate")"#))
        #expect(sdl.contains(#"@validator(name: "sql", operation: "validate")"#))
    }

    /// Repeatable applications must all survive, in the order written, so the
    /// emitted SDL is byte-stable and safe to pin by hash.
    @Test func keepsRepeatedApplicationsInOrder() throws {
        let sdl = try build().sdl()

        guard
            let lua = sdl.range(of: #"@validator(name: "lua""#),
            let sql = sdl.range(of: #"@validator(name: "sql""#)
        else {
            Issue.record("both applications should be present")
            return
        }
        #expect(lua.lowerBound < sql.lowerBound)
    }

    /// The applications are addressable as `.schema`, which is what a consumer
    /// reading `appliedDirectives` needs in order to find them at all.
    @Test func targetsTheSchemaLocation() throws {
        let schema = try build()

        let applied = schema.appliedDirectives[.schema] ?? []
        #expect(applied.count == 2)
        #expect(applied.allSatisfy { $0.name == "validator" })
    }

    /// `SchemaDirectives` declares no type of its own, so it must not leak a
    /// stray named type into the schema.
    @Test func declaresNoTypeOfItsOwn() throws {
        let sdl = try build().sdl()

        #expect(!sdl.contains("type SchemaDirectives"))
    }
}
