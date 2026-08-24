@testable import Graphiti
import GraphQL
import Testing

// MARK: - Fixtures

struct Tick: Codable, Sendable {
    let channel: String
    let value: String
}

struct TickError: Error, Equatable {
    let reason: String
}

/// A pub/sub that can deliver events, finish cleanly, or fail — the three ways
/// a real source stream ends. One instance per test, no shared state.
actor TestPubSub: Sendable {
    private var continuations: [AsyncThrowingStream<Tick, Error>.Continuation] = []

    func subscribe() -> AsyncThrowingStream<Tick, Error> {
        AsyncThrowingStream<Tick, Error> { continuation in
            continuations.append(continuation)
        }
    }

    func publish(_ tick: Tick) {
        for continuation in continuations {
            continuation.yield(tick)
        }
    }

    func finish() {
        for continuation in continuations {
            continuation.finish()
        }
    }

    func fail(_ error: Error) {
        for continuation in continuations {
            continuation.finish(throwing: error)
        }
    }

    var subscriberCount: Int { continuations.count }
}

final class TickContext: Sendable {
    let pubsub = TestPubSub()
}

struct ChannelArguments: Codable, Sendable {
    let channel: String
}

struct TickResolver: Sendable {
    func placeholder(context _: TickContext, arguments _: NoArguments) -> String { "ok" }

    func ticks(
        context: TickContext,
        arguments _: NoArguments
    ) async -> AsyncThrowingStream<Tick, Error> {
        await context.pubsub.subscribe()
    }

    /// The subscribe half receives the field's arguments too, so a real
    /// implementation can filter the source at subscription time.
    func ticksInChannel(
        context: TickContext,
        arguments _: ChannelArguments
    ) async -> AsyncThrowingStream<Tick, Error> {
        await context.pubsub.subscribe()
    }

    /// Subscribe fails before any stream exists — the client should never get a stream.
    func refusedTicks(
        context _: TickContext,
        arguments _: NoArguments
    ) async throws -> AsyncThrowingStream<Tick, Error> {
        throw TickError(reason: "subscription refused")
    }

}

/// The `at:` resolver of a subscription field maps each *source event*, so these
/// hang off `Tick` rather than off the resolver.
extension Tick {
    /// Per-event resolution that fails, exercising the resolve half rather than
    /// the subscribe half.
    func brokenTransform(context _: TickContext, arguments _: NoArguments) throws -> String {
        throw TickError(reason: "cannot transform tick")
    }

    func channelOf(context _: TickContext, arguments: ChannelArguments) -> String {
        arguments.channel
    }
}

struct TickAPI: API {
    let resolver = TickResolver()

    let schema: Schema<TickResolver, TickContext> = try! Schema<TickResolver, TickContext> {
        Type(Tick.self) {
            Field("channel", at: \.channel)
            Field("value", at: \.value)
        }

        Query {
            Field("placeholder", at: TickResolver.placeholder)
        }

        Subscription {
            SubscriptionField("ticks", as: Tick.self, atSub: TickResolver.ticks)
            SubscriptionField("refused", as: Tick.self, atSub: TickResolver.refusedTicks)
            SubscriptionField(
                "broken",
                at: Tick.brokenTransform,
                atSub: TickResolver.ticks
            )
            SubscriptionField(
                "echoChannel",
                at: Tick.channelOf,
                atSub: TickResolver.ticksInChannel
            ) {
                Argument("channel", at: \.channel)
            }
        }
    }
}

// MARK: - Tests

@Suite struct SubscriptionDeliveryTests {
    private let api = TickAPI()

    private func stream(
        _ request: String,
        _ context: TickContext
    ) async throws -> AsyncThrowingStream<GraphQLResult, Error> {
        try await api.subscribe(request: request, context: context).get()
    }

    /// A subscription that delivered only its first event would pass every test
    /// that publishes once. This is the core semantic of a subscription.
    @Test func deliversMultipleEventsInOrder() async throws {
        let context = TickContext()
        let subscription = try await stream(
            "subscription { ticks { value } }",
            context
        )
        var iterator = subscription.makeAsyncIterator()

        for value in ["one", "two", "three"] {
            await context.pubsub.publish(Tick(channel: "a", value: value))
        }

        var received: [String] = []
        for _ in 0 ..< 3 {
            let result = try await iterator.next()
            received.append(try #require(result?.data?["ticks"]["value"].string))
        }

        #expect(received == ["one", "two", "three"])
    }

    /// Determines whether a client connection can ever be torn down cleanly.
    @Test func finishingSourceStreamFinishesSubscription() async throws {
        let context = TickContext()
        let subscription = try await stream("subscription { ticks { value } }", context)
        var iterator = subscription.makeAsyncIterator()

        await context.pubsub.publish(Tick(channel: "a", value: "one"))
        _ = try await iterator.next()

        await context.pubsub.finish()

        let terminal = try await iterator.next()
        #expect(terminal == nil)
    }

    @Test func eachSubscriberReceivesEveryEvent() async throws {
        let context = TickContext()
        let first = try await stream("subscription { ticks { value } }", context)
        let second = try await stream("subscription { ticks { value } }", context)
        var firstIterator = first.makeAsyncIterator()
        var secondIterator = second.makeAsyncIterator()

        #expect(await context.pubsub.subscriberCount == 2)
        await context.pubsub.publish(Tick(channel: "a", value: "broadcast"))

        let a = try await firstIterator.next()
        let b = try await secondIterator.next()
        #expect(a?.data?["ticks"]["value"].string == "broadcast")
        #expect(b?.data?["ticks"]["value"].string == "broadcast")
    }

    @Test func subscriptionFieldReceivesArguments() async throws {
        let context = TickContext()
        let subscription = try await stream(
            """
            subscription { echoChannel(channel: "billing") }
            """,
            context
        )
        var iterator = subscription.makeAsyncIterator()

        await context.pubsub.publish(Tick(channel: "ignored", value: "x"))

        let result = try await iterator.next()
        #expect(result?.data?["echoChannel"].string == "billing")
    }
}

@Suite struct SubscriptionFailureTests {
    private let api = TickAPI()

    /// The stream type is AsyncThrowingStream; this exercises the throwing half.
    @Test func sourceStreamErrorPropagatesToSubscriber() async throws {
        let context = TickContext()
        let subscription = try await api.subscribe(
            request: "subscription { ticks { value } }",
            context: context
        ).get()
        var iterator = subscription.makeAsyncIterator()

        await context.pubsub.fail(TickError(reason: "upstream died"))

        await #expect(throws: TickError.self) {
            _ = try await iterator.next()
        }
    }

    /// A subscribe resolver that throws must surface as a failed subscribe, not
    /// as a stream that silently never yields.
    @Test func failingSubscribeResolverReturnsFailure() async throws {
        let context = TickContext()
        let outcome = try await api.subscribe(
            request: "subscription { refused { value } }",
            context: context
        )

        switch outcome {
        case .success:
            Issue.record("Expected the subscribe resolver's error to fail the subscription")
        case let .failure(errors):
            #expect(!errors.errors.isEmpty)
        }
    }

    /// Per-event resolution failure is different from subscribe failure: the
    /// stream is live, and the error belongs in the payload.
    @Test func resolverErrorArrivesInThePayload() async throws {
        let context = TickContext()
        let subscription = try await api.subscribe(
            request: "subscription { broken }",
            context: context
        ).get()
        var iterator = subscription.makeAsyncIterator()

        await context.pubsub.publish(Tick(channel: "a", value: "one"))

        let result = try await iterator.next()
        let payload = try #require(result)
        #expect(!payload.errors.isEmpty)
        #expect(payload.errors.first?.message.contains("cannot transform tick") == true)
    }

    /// The GraphQL spec allows exactly one root field in a subscription, but
    /// `SingleFieldSubscriptionsRule` is commented out of the GraphQL layer's
    /// `SpecifiedRules.swift` and was never implemented. This pins what actually
    /// happens today: the operation is accepted, one source stream is created,
    /// and every root field resolves off it into a single payload.
    ///
    /// Change this test if that rule is ever implemented — the spec-correct
    /// outcome is a validation failure.
    @Test func multipleRootFieldsAreAcceptedDespiteTheSpec() async throws {
        let context = TickContext()
        let subscription = try await api.subscribe(
            request: "subscription { ticks { value } echoChannel(channel: \"a\") }",
            context: context
        ).get()
        var iterator = subscription.makeAsyncIterator()

        await context.pubsub.publish(Tick(channel: "a", value: "one"))

        let payload = try #require(try await iterator.next())
        #expect(payload.errors.isEmpty)
        #expect(payload.data?["ticks"]["value"].string == "one")
        #expect(payload.data?["echoChannel"].string == "a")
    }
}
