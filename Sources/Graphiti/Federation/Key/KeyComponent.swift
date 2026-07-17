import GraphQL

public protocol KeyComponent<ObjectType, Resolver, Context>: Sendable {
    associatedtype ObjectType: Sendable
    associatedtype Resolver: Sendable
    associatedtype Context: Sendable

    func mapMatchesArguments(_ map: Map, coders: Coders) -> Bool
    func resolveMap(
        resolver: Resolver,
        context: Context,
        map: Map,
        coders: Coders
    ) async throws -> (any Sendable)?
    func validate(againstFields fieldNames: [String]) throws
}
