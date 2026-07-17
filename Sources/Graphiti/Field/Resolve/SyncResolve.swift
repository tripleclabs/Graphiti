public typealias SyncResolve<ObjectType, Context, Arguments, ResolveType> = @Sendable (
    _ object: ObjectType
) -> (
    _ context: Context,
    _ arguments: Arguments
) throws -> ResolveType where
    ObjectType: Sendable,
    Context: Sendable,
    Arguments: Sendable,
    ResolveType: Sendable
