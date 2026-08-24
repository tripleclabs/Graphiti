import GraphQL

/// An argument in a directive declaration.
public struct DirectiveArgument {
    let name: String
    let type: Any.Type
    let description: String?
    let defaultValue: Map?

    public init<ArgumentType>(
        _ name: String,
        at type: ArgumentType.Type,
        description: String? = nil,
        defaultValue: Map? = nil
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.defaultValue = defaultValue
    }
}

@resultBuilder
public struct DirectiveArgumentBuilder {
    public static func buildBlock(_ components: DirectiveArgument...) -> [DirectiveArgument] {
        components
    }

    public static func buildArray(_ components: [[DirectiveArgument]]) -> [DirectiveArgument] {
        components.flatMap { $0 }
    }
}
