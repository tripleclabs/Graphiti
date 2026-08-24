import GraphQL

/// Declares a custom directive definition.
///
/// The definition is rendered into SDL and is what applied directives are
/// validated against. Apply it with `.directive(_:_:)` on any component.
public final class Directive<Resolver: Sendable, Context: Sendable>: TypeComponent<Resolver, Context> {
    let locations: [DirectiveLocation]
    let isRepeatable: Bool
    let arguments: [DirectiveArgument]

    public init(
        _ name: String,
        on locations: DirectiveLocation...,
        repeatable: Bool = false,
        @DirectiveArgumentBuilder _ arguments: () -> [DirectiveArgument] = { [] }
    ) {
        self.locations = locations
        isRepeatable = repeatable
        self.arguments = arguments()
        super.init(name: name, type: .directive)
    }

    override func update(typeProvider: SchemaTypeProvider, coders _: Coders) throws {
        var args: GraphQLArgumentConfigMap = [:]
        for argument in arguments {
            let inputType = try typeProvider.getInputType(
                from: argument.type,
                field: argument.name
            )
            args[argument.name] = GraphQLArgument(
                type: inputType,
                description: argument.description,
                defaultValue: argument.defaultValue
            )
        }

        typeProvider.directives.append(
            try GraphQLDirective(
                name: name,
                description: description,
                locations: locations,
                args: args,
                isRepeatable: isRepeatable
            )
        )
    }
}
