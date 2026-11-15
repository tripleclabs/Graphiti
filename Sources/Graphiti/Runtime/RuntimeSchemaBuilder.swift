import GraphQL

/// A name-based view used by explicitly declared runtime fields. Lookup uses
/// the original objects, preserving native scalar coercion and type identity.
public struct RuntimeTypeLookup {
    private let types: [String: GraphQLNamedType]

    init(_ provider: SchemaTypeProvider) {
        var types: [String: GraphQLNamedType] = [
            "String": GraphQLString, "Int": GraphQLInt, "Float": GraphQLFloat,
            "Boolean": GraphQLBoolean, "ID": GraphQLID,
        ]
        for type in provider.types { types[type.name] = type }
        for type in [provider.query, provider.mutation, provider.subscription].compactMap({ $0 }) {
            types[type.name] = type
        }
        self.types = types
    }

    public func named(_ name: String) throws -> GraphQLNamedType {
        guard let type = types[name] else { throw SchemaError(description: "Unknown runtime type \(name)") }
        return type
    }

    public func output(_ name: String) throws -> GraphQLOutputType {
        guard let type = try named(name) as? GraphQLOutputType else {
            throw SchemaError(description: "\(name) is not an output type")
        }
        return type
    }

    public func input(_ name: String) throws -> GraphQLInputType {
        guard let type = try named(name) as? GraphQLInputType else {
            throw SchemaError(description: "\(name) is not an input type")
        }
        return type
    }
}

/// Opt-in, synchronous construction scope. It can add whole runtime-owned
/// types and operation fields; it cannot add fields to a native-owned type.
/// Complete runtime-owned types (including vertical extensions) before adding.
/// Never retain or mutate GraphQL objects after schema publication.
public final class RuntimeSchemaBuilder {
    private let provider: SchemaTypeProvider
    private var active = true
    private var ownedTypes: Set<String> = []
    private var rootFields: Set<DirectiveTarget> = []
    private var pendingDirectives: AppliedDirectiveMap = [:]

    init(_ provider: SchemaTypeProvider) { self.provider = provider }
    func finish() { active = false }
    public var types: RuntimeTypeLookup { RuntimeTypeLookup(provider) }
    public var queryTypeName: String { provider.query?.name ?? "Query" }
    public var mutationTypeName: String { provider.mutation?.name ?? "Mutation" }

    private func checkActive() throws {
        guard active else { throw SchemaError(description: "Runtime schema construction has finished") }
    }

    public func addType(_ type: GraphQLNamedType) throws {
        try checkActive()
        guard (try? types.named(type.name)) == nil,
              !["Query", "Mutation", "Subscription"].contains(type.name) else {
            throw SchemaError(description: "Duplicate or reserved runtime type \(type.name)")
        }
        ownedTypes.insert(type.name)
        provider.types.append(type)
    }

    /// Bind a native Codable scalar representation to a runtime-owned scalar.
    /// This adds no declaration and does not change either type's fields.
    public func bindScalar<Value: Codable & Sendable>(_ value: Value.Type, named name: String) throws {
        try checkActive()
        guard ownedTypes.contains(name), let scalar = try types.named(name) as? GraphQLScalarType else {
            throw SchemaError(description: "Expected a runtime-owned scalar \(name)")
        }
        try provider.mapName(value, to: name)
        try provider.map(value, to: scalar)
    }

    public func addDirective(_ directive: GraphQLDirective) throws {
        try checkActive()
        guard !(specifiedDirectives + provider.directives).contains(where: { $0.name == directive.name }) else {
            throw SchemaError(description: "Duplicate directive @\(directive.name)")
        }
        provider.directives.append(directive)
    }

    public func addQueryField(_ name: String, field: GraphQLField) throws {
        try checkActive()
        provider.query = try adding(name, field: field, to: provider.query, defaultName: "Query")
    }

    public func addMutationField(_ name: String, field: GraphQLField) throws {
        try checkActive()
        provider.mutation = try adding(name, field: field, to: provider.mutation, defaultName: "Mutation")
    }

    public func addSubscriptionField(_ name: String, field: GraphQLField) throws {
        try checkActive()
        provider.subscription = try adding(name, field: field, to: provider.subscription, defaultName: "Subscription")
    }

    private func adding(_ name: String, field: GraphQLField, to root: GraphQLObjectType?, defaultName: String) throws -> GraphQLObjectType {
        let object = try root ?? GraphQLObjectType(name: defaultName, fields: [:])
        let target = DirectiveTarget.member(type: object.name, member: name)
        guard rootFields.insert(target).inserted else { throw SchemaError(description: "Duplicate runtime root field \(object.name).\(name)") }
        // Preserve deferred native fields: they may refer to types registered
        // later in this callback. Collision checking occurs during finalization.
        let previous = object.fields
        let rootName = object.name
        object.fields = {
            var fields = try previous()
            guard fields[name] == nil else { throw SchemaError(description: "Duplicate root field \(rootName).\(name)") }
            fields[name] = field
            return fields
        }
        return object
    }

    /// Applications may target runtime-owned types or newly added root fields.
    /// Swift-owned declarations continue using Graphiti's .directive DSL.
    public func apply(_ directives: [AppliedDirective], at target: DirectiveTarget) throws {
        try checkActive()
        let permitted: Bool
        switch target {
        case .schema: permitted = true
        case .type(let name): permitted = ownedTypes.contains(name)
        case .member(let type, _): permitted = ownedTypes.contains(type) || rootFields.contains(target)
        case .argument(let type, let field, _):
            permitted = ownedTypes.contains(type) || rootFields.contains(.member(type: type, member: field))
        }
        guard permitted else { throw SchemaError(description: "Directive target is not runtime-owned: \(target)") }
        pendingDirectives[target, default: []].append(contentsOf: directives)
    }

    func registerDirectives(in schema: GraphQLSchema) throws {
        for (target, directives) in pendingDirectives {
            let location = try Self.location(of: target, in: schema)
            provider.register(directives, at: target, as: location)
        }
    }

    private static func location(of target: DirectiveTarget, in schema: GraphQLSchema) throws -> DirectiveLocation {
        switch target {
        case .schema: return .schema
        case .type(let name):
            switch schema.getType(name: name) {
            case is GraphQLObjectType: return .object
            case is GraphQLInputObjectType: return .inputObject
            case is GraphQLInterfaceType: return .interface
            case is GraphQLUnionType: return .union
            case is GraphQLEnumType: return .enum
            case is GraphQLScalarType: return .scalar
            default: break
            }
        case .member(let name, let member):
            let type = schema.getType(name: name)
            if let object = type as? GraphQLObjectType, try object.fields()[member] != nil { return .fieldDefinition }
            if let interface = type as? GraphQLInterfaceType, try interface.fields()[member] != nil { return .fieldDefinition }
            if let input = type as? GraphQLInputObjectType, try input.fields()[member] != nil { return .inputFieldDefinition }
            if let enumeration = type as? GraphQLEnumType, enumeration.values.contains(where: { $0.name == member }) { return .enumValue }
        case .argument(let name, let field, let argument):
            let type = schema.getType(name: name)
            let fields: GraphQLFieldMap?
            if let object = type as? GraphQLObjectType { fields = try object.fields() }
            else if let interface = type as? GraphQLInterfaceType { fields = try interface.fields() }
            else { fields = nil }
            if fields?[field]?.args[argument] != nil { return .argumentDefinition }
        }
        throw SchemaError(description: "Unknown runtime directive target \(target)")
    }
}
