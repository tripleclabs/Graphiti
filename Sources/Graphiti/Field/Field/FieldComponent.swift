import GraphQL

public class FieldComponent<ObjectType, Context> {
    var description: String?
    var deprecationReason: String?
    public var appliedDirectives: [AppliedDirective] = []

    func field(typeProvider _: TypeProvider, coders _: Coders) throws -> (String, GraphQLField) {
        fatalError()
    }

    func getName() -> String {
        fatalError()
    }

    /// Directives applied to this field's arguments, keyed by argument name.
    ///
    /// Type-erased because `Arguments` is generic on the concrete subclass.
    func argumentDirectives() -> [(String, [AppliedDirective])] {
        []
    }
}

public extension FieldComponent {
    func description(_ description: String) -> Self {
        self.description = description
        return self
    }

    func deprecationReason(_ deprecationReason: String) -> Self {
        self.deprecationReason = deprecationReason
        return self
    }
}

extension FieldComponent: DirectiveAnnotatable {}
