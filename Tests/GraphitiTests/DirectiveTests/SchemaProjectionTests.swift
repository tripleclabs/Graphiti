@testable import Graphiti
import GraphQL
import Testing

private struct ProjUser: Codable, Sendable {
    let email: String
}

private struct ProjProduct: Codable, Sendable {
    let sku: String
}

private struct ProjResolver: Sendable {
    func billing(context _: NoContext, arguments _: NoArguments) -> ProjUser {
        ProjUser(email: "a@b.c")
    }

    func search(context _: NoContext, arguments _: NoArguments) -> ProjProduct {
        ProjProduct(sku: "sku-1")
    }

    func pay(context _: NoContext, arguments _: NoArguments) -> String { "ok" }
}

@Suite struct GraphitiSchemaProjectionTests {
    private func schema() throws -> Schema<ProjResolver, NoContext> {
        try Schema<ProjResolver, NoContext> {
            Directive("theme", on: .fieldDefinition) {
                DirectiveArgument("names", at: [String].self)
            }
            Type(ProjUser.self) { Field("email", at: \.email) }
            Type(ProjProduct.self) { Field("sku", at: \.sku) }
            Query {
                Field("billing", at: ProjResolver.billing)
                    .directive("theme", ("names", ["billing"]))
                Field("search", at: ProjResolver.search)
                    .directive("theme", ("names", ["search"]))
            }
            Mutation {
                Field("pay", at: ProjResolver.pay)
                    .directive("theme", ("names", ["billing"]))
            }
        }
    }

    private func billingView() throws -> Schema<ProjResolver, NoContext> {
        try schema().projection { _, _, directives in
            directives.contains { $0.name == "theme" && $0.argument("names", contains: "billing") }
        }
    }

    @Test func keepsOnlyMatchingRootFields() throws {
        let sdl = try billingView().sdl()
        #expect(sdl.contains("billing: ProjUser!"))
        #expect(!sdl.contains("search:"))
    }

    @Test func includesReachableTypesAndExcludesOthers() throws {
        let sdl = try billingView().sdl()
        #expect(sdl.contains("type ProjUser"))
        #expect(!sdl.contains("type ProjProduct"))
    }

    @Test func projectionSpansMutationRoots() throws {
        let sdl = try billingView().sdl()
        #expect(sdl.contains("type Mutation"))
        #expect(sdl.contains("pay: String!"))
    }

    @Test func predicateCanScopeToOneOperationKind() throws {
        let queryOnly = try schema().projection { rootType, _, directives in
            rootType == "Query" &&
                directives.contains { $0.name == "theme" && $0.argument("names", contains: "billing") }
        }
        #expect(!queryOnly.sdl().contains("type Mutation"))
    }

    @Test func projectionExecutes() async throws {
        let result = try await billingView().execute(
            request: "{ billing { email } }",
            resolver: ProjResolver(),
            context: NoContext()
        )
        #expect(result.errors.isEmpty)
        #expect(result.data?["billing"]["email"].string == "a@b.c")
    }

    @Test func projectionKeepsDirectivesOnSurvivingElements() throws {
        let map = try billingView().appliedDirectives
        #expect(map[.member(type: "Query", member: "billing")]?.map(\.name) == ["theme"])
    }

    @Test func projectionDropsDirectivesOnAbsentElements() throws {
        let map = try billingView().appliedDirectives
        #expect(map[.member(type: "Query", member: "search")] == nil)
    }

    @Test func projectionRendersDirectivesInSDL() throws {
        #expect(try billingView().sdl().contains("@theme(names: [\"billing\"])"))
    }

    @Test func projectionIsDeterministic() throws {
        #expect(try billingView().sdl() == billingView().sdl())
    }

    @Test func mutationOnlyThemeThrows() throws {
        // GraphQL requires a query root, so a view of only mutations cannot
        // stand alone — every theme needs at least one query field.
        #expect(throws: SchemaError.self) {
            try schema().projection { rootType, _, _ in rootType == "Mutation" }
        }
    }

    @Test func throwsWhenNoFieldsMatchAtAll() throws {
        #expect(throws: SchemaError.self) {
            try schema().projection { _, _, directives in
                directives.contains { $0.name == "theme" && $0.argument("names", contains: "nothing") }
            }
        }
    }
}
