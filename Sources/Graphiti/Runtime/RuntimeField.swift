import GraphQL

/// Explicitly declares a field on its owning Swift type using a runtime named
/// return type. The supplied resolver adapts values across the boundary; no
/// automatic Codable/Lua conversion is implied. Factory runs during assembly.
public final class RuntimeField<ObjectType, Context>: FieldComponent<ObjectType, Context> {
    private let name: String
    private let makeField: (RuntimeTypeLookup) throws -> GraphQLField
    private let appliedArguments: [(String, [AppliedDirective])]

    public init(
        _ name: String,
        argumentDirectives: [(String, [AppliedDirective])] = [],
        field: @escaping (RuntimeTypeLookup) throws -> GraphQLField
    ) {
        self.name = name
        self.makeField = field
        self.appliedArguments = argumentDirectives
        super.init()
    }

    override func getName() -> String { name }
    override func argumentDirectives() -> [(String, [AppliedDirective])] { appliedArguments }

    override func field(typeProvider: TypeProvider, coders: Coders) throws -> (String, GraphQLField) {
        guard let provider = typeProvider as? SchemaTypeProvider else {
            throw SchemaError(description: "RuntimeField requires a schema type provider")
        }
        let raw = try makeField(RuntimeTypeLookup(provider))
        return (name, GraphQLField(
            type: raw.type,
            description: description ?? raw.description,
            deprecationReason: deprecationReason ?? raw.deprecationReason,
            args: raw.args,
            resolve: raw.resolve,
            subscribe: raw.subscribe,
            astNode: raw.astNode
        ))
    }
}
