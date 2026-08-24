import GraphQL

public struct SchemaError: Error, Equatable {
    let description: String
}

public final class Schema<Resolver: Sendable, Context: Sendable>: Sendable {
    public let schema: GraphQLSchema
    /// Every directive application in this schema, keyed by schema location.
    ///
    /// Filter this to answer questions like "which root fields carry this
    /// directive with this value?" — see `AppliedDirective.argument(_:contains:)`.
    public let appliedDirectives: AppliedDirectiveMap

    public init(
        coders: Coders = Coders(),
        federatedSDL: String? = nil,
        components: [Component<Resolver, Context>]
    ) throws {
        let typeProvider = SchemaTypeProvider()
        typeProvider.federatedSDL = federatedSDL

        for component in components {
            try component.update(typeProvider: typeProvider, coders: coders)
            typeProvider.registerTypeDirectives(for: component)
        }

        guard typeProvider.query != nil || !typeProvider.federatedResolvers.isEmpty else {
            throw SchemaError(
                description: "Schema must contain at least 1 query or federated resolver"
            )
        }

        try validateAppliedDirectives(
            typeProvider.appliedDirectiveMap,
            locations: typeProvider.targetLocations,
            against: specifiedDirectives + typeProvider.directives
        )

        let schema = try GraphQLSchema(
            query: typeProvider.query,
            mutation: typeProvider.mutation,
            subscription: typeProvider.subscription,
            types: typeProvider.types,
            directives: specifiedDirectives + typeProvider.directives
        )

        // GraphQL caches schema validation lazily without synchronizing the initial write.
        // Validate before publishing the Sendable schema so concurrent requests only read it.
        let validationErrors = try validateSchema(schema: schema)
        guard validationErrors.isEmpty else {
            throw GraphQLErrors(validationErrors)
        }

        appliedDirectives = typeProvider.appliedDirectiveMap
        self.schema = schema
    }

    /// Wraps an already-built GraphQL schema. Used by projection, which
    /// constructs its schema rather than building one from components.
    init(schema: GraphQLSchema, appliedDirectives: AppliedDirectiveMap) {
        self.schema = schema
        self.appliedDirectives = appliedDirectives
    }
}

public extension Schema {
    /// The schema rendered as SDL, including any custom directives declared and
    /// applied through the DSL.
    ///
    /// - Note: Calling `printSchema(schema:)` on the underlying `GraphQLSchema`
    ///   will *not* include applied directives. They are held alongside the
    ///   schema rather than on its type objects, so they must be passed to the
    ///   printer explicitly, which is what this does.
    func sdl() -> String {
        printSchema(schema: schema, appliedDirectives: appliedDirectives)
    }
}

public extension Schema {
    convenience init(
        coders: Coders = Coders(),
        federatedSDL: String? = nil,
        @ComponentBuilder<Resolver, Context> _ components: () -> Component<Resolver, Context>
    ) throws {
        try self.init(
            coders: coders,
            federatedSDL: federatedSDL,
            components: [components()]
        )
    }

    convenience init(
        coders: Coders = Coders(),
        federatedSDL: String? = nil,
        @ComponentBuilder<Resolver, Context> _ components: () -> [Component<Resolver, Context>]
    ) throws {
        try self.init(
            coders: coders,
            federatedSDL: federatedSDL,
            components: components()
        )
    }

    func execute(
        request: String,
        resolver: Resolver,
        context: Context,
        variables: [String: Map] = [:],
        operationName: String? = nil,
        validationRules: [@Sendable (ValidationContext) -> Visitor] = []
    ) async throws -> GraphQLResult {
        return try await graphql(
            schema: schema,
            request: request,
            rootValue: resolver,
            context: context,
            variableValues: variables,
            operationName: operationName,
            validationRules: GraphQL.specifiedRules + validationRules
        )
    }

    func subscribe(
        request: String,
        resolver: Resolver,
        context: Context,
        variables: [String: Map] = [:],
        operationName: String? = nil,
        validationRules: [@Sendable (ValidationContext) -> Visitor] = []
    ) async throws -> Result<AsyncThrowingStream<GraphQLResult, Error>, GraphQLErrors> {
        return try await graphqlSubscribe(
            schema: schema,
            request: request,
            rootValue: resolver,
            context: context,
            variableValues: variables,
            operationName: operationName,
            validationRules: GraphQL.specifiedRules + validationRules
        )
    }
}
