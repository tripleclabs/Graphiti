@testable import Graphiti
import GraphQL
import Testing

private struct SideUser: Codable, Sendable {
    let email: String

    func search(context _: NoContext, arguments _: SearchArgs) -> String {
        email
    }
}

private struct SideFilter: Codable, Sendable {
    let q: String
}

private enum SideRole: String, Codable, Sendable {
    case admin = "ADMIN"
}

private struct SideResolver: Sendable {
    func user(context _: NoContext, arguments _: NoArguments) -> SideUser {
        SideUser(email: "a@b.c")
    }
}

private struct SearchArgs: Codable, Sendable {
    let term: String
}

@Suite struct DirectiveSideTableTests {
    private func provider() throws -> SchemaTypeProvider {
        let provider = SchemaTypeProvider()
        let coders = Coders()
        let components: [Component<SideResolver, NoContext>] = [
            Directive("model", on: .object) {
                DirectiveArgument("table", at: String.self)
            },
            Directive("unique", on: .fieldDefinition, .enumValue, .inputFieldDefinition),
            Directive("tag", on: .argumentDefinition),
            Enum(SideRole.self) {
                Value(SideRole.admin).directive("unique")
            },
            Input(SideFilter.self) {
                InputField("q", at: \.q).directive("unique")
            },
            Type(SideUser.self) {
                Field("email", at: \.email).directive("unique")
            }
            .directive("model", ("table", "users")),
            Query {
                Field("user", at: SideResolver.user)
            },
        ]
        for component in components {
            try component.update(typeProvider: provider, coders: coders)
            provider.registerTypeDirectives(for: component)
        }
        return provider
    }

    @Test func typeLevelDirectiveIsRegistered() throws {
        let map = try provider().appliedDirectiveMap
        let applied = try #require(map[.type("SideUser")])
        #expect(applied == [AppliedDirective(name: "model", arguments: [("table", "users")])])
    }

    @Test func fieldLevelDirectiveIsRegistered() throws {
        let map = try provider().appliedDirectiveMap
        let applied = try #require(map[.member(type: "SideUser", member: "email")])
        #expect(applied.map(\.name) == ["unique"])
    }

    @Test func enumValueDirectiveIsRegistered() throws {
        let map = try provider().appliedDirectiveMap
        let applied = try #require(map[.member(type: "SideRole", member: "ADMIN")])
        #expect(applied.map(\.name) == ["unique"])
    }

    @Test func inputFieldDirectiveIsRegistered() throws {
        let map = try provider().appliedDirectiveMap
        let applied = try #require(map[.member(type: "SideFilter", member: "q")])
        #expect(applied.map(\.name) == ["unique"])
    }

    @Test func fieldArgumentDirectiveIsRegistered() throws {
        let provider = SchemaTypeProvider()
        let coders = Coders()
        let type = Type<SideResolver, NoContext, SideUser>(SideUser.self) {
            Field("search", at: SideUser.search) {
                Argument("term", at: \SearchArgs.term).directive("tag")
            }
        }
        try type.update(typeProvider: provider, coders: coders)
        provider.registerTypeDirectives(for: type)

        let applied = try #require(
            provider.appliedDirectiveMap[
                .argument(type: "SideUser", field: "search", argument: "term")
            ]
        )
        #expect(applied.map(\.name) == ["tag"])
    }

    @Test func unannotatedLocationsAreAbsent() throws {
        let map = try provider().appliedDirectiveMap
        #expect(map[.type("Query")] == nil)
    }
}
