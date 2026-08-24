@testable import Graphiti
import GraphQL
import Testing

private struct ValUser: Codable, Sendable {
    let email: String
}

private enum ValRole: String, Codable, Sendable {
    case admin = "ADMIN"
}

private struct ValidationResolver: Sendable {
    func user(context _: NoContext, arguments _: NoArguments) -> ValUser {
        ValUser(email: "a@b.c")
    }
}

@Suite struct DirectiveValidationTests {
    private func build(
        @ComponentBuilder<ValidationResolver, NoContext> _ components: ()
            -> [Component<ValidationResolver, NoContext>]
    ) throws -> Schema<ValidationResolver, NoContext> {
        try Schema<ValidationResolver, NoContext>(components: components())
    }

    @Test func rejectsUndeclaredDirective() throws {
        #expect(throws: SchemaError.self) {
            try build {
                Type(ValUser.self) { Field("email", at: \.email) }.directive("nope")
                Query { Field("user", at: ValidationResolver.user) }
            }
        }
    }

    @Test func rejectsDirectiveAtIllegalLocation() throws {
        #expect(throws: SchemaError.self) {
            try build {
                Directive("auth", on: .fieldDefinition)
                Type(ValUser.self) { Field("email", at: \.email) }.directive("auth")
                Query { Field("user", at: ValidationResolver.user) }
            }
        }
    }

    @Test func rejectsFieldDirectiveAppliedToEnumValue() throws {
        // .member covers fields, input fields and enum values; the recorded
        // location must be precise enough to tell them apart.
        #expect(throws: SchemaError.self) {
            try build {
                Directive("auth", on: .fieldDefinition)
                Enum(ValRole.self) { Value(ValRole.admin).directive("auth") }
                Type(ValUser.self) { Field("email", at: \.email) }
                Query { Field("user", at: ValidationResolver.user) }
            }
        }
    }

    @Test func rejectsUnknownArgumentName() throws {
        #expect(throws: SchemaError.self) {
            try build {
                Directive("model", on: .object) { DirectiveArgument("table", at: String.self) }
                Type(ValUser.self) { Field("email", at: \.email) }
                    .directive("model", ("tabel", "users"))
                Query { Field("user", at: ValidationResolver.user) }
            }
        }
    }

    @Test func rejectsMissingRequiredArgument() throws {
        // String.self maps to String! (non-null, no default), so omitting it must throw.
        #expect(throws: SchemaError.self) {
            try build {
                Directive("model", on: .object) { DirectiveArgument("table", at: String.self) }
                Type(ValUser.self) { Field("email", at: \.email) }.directive("model")
                Query { Field("user", at: ValidationResolver.user) }
            }
        }
    }

    @Test func rejectsUncoercibleArgumentValue() throws {
        #expect(throws: SchemaError.self) {
            try build {
                Directive("count", on: .object) { DirectiveArgument("n", at: Int.self) }
                Type(ValUser.self) { Field("email", at: \.email) }
                    .directive("count", ("n", "not a number"))
                Query { Field("user", at: ValidationResolver.user) }
            }
        }
    }

    @Test func rejectsNullForNonNullArgument() throws {
        #expect(throws: SchemaError.self) {
            try build {
                Directive("model", on: .object) { DirectiveArgument("table", at: String.self) }
                Type(ValUser.self) { Field("email", at: \.email) }
                    .directive("model", ("table", nil))
                Query { Field("user", at: ValidationResolver.user) }
            }
        }
    }

    @Test func acceptsNullForNullableArgument() throws {
        let schema = try build {
            Directive("model", on: .object) { DirectiveArgument("table", at: String?.self) }
            Type(ValUser.self) { Field("email", at: \.email) }
                .directive("model", ("table", nil))
            Query { Field("user", at: ValidationResolver.user) }
        }
        #expect(schema.sdl().contains("@model(table: null)"))
    }

    @Test func rejectsRepeatedNonRepeatableDirective() throws {
        #expect(throws: SchemaError.self) {
            try build {
                Directive("model", on: .object)
                Type(ValUser.self) { Field("email", at: \.email) }
                    .directive("model")
                    .directive("model")
                Query { Field("user", at: ValidationResolver.user) }
            }
        }
    }

    @Test func acceptsRepeatedRepeatableDirective() throws {
        let schema = try build {
            Directive("tag", on: .object, repeatable: true) {
                DirectiveArgument("name", at: String.self)
            }
            Type(ValUser.self) { Field("email", at: \.email) }
                .directive("tag", ("name", "a"))
                .directive("tag", ("name", "b"))
            Query { Field("user", at: ValidationResolver.user) }
        }
        #expect(schema.sdl().contains("@tag(name: \"a\") @tag(name: \"b\")"))
    }
}
