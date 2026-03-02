import GraphQL

/// Registers a GraphQLEnumType against any Codable Swift type.
///
/// Unlike `Enum<>`, which requires `RawRepresentable` Swift enums,
/// DynamicEnum works with any Codable type whose encoded form is a
/// flat string matching one of the declared value names.
///
/// Typical use: `ValidatedStatus<T>` / `ValidatedKind<T>` wrappers
/// that encode as `singleValueContainer().encode(rawValue)`.
public final class DynamicEnum<
    Resolver: Sendable,
    Context: Sendable,
    SwiftType: Codable
>: TypeComponent<Resolver, Context> {

    private let swiftType: SwiftType.Type
    private let enumValues: [(name: String, description: String?, deprecationReason: String?)]

    override func update(typeProvider: SchemaTypeProvider, coders _: Coders) throws {
        let enumType = try GraphQLEnumType(
            name: name,
            description: description,
            values: enumValues.reduce(into: [:]) { result, entry in
                result[entry.name] = try GraphQLEnumValue(
                    value: .string(entry.name),
                    description: entry.description,
                    deprecationReason: entry.deprecationReason
                )
            }
        )

        try typeProvider.add(type: swiftType, as: enumType)
    }

    private init(
        type: SwiftType.Type,
        name: String?,
        values: [(name: String, description: String?, deprecationReason: String?)]
    ) {
        self.swiftType = type
        self.enumValues = values
        super.init(
            name: name ?? Reflection.name(for: SwiftType.self),
            type: .enum
        )
    }
}

// MARK: - Public convenience initializers

public extension DynamicEnum {
    /// Create a DynamicEnum with named values (no deprecation).
    convenience init(
        _ type: SwiftType.Type,
        as name: String? = nil,
        values: [(name: String, description: String?)]
    ) {
        self.init(
            type: type,
            name: name,
            values: values.map { ($0.name, $0.description, nil) }
        )
    }

    /// Create a DynamicEnum with full control over deprecation.
    convenience init(
        _ type: SwiftType.Type,
        as name: String? = nil,
        values: [(name: String, description: String?, deprecationReason: String?)]
    ) {
        self.init(type: type, name: name, values: values)
    }
}
