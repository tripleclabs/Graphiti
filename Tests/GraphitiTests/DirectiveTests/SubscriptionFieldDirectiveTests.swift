@testable import Graphiti
import GraphQL
import Testing

private struct SubSource: Sendable {}
private struct SubArgs: Codable, Sendable {
    let channel: String
}

/// `SubscriptionField` is a second `FieldComponent` subclass alongside `Field`,
/// so it needs its own `argumentDirectives()` override — without it, directives
/// applied to a subscription field's arguments are silently dropped.
@Suite struct SubscriptionFieldDirectiveTests {
    @Test func subscriptionFieldExposesArgumentDirectives() throws {
        let field = SubscriptionField<
            SubSource, SubSource, NoContext, String, SubArgs, AsyncStream<SubSource>
        >(
            name: "events",
            arguments: [Argument("channel", at: \SubArgs.channel).directive("tag")],
            resolve: { _ in { _, _ in "x" } },
            subscribe: { _ in { _, _ in AsyncStream { $0.finish() } } }
        )

        let directives = field.argumentDirectives()
        let entry = try #require(directives.first)
        #expect(directives.count == 1)
        #expect(entry.0 == "channel")
        #expect(entry.1.map(\.name) == ["tag"])
    }
}
