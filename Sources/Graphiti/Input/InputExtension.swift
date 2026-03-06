import GraphQL

public final class InputExtension<
    Resolver: Sendable,
    Context: Sendable,
    InputObjectType
>: TypeComponent<
    Resolver,
    Context
> {
    let fields: [InputFieldComponent<InputObjectType, Context>]

    override func update(typeProvider: SchemaTypeProvider, coders _: Coders) throws {
        let existingType = try typeProvider.getInputObjectType(from: InputObjectType.self)

        var newFields: InputObjectFieldMap = [:]
        for field in fields {
            let (name, inputField) = try field.field(typeProvider: typeProvider)
            newFields[name] = inputField
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
        type _: InputObjectType.Type,
        name: String?,
        fields: [InputFieldComponent<InputObjectType, Context>]
    ) {
        self.fields = fields
        super.init(
            name: name ?? Reflection.name(for: InputObjectType.self),
            type: .connection
        )
    }
}

public extension InputExtension {
    convenience init(
        _ type: InputObjectType.Type,
        as name: String? = nil,
        @InputFieldComponentBuilder<InputObjectType, Context> _ fields: ()
            -> InputFieldComponent<InputObjectType, Context>
    ) {
        self.init(type: type, name: name, fields: [fields()])
    }

    convenience init(
        _ type: InputObjectType.Type,
        as name: String? = nil,
        @InputFieldComponentBuilder<InputObjectType, Context> _ fields: ()
            -> [InputFieldComponent<InputObjectType, Context>]
    ) {
        self.init(type: type, name: name, fields: fields())
    }
}
