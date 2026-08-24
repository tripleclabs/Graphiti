# Directive Queries and Schema Projection

**Date:** 2026-08-24
**Status:** Approved, ready for implementation planning

## Problem

A production schema has roughly 900 root query fields and hundreds of types.
These break into thematic groups, and consumers — both people and LLMs — need a
view of only the slice relevant to their use case. It remains one graph; the
view is a lens on it.

This is currently done with Swift wrappers outside the schema. Expressing it in
the SDL instead makes the grouping visible to every consumer of the schema
rather than only to code that knows about the wrappers.

Two capabilities are missing:

1. **Querying a schema by applied directive.** `Schema.appliedDirectives` exists
   but is internal (`Sources/Graphiti/Schema/Schema.swift:9`), so no caller can
   ask "which root fields carry this directive with this value?"

2. **Projecting a schema to a subset of its root fields.** Nothing produces a
   reduced schema from such a query.

## Requirements

- Work for **any** directive. This is a general capability, not a themes
  feature — no domain vocabulary enters Graphiti or the GraphQL fork.
- Query applied directives from outside the module.
- Project a schema down to root fields matching a caller-supplied predicate.
- Projections must **execute**, not merely print. Resolvers and subscription
  sources survive.
- Types are included by **automatic transitive closure** from retained root
  fields. Only root fields are tagged.
- Root fields with no matching directive are **excluded from every view**. The
  unprojected schema is unchanged and still contains everything.
- Projections are built **on demand and held by the caller**. Graphiti caches
  nothing and stays lock-free and `Sendable`.
- Works across **query, mutation and subscription** roots.

## Non-goals

- No caching, memoisation, or eager projection inside `Schema`.
- No `theme` vocabulary in the library; the convention lives in the caller.
- No new query language — predicates are Swift closures.
- No tagging of types; tags go on root fields only.

## Approach

Rejected alternatives:

- **A theme-aware API** (`schema.projection(theme:)`). Ergonomic for one caller,
  but bakes a convention into a general-purpose library. Made configurable, it
  becomes the generic design with more machinery and a worse name.
- **A declarative matcher type** (`.directive(_:argument:contains:)`). Fully
  generic and reads well, but duplicates what a closure already does and grows a
  case per comparison. Revisit only if writing predicates proves painful.

## Design

### Query API

**Make `Schema.appliedDirectives` public.** It is an `AppliedDirectiveMap`, a
public type keyed by the public `DirectiveTarget`, so once visible every query
is ordinary Swift:

```swift
let billing = schema.appliedDirectives.filter { target, directives in
    guard case .member(let type, _) = target, type == "Query" else { return false }
    return directives.contains { $0.name == "theme" && $0.argument("names", contains: "billing") }
}
```

**Add argument access to `AppliedDirective`** in the GraphQL fork.
`AppliedDirective.arguments` is `[(String, Map)]`, and `Map` exposes almost no
public read accessors — `stringValue` and `intValue` only — so predicates would
otherwise hand-roll pattern matches over `Map` cases:

```swift
public extension AppliedDirective {
    /// The value of a named argument, if present.
    subscript(_ argument: String) -> Map? { get }

    /// True when the named argument is a list containing `value`.
    /// False when the argument is absent or is not a list.
    func argument(_ name: String, contains value: Map) -> Bool
}
```

`contains` exists because list-valued arguments are the expected shape for
multi-valued tags (`@theme(names: ["billing", "admin"])`). It stays generic over
directive, argument and value.

**Nothing else is added.** No `elements(withDirective:)`, no `locations(where:)`.
Those are one-line filters over a dictionary the caller now has, and a library
should not wrap the standard library.

### Projection

`GraphQLFieldDefinition.toField()` (`Type/Definition.swift:629`) rebuilds a field
config carrying `resolve` **and** `subscribe`, so a rebuilt root type stays
executable — but it is internal. Rather than widening the fork's type-layer
visibility, projection lives in the fork as a generic capability, mirroring the
split already used for directive printing: mechanics in the GraphQL layer, DSL
knowledge in Graphiti.

```swift
public extension GraphQLSchema {
    /// A schema containing only the root fields satisfying `keep`, plus every
    /// type reachable from them.
    /// - Parameter keep: called with (root type name, field name).
    func projected(
        rootFieldsWhere keep: (String, String) -> Bool
    ) throws -> GraphQLSchema
}
```

Graphiti wraps it:

```swift
public extension Schema {
    /// - Parameter keep: called with the root type name ("Query", "Mutation",
    ///   "Subscription"), the field name, and the directives applied to it.
    func projection(
        rootFieldsWhere keep: (String, String, [AppliedDirective]) -> Bool
    ) throws -> Schema<Resolver, Context>
}
```

The predicate receives the root type name as well as the field name so callers
can distinguish a tagged mutation from a tagged query sharing a name, and can
scope a view to one operation kind.

Graphiti supplies a predicate closing over its directive map — looking each
field up as `.member(type: rootTypeName, member: fieldName)` — filters that map,
and wraps the result. This requires a new internal `Schema` initializer taking a
prebuilt `GraphQLSchema` and an `AppliedDirectiveMap`; the existing initializer
only builds from components.

**Algorithm:**

1. For each of query, mutation and subscription present on the source schema,
   retain the fields `keep` accepts and rebuild the root object type from
   `toField()`. A root type with no surviving fields is omitted entirely.
2. Hand the rebuilt roots to `GraphQLSchema.init`, which runs `typeMapReducer`
   and computes the type closure itself.
3. Apply the interface completeness pass below.
4. Run `validateSchema` and throw on any error.

### Interface completeness

`typeMapReducer` (`Type/Schema.swift:337`) walks unions down to their member
types and objects up to their interfaces, but for an **interface** it walks only
that interface's own fields — never its implementations. This matches graphql-js.

Consequently a projection whose retained root field returns `interface Node`
includes `Node` but not `User` or `Product`. Resolving a concrete type at
runtime would then fail. Unions are unaffected.

**Fix:** before constructing, walk the retained closure; for every interface in
it, add the implementing types from `GraphQLSchema.implementations`
(`Type/Schema.swift:46`, already public) via the `types:` parameter. This
iterates to a fixed point, because an added implementation has fields that pull
in further types, which may retain further interfaces.

**Known trade-off.** Interface completeness fights view smallness. A tagged
field returning a bare interface drags in every implementor and everything they
reference, so a 40-type view can become 300. An executable projection cannot
avoid this. Completeness is therefore the default and there is **no opt-out
flag**: measure against the real schema first, since the better remedy may be
"do not return bare interfaces from tagged root fields" rather than an API knob.

### Directive map on a projection

A projected `Schema` carries a reduced `AppliedDirectiveMap`. The rule is
uniform, with no special case for root types: **keep an entry if its owning
element still exists in the projected schema.** Look the type up in the
projected `typeMap`; for `.member` and `.argument`, confirm the field, input
field, enum value or argument is still present.

Everything the view contains keeps all of its directives. Only applications
pointing at elements the view does not contain are dropped.

This matters for the query API rather than for rendering. The renderer only
looks up elements it is printing, so `sdl()` would be correct either way. But
`projection.appliedDirectives` is what second-order queries run against, and
unfiltered it would report elements that schema does not contain.

### SDL

`sdl()` needs no change — it already passes the schema's own map to
`printSchema(schema:appliedDirectives:)`, so a projection prints its reduced map.

Directive **definitions** carry over wholesale from the source schema, including
any no longer applied in the view. Pruning them would save a few lines of
context but risks emitting SDL that applies an undefined directive if the
filtering is ever wrong.

### Errors

All throw `SchemaError`:

- No query fields matched. GraphQL requires a query root, so this cannot produce
  a valid schema. Note this means **every theme needs at least one query field**;
  a mutation-only view cannot stand alone.
- The projected schema fails `validateSchema`. This is the backstop for any
  structural problem the projection introduces.

A theme matching no *mutations* is not an error — the view simply omits the
mutation root. The same holds for subscriptions.

## Testing

Beyond printing:

1. **Execution against a projection.** Run a real query through a projected
   schema and assert data returns, proving `toField()` preserved resolvers. This
   is what distinguishes a sub-schema from a pretty string.
2. **Interface completeness.** A tagged root returning an interface, then
   *execute* a query selecting `__typename` on a concrete implementor. Printing
   alone would not catch this failure.
3. **Transitive inclusion and exclusion.** A type reachable only from an
   untagged root field is absent; one reachable from a tagged field is present.
4. **Subscription projection** preserves `subscribe`.
5. **Mutation-only theme** omits the query root and therefore throws.
6. **No matching query fields** throws.
7. **Map filtering.** `appliedDirectives` on a projection reports only surviving
   elements, and every surviving element keeps all of its directives.
8. **Determinism.** Two projections of the same predicate produce byte-identical
   SDL.
9. **Query API.** `subscript(_:)` and `argument(_:contains:)` against list,
   scalar, absent and non-list arguments.

## Repository sequencing

1. `tripleclabs/GraphQL` — `AppliedDirective` argument access,
   `GraphQLSchema.projected(rootFieldsWhere:)`, interface completeness.
2. Bump the revision pin at `Package.swift:12`.
3. `tripleclabs/graphiti` — public `appliedDirectives`, `Schema.projection`,
   map filtering, the internal `Schema` initializer, docs.

The Graphiti side cannot build against the new API until steps 1 and 2 land.
