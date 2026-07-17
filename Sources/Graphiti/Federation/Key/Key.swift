import GraphQL

public final class Key<
    ObjectType: Sendable,
    Resolver: Sendable,
    Context: Sendable,
    Arguments: Codable & Sendable
>: KeyComponent {
    let argumentNames: [String]
    let resolve: AsyncResolve<Resolver, Context, Arguments, ObjectType?>

    public func mapMatchesArguments(_ map: Map, coders: Coders) -> Bool {
        let args = try? coders.decoder.decode(Arguments.self, from: map)
        return args != nil
    }

    public func resolveMap(
        resolver: Resolver,
        context: Context,
        map: Map,
        coders: Coders
    ) async throws -> (any Sendable)? {
        let arguments = try coders.decoder.decode(Arguments.self, from: map)
        return try await resolve(resolver)(context, arguments)
    }

    public func validate(
        againstFields fieldNames: [String]
    ) throws {
        // Ensure that every argument is included in the provided field list
        for name in argumentNames {
            if !fieldNames.contains(name) {
                throw GraphQLError(message: "Argument name not found in type fields: \(name)")
            }
        }
    }

    init(
        arguments: [ArgumentComponent<Arguments>],
        asyncResolve: @escaping AsyncResolve<Resolver, Context, Arguments, ObjectType?>
    ) {
        argumentNames = arguments.map { $0.getName() }
        resolve = asyncResolve
    }

    convenience init(
        arguments: [ArgumentComponent<Arguments>],
        syncResolve: @escaping SyncResolve<Resolver, Context, Arguments, ObjectType?>
    ) {
        let asyncResolve: AsyncResolve<Resolver, Context, Arguments, ObjectType?> = { type in
            { context, arguments in
                try syncResolve(type)(context, arguments)
            }
        }

        self.init(arguments: arguments, asyncResolve: asyncResolve)
    }
}
