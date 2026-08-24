import GraphQL

/// Validates directive applications against their declarations.
///
/// Runs as a second pass after every component has been processed: a directive
/// may be applied by a component the builder visits before the `Directive` that
/// declares it, so this cannot happen during `update`.
func validateAppliedDirectives(
    _ map: AppliedDirectiveMap,
    locations: [DirectiveTarget: DirectiveLocation],
    against definitions: [GraphQLDirective]
) throws {
    for (target, applied) in map {
        var seen: Set<String> = []

        for directive in applied {
            guard let definition = definitions.first(where: { $0.name == directive.name }) else {
                throw SchemaError(
                    description: "Directive @\(directive.name) is applied but never declared."
                )
            }

            if let location = locations[target], !definition.locations.contains(location) {
                throw SchemaError(
                    description: "Directive @\(directive.name) is not permitted on \(location.rawValue)."
                )
            }

            if !definition.isRepeatable, seen.contains(directive.name) {
                throw SchemaError(
                    description: "Directive @\(directive.name) is not repeatable but is applied more than once at the same location."
                )
            }
            seen.insert(directive.name)

            for (argumentName, _) in directive.arguments {
                guard definition.args.contains(where: { $0.name == argumentName }) else {
                    throw SchemaError(
                        description: "Directive @\(directive.name) has no argument named \(argumentName)."
                    )
                }
            }

            for argument in definition.args {
                let isRequired = argument.type is GraphQLNonNull && argument.defaultValue == nil
                let isProvided = directive.arguments.contains { $0.0 == argument.name }
                if isRequired, !isProvided {
                    throw SchemaError(
                        description: "Directive @\(directive.name) is missing required argument \(argument.name)."
                    )
                }
            }

            // Value coercion can only be checked inside the GraphQL module,
            // where astFromValue lives.
            if let error = directive.coercionErrors(against: definition).first {
                throw SchemaError(description: error)
            }
        }
    }
}
