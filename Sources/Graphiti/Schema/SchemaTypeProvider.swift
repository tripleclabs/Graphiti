import GraphQL

final class SchemaTypeProvider: TypeProvider {
    var graphQLNameMap: [AnyType: String] = [
        AnyType(Int.self): "Int",
        AnyType(Double.self): "Float",
        AnyType(String.self): "String",
        AnyType(Bool.self): "Boolean",
    ]

    var graphQLTypeMap: [AnyType: GraphQLType] = [
        AnyType(Int.self): GraphQLInt,
        AnyType(Double.self): GraphQLFloat,
        AnyType(String.self): GraphQLString,
        AnyType(Bool.self): GraphQLBoolean,
    ]

    var federatedTypes: [GraphQLObjectType] = []
    var federatedResolvers: [String: GraphQLFieldResolve] = [:]
    var federatedSDL: String?

    var query: GraphQLObjectType?
    var mutation: GraphQLObjectType?
    var subscription: GraphQLObjectType?
    var types: [GraphQLNamedType] = []
    var directives: [GraphQLDirective] = []
    var appliedDirectiveMap: AppliedDirectiveMap = [:]

    /// Locations are tracked separately from the render map because a single
    /// `DirectiveTarget.member` covers object fields, input fields and enum
    /// values; validation has to tell them apart.
    var targetLocations: [DirectiveTarget: DirectiveLocation] = [:]

    func register(
        _ directives: [AppliedDirective],
        at target: DirectiveTarget,
        as location: DirectiveLocation
    ) {
        guard !directives.isEmpty else {
            return
        }
        appliedDirectiveMap[target, default: []].append(contentsOf: directives)
        targetLocations[target] = location
    }

    /// Records the directives a component applies to its own named type.
    ///
    /// Every type-level component reaches the schema through the same loop, so
    /// this runs once there rather than being copied into each `update`.
    /// Directive *declarations* are skipped — their name is a directive, not a type.
    func registerTypeDirectives<Resolver, Context>(for component: Component<Resolver, Context>) {
        guard let location = component.componentType.directiveLocation else {
            return
        }
        register(component.appliedDirectives, at: .type(component.name), as: location)
    }

    func add(type: Any.Type, as graphQLType: GraphQLNamedType) throws {
        try map(type, to: graphQLType)
        types.append(graphQLType)
    }
}
