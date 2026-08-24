import GraphQL

public class InputFieldComponent<InputObjectType, Context> {
    var description: String?
    public var appliedDirectives: [AppliedDirective] = []

    func field(typeProvider _: TypeProvider) throws -> (String, InputObjectField) {
        fatalError()
    }
}

public extension InputFieldComponent {
    func description(_ description: String) -> Self {
        self.description = description
        return self
    }
}

extension InputFieldComponent: DirectiveAnnotatable {}
