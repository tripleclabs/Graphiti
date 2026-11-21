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
    /// Named types in registration order. Append-only: added through
    /// `appendType(_:)`, which keeps the name index in step, and read in full
    /// through `allTypes()`.
    private var typeList: [GraphQLNamedType] = []
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

    /// Records the directives applied to a set of fields and their arguments.
    ///
    /// Object fields reach the schema through five components (`Type`,
    /// `Interface`, `Query`, `Mutation`, `Subscription`), so this lives here
    /// rather than being copied into each of them.
    func registerFieldDirectives<ObjectType, Context>(
        _ fields: [FieldComponent<ObjectType, Context>],
        onType typeName: String
    ) {
        for field in fields {
            let fieldName = field.getName()
            register(
                field.appliedDirectives,
                at: .member(type: typeName, member: fieldName),
                as: .fieldDefinition
            )
            for (argumentName, directives) in field.argumentDirectives() {
                register(
                    directives,
                    at: .argument(type: typeName, field: fieldName, argument: argumentName),
                    as: .argumentDefinition
                )
            }
        }
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
        // `SchemaDirectives` declares no named type; its applications belong to
        // the schema definition rather than to a type called "".
        let target: DirectiveTarget = component.componentType == .schemaDirectives
            ? .schema
            : .type(component.name)
        register(component.appliedDirectives, at: target, as: location)
    }

    func add(type: Any.Type, as graphQLType: GraphQLNamedType) throws {
        try map(type, to: graphQLType)
        appendType(graphQLType)
    }

    // MARK: Type list and name index

    private static let builtInScalars: [String: GraphQLNamedType] = [
        "String": GraphQLString, "Int": GraphQLInt, "Float": GraphQLFloat,
        "Boolean": GraphQLBoolean, "ID": GraphQLID,
    ]

    /// The registered types keyed by name, over the built-in scalars, updated
    /// on each append. Later entries win, as they did when 0.1.0 rebuilt this
    /// map from the whole list for every lookup.
    private var typeIndex = builtInScalars

    /// Entries written to the name index: one per appended type.
    package private(set) var typeIndexInsertions = 0
    /// Full reads of the type list. Building a lookup must not need one; the
    /// scaling tests check that this stays constant.
    package private(set) var typeListReads = 0

    func appendType(_ type: GraphQLNamedType) {
        typeList.append(type)
        typeIndex[type.name] = type
        typeIndexInsertions += 1
    }

    /// Every registered type, in registration order.
    func allTypes() -> [GraphQLNamedType] {
        typeListReads += 1
        return typeList
    }

    /// The name index as it stands. Callers that keep the result share its
    /// storage copy-on-write until the next `appendType(_:)`.
    func currentTypeIndex() -> [String: GraphQLNamedType] {
        typeIndex
    }

    /// The current root types, in the precedence order lookups apply.
    func currentRootTypes() -> [GraphQLObjectType?] {
        [query, mutation, subscription]
    }
}
