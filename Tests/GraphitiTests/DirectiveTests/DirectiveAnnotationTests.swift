@testable import Graphiti
import GraphQL
import Testing

private struct DirectiveUser: Codable, Sendable {
    let email: String
}

private struct AnnotationResolver: Sendable {}

@Suite struct DirectiveAnnotationTests {
    @Test func fieldComponentRecordsAppliedDirectives() throws {
        let field = Field<DirectiveUser, NoContext, String, NoArguments>("email", at: \.email)
            .directive("unique")
            .directive("tag", ("name", "pii"))

        #expect(field.appliedDirectives.count == 2)
        #expect(field.appliedDirectives[0].name == "unique")
        #expect(field.appliedDirectives[0].arguments.isEmpty)
        #expect(field.appliedDirectives[1] == AppliedDirective(
            name: "tag",
            arguments: [("name", "pii")]
        ))
    }

    @Test func typeComponentRecordsAppliedDirectives() throws {
        let type = Type<AnnotationResolver, NoContext, DirectiveUser>(DirectiveUser.self) {
            Field("email", at: \.email)
        }
        .directive("model", ("table", "users"))

        #expect(type.appliedDirectives == [
            AppliedDirective(name: "model", arguments: [("table", "users")]),
        ])
    }

    @Test func modifiersPreserveArgumentOrder() throws {
        let field = Field<DirectiveUser, NoContext, String, NoArguments>("email", at: \.email)
            .directive("constraint", ("min", 1), ("max", 10))

        let names = field.appliedDirectives[0].arguments.map { $0.0 }
        #expect(names == ["min", "max"])
    }

    @Test func argumentComponentRecordsAppliedDirectives() throws {
        let argument = Argument<DirectiveFilter, String>("q", at: \.q)
            .directive("unique")
        #expect(argument.appliedDirectives.map(\.name) == ["unique"])
    }

    @Test func enumValueRecordsAppliedDirectives() throws {
        let value = Value(DirectiveRole.admin).directive("unique")
        #expect(value.appliedDirectives.map(\.name) == ["unique"])
    }

    @Test func inputFieldRecordsAppliedDirectives() throws {
        let field = InputField<DirectiveFilter, NoContext, String>("q", at: \DirectiveFilter.q)
            .directive("unique")
        #expect(field.appliedDirectives.map(\.name) == ["unique"])
    }
}

private enum DirectiveRole: String, Codable, Sendable {
    case admin = "ADMIN"
}

private struct DirectiveFilter: Codable, Sendable {
    let q: String
}
