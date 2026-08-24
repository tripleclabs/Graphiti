import Graphiti
import GraphQL
import Testing

private struct QueryUser: Codable, Sendable {
    let email: String
}

private struct QueryResolver: Sendable {
    func billing(context _: NoContext, arguments _: NoArguments) -> QueryUser {
        QueryUser(email: "a@b.c")
    }

    func search(context _: NoContext, arguments _: NoArguments) -> QueryUser {
        QueryUser(email: "a@b.c")
    }

    func untagged(context _: NoContext, arguments _: NoArguments) -> QueryUser {
        QueryUser(email: "a@b.c")
    }
}

@Suite struct DirectiveQueryTests {
    private func schema() throws -> Schema<QueryResolver, NoContext> {
        try Schema<QueryResolver, NoContext> {
            Directive("theme", on: .fieldDefinition) {
                DirectiveArgument("names", at: [String].self)
            }
            Type(QueryUser.self) { Field("email", at: \.email) }
            Query {
                Field("billing", at: QueryResolver.billing)
                    .directive("theme", ("names", ["billing", "admin"]))
                Field("search", at: QueryResolver.search)
                    .directive("theme", ("names", ["search"]))
                Field("untagged", at: QueryResolver.untagged)
            }
        }
    }

    @Test func rootFieldsAreQueryableByDirectiveValue() throws {
        let matches = try schema().appliedDirectives
            .compactMap { target, directives -> String? in
                guard
                    case let .member(type, member) = target,
                    type == "Query",
                    directives.contains(where: {
                        $0.name == "theme" && $0.argument("names", contains: "billing")
                    })
                else { return nil }
                return member
            }
            .sorted()
        #expect(matches == ["billing"])
    }

    @Test func untaggedFieldsAreAbsentFromTheMap() throws {
        let map = try schema().appliedDirectives
        #expect(map[.member(type: "Query", member: "untagged")] == nil)
    }
}
