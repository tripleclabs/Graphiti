import GraphQL

/// Applies directives to the schema definition itself.
///
/// GraphQL allows directives on the `schema { }` block, but every other Graphiti
/// component declares a named type, so there was no component whose applications
/// could target `DirectiveTarget.schema`. A directive declared `on: .schema`
/// could therefore be declared and never applied.
///
/// This component declares no type of its own — it exists only to carry
/// applications:
///
/// ```swift
/// Directive("validator", on: .schema, repeatable: true) {
///     DirectiveArgument("name", at: String.self)
/// }
/// SchemaDirectives()
///     .directive("validator", ("name", "lua-typecheck"))
/// ```
///
/// Applications are emitted in the order written, so the printed SDL is stable
/// across builds.
public final class SchemaDirectives<
    Resolver: Sendable,
    Context: Sendable
>: TypeComponent<Resolver, Context> {
    public init() {
        super.init(name: "", type: .schemaDirectives)
    }
}
