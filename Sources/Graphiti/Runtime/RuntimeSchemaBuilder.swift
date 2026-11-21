import GraphQL

/// A name-based view used by explicitly declared runtime fields. Lookup uses
/// the original objects, preserving native scalar coercion and type identity.
///
/// A lookup is a snapshot of the types registered when it was made. It shares
/// the schema's name index copy-on-write, so making one is constant time.
/// That stays linear overall only while lookups are not retained across
/// `RuntimeSchemaBuilder.addType(_:)`: a caller that takes a fresh
/// `runtime.types` before every `addType` and keeps each one forces a copy of
/// the index per added type — quadratic, but no worse than 0.1.0, which
/// rebuilt the index for every lookup.
public struct RuntimeTypeLookup {
    /// The registered types (over the built-in scalars) at snapshot time.
    private let types: [String: GraphQLNamedType]
    /// The root types at snapshot time; see `resolve(_:roots:types:)`.
    private let roots: [GraphQLObjectType?]

    init(_ provider: SchemaTypeProvider) {
        types = provider.currentTypeIndex()
        roots = provider.currentRootTypes()
    }

    /// The single name-resolution rule: a root type takes precedence over a
    /// registered type of the same name, and among roots the later of query,
    /// mutation, subscription wins.
    static func resolve(
        _ name: String,
        roots: [GraphQLObjectType?],
        types: [String: GraphQLNamedType]
    ) -> GraphQLNamedType? {
        if let root = roots.last(where: { $0?.name == name }) { return root }
        return types[name]
    }

    public func named(_ name: String) throws -> GraphQLNamedType {
        guard let type = Self.resolve(name, roots: roots, types: types) else {
            throw SchemaError(description: "Unknown runtime type \(name)")
        }
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
    private var fieldMapEvaluations = 0

    init(_ provider: SchemaTypeProvider) { self.provider = provider }
    func finish() { active = false }
    public var types: RuntimeTypeLookup { RuntimeTypeLookup(provider) }
    public var queryTypeName: String { provider.query?.name ?? "Query" }
    public var mutationTypeName: String { provider.mutation?.name ?? "Mutation" }

    private func checkActive() throws {
        guard active else { throw SchemaError(description: "Runtime schema construction has finished") }
    }

    /// Whether `types` would find `name`.
    private func isNamedType(_ name: String) -> Bool {
        RuntimeTypeLookup.resolve(
            name, roots: provider.currentRootTypes(), types: provider.currentTypeIndex()
        ) != nil
    }

    public func addType(_ type: GraphQLNamedType) throws {
        try checkActive()
        guard !isNamedType(type.name),
              !["Query", "Mutation", "Subscription"].contains(type.name) else {
            throw SchemaError(description: "Duplicate or reserved runtime type \(type.name)")
        }
        ownedTypes.insert(type.name)
        provider.appendType(type)
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
        // Each type's field map is evaluated at most once here. A root type's
        // `fields` is the chain built by `adding` over the native thunk, so
        // evaluating it per target made this pass quadratic.
        var members = MemberIndex(schema: schema)
        defer { fieldMapEvaluations += members.evaluations }
        for (target, directives) in pendingDirectives {
            let location = try Self.location(of: target, in: schema, members: &members)
            provider.register(directives, at: target, as: location)
        }
    }

    private static func location(
        of target: DirectiveTarget,
        in schema: GraphQLSchema,
        members: inout MemberIndex
    ) throws -> DirectiveLocation {
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
            // The same checks in the same order as before; each type's thunk
            // now runs once per pass instead of once per target.
            if try members.fields(of: name)?[member] != nil { return .fieldDefinition }
            if try members.inputFields(of: name)?[member] != nil { return .inputFieldDefinition }
            if let enumeration = schema.getType(name: name) as? GraphQLEnumType,
               enumeration.nameLookup[member] != nil {
                return .enumValue
            }
        case .argument(let name, let field, let argument):
            if try members.fields(of: name)?[field]?.args[argument] != nil { return .argumentDefinition }
        }
        throw SchemaError(description: "Unknown runtime directive target \(target)")
    }

    /// Counts of construction work done through this builder, so tests can
    /// check that it grows linearly with the schema. Scoped to this builder.
    package struct WorkCounts: Equatable, Sendable {
        /// Field maps evaluated while locating directive targets. A root type's
        /// map is the whole `adding` chain over the native fields.
        package var fieldMapEvaluations: Int
        /// Entries written to the type-name index used by lookups.
        package var typeIndexInsertions: Int
        /// Full reads of the registered type list (schema construction makes one).
        package var typeListReads: Int
    }

    package var workCounts: WorkCounts {
        WorkCounts(
            fieldMapEvaluations: fieldMapEvaluations,
            typeIndexInsertions: provider.typeIndexInsertions,
            typeListReads: provider.typeListReads
        )
    }
}

/// Field maps of the schema's types, each evaluated on first use within one
/// `registerDirectives` pass and reused for every later target on that type.
private struct MemberIndex {
    let schema: GraphQLSchema
    private(set) var evaluations = 0
    private var fieldMaps: [String: GraphQLFieldMap?] = [:]
    private var inputFieldMaps: [String: InputObjectFieldMap?] = [:]

    init(schema: GraphQLSchema) { self.schema = schema }

    /// The fields of an object or interface type; nil for any other type.
    mutating func fields(of name: String) throws -> GraphQLFieldMap? {
        if let cached = fieldMaps[name] { return cached }
        let fields: GraphQLFieldMap?
        switch schema.getType(name: name) {
        case let object as GraphQLObjectType:
            evaluations += 1
            fields = try object.fields()
        case let interface as GraphQLInterfaceType:
            evaluations += 1
            fields = try interface.fields()
        default:
            fields = nil
        }
        fieldMaps[name] = .some(fields)
        return fields
    }

    /// The fields of an input object type; nil for any other type.
    mutating func inputFields(of name: String) throws -> InputObjectFieldMap? {
        if let cached = inputFieldMaps[name] { return cached }
        let fields: InputObjectFieldMap?
        if let input = schema.getType(name: name) as? GraphQLInputObjectType {
            evaluations += 1
            fields = try input.fields()
        } else {
            fields = nil
        }
        inputFieldMaps[name] = .some(fields)
        return fields
    }
}
