@testable import Graphiti
import GraphQL
import Testing

private struct DeclUser: Codable, Sendable {
    let email: String
}

private struct DeclarationResolver: Sendable {
    func user(context _: NoContext, arguments _: NoArguments) -> DeclUser {
        DeclUser(email: "a@b.c")
    }
}

@Suite struct DirectiveDeclarationTests {
    private func schema() throws -> Schema<DeclarationResolver, NoContext> {
        try Schema<DeclarationResolver, NoContext> {
            Directive("model", on: .object) {
                DirectiveArgument("table", at: String.self)
            }
            Directive("tag", on: .fieldDefinition, .object, repeatable: true) {
                DirectiveArgument("name", at: String.self)
            }
            Type(DeclUser.self) {
                Field("email", at: \.email)
            }
            Query {
                Field("user", at: DeclarationResolver.user)
            }
        }
    }

    @Test func declaredDirectivesAppearInSchema() throws {
        let names = try schema().schema.directives.map { $0.name }
        #expect(names.contains("model"))
        #expect(names.contains("tag"))
    }

    @Test func specifiedDirectivesArePreserved() throws {
        let names = try schema().schema.directives.map { $0.name }
        #expect(names.contains("skip"))
        #expect(names.contains("include"))
        #expect(names.contains("deprecated"))
        #expect(names.contains("specifiedBy"))
    }

    @Test func declaredDirectiveCarriesLocationsAndRepeatability() throws {
        let directives = try schema().schema.directives
        let tag = try #require(directives.first { $0.name == "tag" })
        #expect(tag.isRepeatable)
        #expect(tag.locations.contains(.fieldDefinition))
        #expect(tag.locations.contains(.object))

        let model = try #require(directives.first { $0.name == "model" })
        #expect(!model.isRepeatable)
        #expect(model.locations == [.object])
    }

    @Test func declaredDirectiveCarriesArguments() throws {
        let directives = try schema().schema.directives
        let model = try #require(directives.first { $0.name == "model" })
        #expect(model.args.count == 1)
        #expect(model.args[0].name == "table")
        #expect(model.args[0].type is GraphQLNonNull)
    }
}
