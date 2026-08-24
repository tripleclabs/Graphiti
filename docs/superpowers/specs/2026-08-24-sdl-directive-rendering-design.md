# Rendering Directives in GraphQL SDL

**Date:** 2026-08-24
**Status:** Approved, ready for implementation planning

## Problem

Graphiti cannot express custom GraphQL directives, and its SDL output cannot
render them. Two distinct gaps:

1. **Directive definitions.** `SchemaTypeProvider.directives`
   (`Sources/Graphiti/Schema/SchemaTypeProvider.swift:26`) is declared and
   passed to `GraphQLSchema` (`Sources/Graphiti/Schema/Schema.swift:33`), but
   nothing populates it. There is no DSL component to declare a directive, so
   the array is always empty.

2. **Directive applications.** `printSchema` in the pinned GraphQL fork
   (`Utilities/PrintSchema.swift`) hardcodes `@deprecated`, `@specifiedBy` and
   `@oneOf` and prints nothing else. The type objects
   (`GraphQLObjectType`, `GraphQLFieldDefinition`, ...) have nowhere to store
   applied directives — no `astNode`, no extensions map.

Federation hit this same wall, which is why `Schema(federatedSDL:)` exists as a
hand-written raw-SDL escape hatch: `@key` is modelled semantically in
`Sources/Graphiti/Federation/Key/Key.swift` but never rendered.

## Requirements

- Declare custom directive definitions in the Graphiti DSL; render them in SDL.
- Apply directives at **all** type-system locations the spec allows; render them.
- **Direction: schema to SDL only.** No SDL-to-schema round trip, no
  introspection extension, no execution semantics.
- Consumer is codegen / client tooling reading an exported SDL file.

Explicitly out of scope: directive resolvers or middleware; `buildASTSchema` /
`extendSchema` preservation; introspection parity (the GraphQL spec cannot
expose applied directives through introspection at all, so codegen must read
the printed SDL); generating `federatedSDL:` from the existing `Key` model.

## Approach

Graphiti holds applied directives in its own side table keyed by schema path.
The fork's `printSchema` gains an optional map parameter and emits them.

Rejected alternatives:

- **Storage on the fork's type objects** (graphql-js parity, `astNode` on every
  type). Wide structural diff across `Definition.swift` and schema construction,
  in files upstream actively edits, buying round-trip and introspection
  capabilities that are explicitly out of scope.
- **A Graphiti-owned SDL printer from scratch.** Reimplements descriptions,
  block strings, default values and deprecation, then drifts from the fork's
  printer permanently.
- **A new fork file doing print to parse to inject to print.** Avoids editing
  `PrintSchema.swift`, but `print(ast:)` (`Language/Printer.swift`) and
  `printSchema` (`Utilities/PrintSchema.swift`) are independent formatters that
  are not guaranteed byte-identical on block-string descriptions or multiline
  argument lists. Threading a parameter through the existing functions has no
  round trip and therefore no fidelity risk.

The AST layer already models directives at every type-system location
(`ObjectTypeDefinition.directives`, `FieldDefinition.directives`,
`InputValueDefinition.directives`) and `Directive: Printable`
(`Language/Printer.swift:209`) renders them correctly. Only the type-object
layer and `printSchema` are missing. All AST initializers are internal, so
Graphiti cannot construct AST nodes from outside the module — which is why the
renderer lives in the fork and takes a plain value type across the boundary.

## Design

### DSL surface

Declaration, as a new top-level component alongside `Type` / `Enum` / `Input`:

```swift
Schema<Resolver, Context> {
    Directive("model", on: .object) {
        DirectiveArgument("table", at: String.self)
    }
    Directive("tag", on: .fieldDefinition, .object, repeatable: true) {
        DirectiveArgument("name", at: String.self)
    }
    Directive("auth", on: .fieldDefinition) {
        DirectiveArgument("role", at: Role.self)
    }
}
```

Application, following the chaining-modifier pattern every component already
uses for `.description(_:)`:

```swift
Type(User.self) {
    Field("email", at: \.email)
        .directive("auth", ("role", "ADMIN"))
        .directive("tag", ("name", "pii"))
}
.directive("model", ("table", "users"))
```

Covering every spec location means **five** independent modifier hosts, not
three. `Component` (`Component/Component.swift`), `FieldComponent`
(`Field/Field/FieldComponent.swift`), `ArgumentComponent`
(`Argument/ArgumentComponent.swift`), `InputFieldComponent`
(`InputField/InputFieldComponent.swift`) and `Value`
(`Value/Value.swift`, enum values) each declare their own `description` and
their own `.description(_:)` extension; none share a base class. Each gains
`var appliedDirectives: [AppliedDirective]` and a `.directive(...)` modifier
returning `Self`.

To avoid five copies of an identical modifier, introduce a
`DirectiveAnnotatable` protocol carrying `var appliedDirectives` with the
`.directive(...)` modifier supplied once in a protocol extension, and conform
all five. This mirrors what the existing `.description(_:)` duplication should
arguably have been, but do **not** refactor `description` as part of this work.

Arguments are **variadic ordered pairs**, not a dictionary. `Map` already
conforms to every literal protocol (`Map/Map.swift:770-814`), so
`("role", "ADMIN")` needs no ceremony, and ordering is preserved so emitted SDL
is byte-stable across builds. A `Dictionary` would reorder between runs and
produce phantom diffs in committed codegen output.

`("role", "ADMIN")` renders as `@auth(role: ADMIN)` — unquoted — because the
value is converted by `astFromValue(value:type:)` against the *declared*
argument type, not guessed from the `Map` case. This is why applications must
reference a declaration, and why an undeclared directive name is a build-time
error rather than passed through.

### Side table

Applications register into `SchemaTypeProvider` during the existing
`update(typeProvider:coders:)` pass, keyed by path:

```swift
public enum DirectiveTarget: Hashable {
    case schema
    case type(String)                                 // any named type
    case member(type: String, member: String)         // field, input field, or enum value
    case argument(type: String, field: String, argument: String)
}
```

`DirectiveTarget` is defined in the fork, since it appears in the public
`AppliedDirectiveMap` signature; Graphiti imports it rather than declaring its
own.

Named types are unique schema-wide, so one `.type` case covers
object/interface/union/enum/input/scalar. One `.member` case covers all three
member kinds; the AST nodes differ but the lookup key shape is identical.

### Renderer (fork)

```swift
public struct AppliedDirective: Sendable {
    public let name: String
    public let arguments: [(String, Map)]
}

public typealias AppliedDirectiveMap = [DirectiveTarget: [AppliedDirective]]

public func printSchema(
    schema: GraphQLSchema,
    appliedDirectives: AppliedDirectiveMap = [:]
) -> String
```

The existing `printSchema(schema:)` call sites keep working via the default.
Internally the fork resolves each name against `schema.directives` to get
declared argument types, runs `astFromValue(value:type:)` per argument, builds
the `Directive` AST node and renders it with the existing `Directive: Printable`.
All AST construction stays inside the module; no AST visibility changes.

Injection points, one lookup per print function:

| Construct | Position |
|---|---|
| object / interface | after `implements ...`, before `{` |
| union | after name, before `=` |
| enum, input object | after name (after `@oneOf`), before `{` |
| scalar | after name, after `@specifiedBy` |
| field | after the type, after `@deprecated` |
| argument / input field | after the default value, after `@deprecated` |
| enum value | after the value name |

Built-ins print first; customs append in declaration order. Output is fully
deterministic.

`printSchemaDefinition` (`Utilities/PrintSchema.swift:38-66`) returns nil when
root operation types use default names, omitting the schema block entirely. A
schema-level directive application must force that block to print, or the
directive silently vanishes:

```graphql
schema @link(url: "https://example.com/v1") {
  query: Query
}
```

### Graphiti entry point

`Schema` stores the map alongside `schema` and exposes:

```swift
public func sdl() -> String {
    printSchema(schema: schema, appliedDirectives: appliedDirectives)
}
```

Calling `printSchema(schema.schema)` directly still yields un-annotated SDL.
That is inherent to this approach and must be documented plainly in
`UsageGuide.md`.

## The specified-directives landmine

`GraphQLSchema.init` does:

```swift
self.directives = directives.isEmpty ? specifiedDirectives : directives
```

(`Type/Schema.swift:93`)

Graphiti passes `typeProvider.directives`, which is always empty today, so the
schema gets the spec directives by default and `@skip` / `@include` work. **The
moment the first custom directive is declared, that array becomes non-empty and
`@skip`, `@include`, `@deprecated` and `@specifiedBy` are silently dropped from
the schema.** `DirectiveTests.skip()` and `.include()` would fail, and any
client query using `@skip` would break at validation.

Graphiti cannot fix this locally: `specifiedDirectives` is internal
(`Type/Directives.swift:167`) even though the doc comment at `Type/Schema.swift:26`
tells callers to write `directives: specifiedDirectives + [myCustomDirective]`.

**Fix:** make `specifiedDirectives` public in the fork; Graphiti passes
`specifiedDirectives + custom`.

## Validation

Runs in Graphiti, in a second pass after all components are processed — a
directive may be applied by a `Type` the builder visits before the `Directive`
that declares it, so validation cannot happen during `update`.

Rejections, all thrown as `SchemaError` at schema-build time:

- undeclared directive name
- application at a location the declaration does not list
- unknown argument name
- missing non-null argument with no default
- argument value that will not coerce to the declared type (`astFromValue`
  returns nil)
- a non-`repeatable` directive applied twice at the same target

The renderer stays permissive, skipping anything unresolvable rather than
trapping: Graphiti has already rejected the bad cases, and the fork entry point
is public API that should not crash on odd input.

## Testing

In `Tests/GraphitiTests/DirectiveTests/`, using the existing swift-testing style
(`@Test`, `#expect`). TDD throughout — each test written failing first.

1. **Byte-identity regression.** For each existing test schema, assert
   `printSchema(schema:)` is character-for-character equal to
   `printSchema(schema:appliedDirectives: [:])`. Threading a parameter through
   eight print functions is exactly the refactor that shifts a space or a
   newline; this pins all existing output for free.
2. **Rendering.** One test per row of the injection-point table.
3. **Parse-back invariant.** Emitted SDL must `parse` without error — catches
   malformed construction generically.
4. **Enum vs string.** `("role", "ADMIN")` against an enum arg emits
   `@auth(role: ADMIN)` unquoted; `("name", "pii")` against `String` emits
   `@tag(name: "pii")` quoted. Highest-risk detail in the design.
5. **Determinism.** Build the same schema twice, compare output byte-for-byte.
   Guards the ordered-pairs decision.
6. **Schema-block forcing.** A schema-level directive forces the `schema { }`
   block to print.
7. **Validation.** One test per rejection rule above.
8. **Spec-directive preservation.** `@skip` still works alongside custom
   directives — pins the landmine.

## Repository sequencing

The work spans two repositories:

1. `tripleclabs/GraphQL` — `printSchema` parameter threading, `AppliedDirective`,
   `DirectiveTarget`, `public specifiedDirectives`.
2. Bump the revision pin at `Package.swift:12`.
3. `tripleclabs/graphiti` — DSL components, side table, validation, `sdl()`,
   docs.

The Graphiti side cannot build against the new API until steps 1 and 2 land.
Local development will need the fork checked out and referenced by path, since
`.build/checkouts/GraphQL` is a managed working copy of a local mirror and is
not a suitable place to develop the change.
