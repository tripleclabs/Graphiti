import GraphQL

public final class TypeExtension<
    Resolver: Sendable,
    Context: Sendable,
    ObjectType: Sendable
>: TypeComponent<
    Resolver,
    Context
> {
    let fields: [FieldComponent<ObjectType, Context>]

    override func update(typeProvider: SchemaTypeProvider, coders: Coders) throws {
        let existingType = try typeProvider.getObjectType(from: ObjectType.self)

        var newFields: GraphQLFieldMap = [:]
        for field in fields {
            let (name, graphQLField) = try field.field(typeProvider: typeProvider, coders: coders)
            newFields[name] = graphQLField
        }

        let existingFields = existingType.fields
        existingType.fields = {
            var merged = try existingFields()
            for (name, field) in newFields {
                merged[name] = field
            }
            return merged
        }
    }

    private init(
        type _: ObjectType.Type,
        name: String?,
        fields: [FieldComponent<ObjectType, Context>]
    ) {
        self.fields = fields
        super.init(
            name: name ?? Reflection.name(for: ObjectType.self),
            type: .type
        )
    }
}

public extension TypeExtension {
    convenience init(
        _ type: ObjectType.Type,
        as name: String? = nil,
        @FieldComponentBuilder<ObjectType, Context> _ fields: ()
            -> FieldComponent<ObjectType, Context>
    ) {
        self.init(type: type, name: name, fields: [fields()])
    }

    convenience init(
        _ type: ObjectType.Type,
        as name: String? = nil,
        @FieldComponentBuilder<ObjectType, Context> _ fields: ()
            -> [FieldComponent<ObjectType, Context>]
    ) {
        self.init(type: type, name: name, fields: fields())
    }
}
