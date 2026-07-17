import GraphQL

/// A parsed and validated GraphQL operation that can be safely reused across requests.
public struct PreparedOperation: Sendable {
    let document: Document
    let schemaIdentifier: ObjectIdentifier

    /// The operation to execute when the document contains multiple operations.
    public let operationName: String?

    init(
        document: Document,
        schema: GraphQLSchema,
        operationName: String?
    ) {
        self.document = document
        schemaIdentifier = ObjectIdentifier(schema)
        self.operationName = operationName
    }
}

/// Errors specific to using a prepared operation.
public enum PreparedOperationError: Error, Equatable, Sendable {
    /// The operation was prepared for a different schema instance.
    case schemaMismatch
}

public extension Schema {
    /// Parse and validate an operation once for repeated execution against this schema.
    func prepare(
        request: String,
        operationName: String? = nil,
        validationRules: [@Sendable (ValidationContext) -> Visitor] = []
    ) throws -> PreparedOperation {
        let schemaErrors = try validateSchema(schema: schema)
        guard schemaErrors.isEmpty else {
            throw GraphQLErrors(schemaErrors)
        }

        let document = try parse(source: request)
        let validationErrors = validate(
            schema: schema,
            ast: document,
            rules: GraphQL.specifiedRules + validationRules
        )
        guard validationErrors.isEmpty else {
            throw GraphQLErrors(validationErrors)
        }

        return PreparedOperation(
            document: document,
            schema: schema,
            operationName: operationName
        )
    }

    /// Execute an operation previously prepared for this schema.
    func execute(
        prepared operation: PreparedOperation,
        resolver: Resolver,
        context: Context,
        variables: [String: Map] = [:]
    ) async throws -> GraphQLResult {
        guard operation.schemaIdentifier == ObjectIdentifier(schema) else {
            throw PreparedOperationError.schemaMismatch
        }

        return try await GraphQL.execute(
            schema: schema,
            documentAST: operation.document,
            rootValue: resolver,
            context: context,
            variableValues: variables,
            operationName: operation.operationName
        )
    }
}
