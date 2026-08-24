import GraphQL

public extension Schema {
    /// A schema containing only the root fields satisfying `keep`, plus every
    /// type reachable from them.
    ///
    /// The result executes as well as prints — resolvers and subscription
    /// sources are preserved — and carries a directive map reduced to the
    /// elements it actually contains.
    ///
    /// Nothing is cached: each call builds a new schema, and the caller decides
    /// how long to hold it.
    ///
    /// - Parameter keep: called with the root type name ("Query", "Mutation",
    ///   "Subscription"), the field name, and the directives applied to it.
    /// - Throws: `SchemaError` when no root query fields match, since GraphQL
    ///   requires a query type.
    func projection(
        rootFieldsWhere keep: (String, String, [AppliedDirective]) -> Bool
    ) throws -> Schema<Resolver, Context> {
        let map = appliedDirectives

        let projected: GraphQLSchema
        do {
            projected = try schema.projected { rootType, field in
                keep(rootType, field, map[.member(type: rootType, member: field)] ?? [])
            }
        } catch let error as GraphQLError {
            throw SchemaError(description: error.message)
        }

        return Schema(
            schema: projected,
            appliedDirectives: map.filter { projected.contains($0.key) }
        )
    }
}
