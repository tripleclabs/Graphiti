import GraphQL

open class Component<Resolver: Sendable, Context: Sendable> {
    let name: String
    var description: String?
    var componentType: ComponentType
    public var appliedDirectives: [AppliedDirective] = []

    init(name: String, type: ComponentType) {
        self.name = name
        componentType = type
    }

    func update(typeProvider _: SchemaTypeProvider, coders _: Coders) throws {}
}

public extension Component {
    func description(_ description: String) -> Self {
        self.description = description
        return self
    }
}

/// The type of a component. This is used as opposed to runtime type-checking because the
/// component types are typically generics (and therefore hard to type-check).
enum ComponentType {
    case none
    case connection
    case directive
    case `enum`
    case input
    case interface
    case mutation
    case query
    case scalar
    case schemaDirectives
    case subscription
    case type
    case types
    case union
}

extension Component: DirectiveAnnotatable {}

extension ComponentType {
    /// The spec location a directive applied to this component targets, or nil
    /// when the component declares no named type of its own.
    var directiveLocation: DirectiveLocation? {
        switch self {
        case .type, .connection, .query, .mutation, .subscription:
            return .object
        case .enum:
            return .enum
        case .input:
            return .inputObject
        case .interface:
            return .interface
        case .union:
            return .union
        case .scalar:
            return .scalar
        case .schemaDirectives:
            return .schema
        case .directive, .types, .none:
            return nil
        }
    }
}
