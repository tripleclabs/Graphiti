# SDL Directive Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Graphiti users declare custom GraphQL directives and apply them at every type-system location, and render both into printed SDL for codegen consumption.

**Architecture:** Graphiti holds applied directives in a side table keyed by schema path. The pinned GraphQL fork's `printSchema` gains an optional map parameter and emits them, converting argument values through `astFromValue` against the declared argument types. No changes to the fork's type objects, no SDL round trip, no execution semantics.

**Tech Stack:** Swift 6.2 (Graphiti) / Swift 5.8 tools (fork), SwiftPM, swift-testing (`@Test` / `#expect`), `tripleclabs/GraphQL` fork of GraphQLSwift/GraphQL.

**Spec:** `docs/superpowers/specs/2026-08-24-sdl-directive-rendering-design.md`

## Global Constraints

- Direction is **schema to SDL only**. Do not touch `buildASTSchema`, `extendSchema`, introspection, or execution.
- The existing `printSchema(schema:)` signature must keep working unchanged — all new parameters are defaulted.
- No AST node initializer or `astFromValue` may be made `public`. All AST construction stays inside the GraphQL module.
- Emitted SDL must be **byte-stable across builds**: never iterate an unordered `Dictionary` when producing output.
- Built-in directives (`@deprecated`, `@specifiedBy`, `@oneOf`) print before custom ones.
- Graphiti test style is swift-testing: `@Test func name() throws`, `#expect(...)`. No XCTest.
- Fork test style is the same, plus `@Suite struct`.
- Commit after every task.

## Repository Setup (do this before Task 1)

Two repositories are involved. `.build/checkouts/GraphQL` is a SwiftPM-managed working copy of a local mirror — **do not develop there**, changes will be discarded.

```bash
cd ~/src
git clone git@github.com:tripleclabs/GraphQL.git graphql-swift
cd graphql-swift
git checkout -b feat/sdl-applied-directives 2034ec6d29c23623b20a7c21f2b04658341cd0d0
```

Then, from the Graphiti checkout, point SwiftPM at it for local development:

```bash
cd ~/src/graphiti
swift package edit GraphQL --path ~/src/graphql-swift
```

This creates a `Packages/` symlink and makes `swift build` in Graphiti compile against your working fork. Undo at the end with `swift package unedit GraphQL`.

Tasks 1-6 run `swift test` inside `~/src/graphql-swift`. Tasks 8-12 run `swift test` inside `~/src/graphiti`.

---

## Phase A — GraphQL fork

### Task 1: Make `specifiedDirectives` public

Graphiti passes its directive array to `GraphQLSchema.init`, which does `self.directives = directives.isEmpty ? specifiedDirectives : directives` (`Type/Schema.swift:93`). The moment Graphiti declares one custom directive, `@skip`, `@include`, `@deprecated` and `@specifiedBy` are dropped from the schema. Graphiti cannot merge them back because `specifiedDirectives` is internal — even though the doc comment at `Type/Schema.swift:26` tells callers to do exactly that.

**Files:**
- Modify: `Sources/GraphQL/Type/Directives.swift:167`
- Test: `Tests/GraphQLTests/TypeTests/DirectivesTests.swift` (create)

**Interfaces:**
- Consumes: nothing
- Produces: `public let specifiedDirectives: [GraphQLDirective]`

- [ ] **Step 1: Write the failing test**

Create `Tests/GraphQLTests/TypeTests/DirectivesTests.swift`. Note this file uses a plain `import GraphQL`, **not** `@testable import` — the whole point is proving the symbol is visible to external modules like Graphiti.

```swift
import GraphQL
import Testing

@Suite struct SpecifiedDirectivesVisibilityTests {
    @Test func specifiedDirectivesIsPubliclyVisible() throws {
        let names = specifiedDirectives.map { $0.name }.sorted()
        #expect(names == ["deprecated", "include", "skip", "specifiedBy"])
    }

    @Test func customDirectivesCanBeMergedWithSpecified() throws {
        let custom = try GraphQLDirective(name: "model", locations: [.object])
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["a": GraphQLField(type: GraphQLString)]
        )
        let schema = try GraphQLSchema(
            query: query,
            directives: specifiedDirectives + [custom]
        )
        let names = schema.directives.map { $0.name }
        #expect(names.contains("skip"))
        #expect(names.contains("include"))
        #expect(names.contains("model"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpecifiedDirectivesVisibilityTests`
Expected: FAIL to compile — "cannot find 'specifiedDirectives' in scope".

- [ ] **Step 3: Write minimal implementation**

In `Sources/GraphQL/Type/Directives.swift:167`, change:

```swift
let specifiedDirectives: [GraphQLDirective] = [
```

to:

```swift
public let specifiedDirectives: [GraphQLDirective] = [
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SpecifiedDirectivesVisibilityTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the full fork suite**

Run: `swift test`
Expected: PASS. Nothing else should change — this is a visibility-only edit.

- [ ] **Step 6: Commit**

```bash
git add Sources/GraphQL/Type/Directives.swift Tests/GraphQLTests/TypeTests/DirectivesTests.swift
git commit -m "feat: make specifiedDirectives public"
```

---

### Task 2: Applied-directive boundary types and AST conversion

The public value type Graphiti passes across the module boundary, plus the conversion from `Map` argument values to `Directive` AST nodes. Conversion resolves the directive name against `schema.directives` to get declared argument types, so `("role", "ADMIN")` against an enum-typed argument emits `ADMIN` unquoted while `("name", "pii")` against `String` emits `"pii"` quoted.

**Files:**
- Create: `Sources/GraphQL/Utilities/AppliedDirectives.swift`
- Test: `Tests/GraphQLTests/UtilitiesTests/AppliedDirectivesTests.swift` (create)

**Interfaces:**
- Consumes: `astFromValue(value:type:)` from `Utilities/ASTFromValue.swift` (internal, same module); `Directive`, `Argument`, `Name` AST nodes (internal inits, same module).
- Produces:
  - `public enum DirectiveTarget: Hashable, Sendable` with cases `.schema`, `.type(String)`, `.member(type: String, member: String)`, `.argument(type: String, field: String, argument: String)`
  - `public struct AppliedDirective: Sendable` with `public let name: String`, `public let arguments: [(String, Map)]`, and `public init(name:arguments:)`
  - `public typealias AppliedDirectiveMap = [DirectiveTarget: [AppliedDirective]]`
  - `func printAppliedDirectives(_ target: DirectiveTarget, _ map: AppliedDirectiveMap, _ schema: GraphQLSchema) -> String` — internal, returns `""` or a leading-space-prefixed string like `" @model(table: \"users\")"`
  - `public func coercionErrors(for applied: AppliedDirective, against definition: GraphQLDirective) -> [String]` — consumed by Graphiti in Task 10

- [ ] **Step 1: Write the failing test**

Create `Tests/GraphQLTests/UtilitiesTests/AppliedDirectivesTests.swift`:

```swift
@testable import GraphQL
import Testing

private func schemaWithDirectives() throws -> GraphQLSchema {
    let role = try GraphQLEnumType(
        name: "Role",
        values: ["ADMIN": GraphQLEnumValue(value: .string("ADMIN"))]
    )
    let auth = try GraphQLDirective(
        name: "auth",
        locations: [.fieldDefinition],
        args: ["role": GraphQLArgument(type: role)]
    )
    let tag = try GraphQLDirective(
        name: "tag",
        locations: [.fieldDefinition, .object],
        args: ["name": GraphQLArgument(type: GraphQLString)]
    )
    let flag = try GraphQLDirective(name: "flag", locations: [.object])
    let query = try GraphQLObjectType(
        name: "Query",
        fields: ["a": GraphQLField(type: GraphQLString)]
    )
    return try GraphQLSchema(
        query: query,
        types: [role],
        directives: specifiedDirectives + [auth, tag, flag]
    )
}

@Suite struct AppliedDirectivePrintingTests {
    @Test func printsNothingWhenTargetHasNoDirectives() throws {
        let schema = try schemaWithDirectives()
        let result = printAppliedDirectives(.type("User"), [:], schema)
        #expect(result == "")
    }

    @Test func printsDirectiveWithNoArguments() throws {
        let schema = try schemaWithDirectives()
        let map: AppliedDirectiveMap = [
            .type("User"): [AppliedDirective(name: "flag", arguments: [])],
        ]
        #expect(printAppliedDirectives(.type("User"), map, schema) == " @flag")
    }

    @Test func printsStringArgumentQuoted() throws {
        let schema = try schemaWithDirectives()
        let map: AppliedDirectiveMap = [
            .type("User"): [AppliedDirective(name: "tag", arguments: [("name", "pii")])],
        ]
        #expect(printAppliedDirectives(.type("User"), map, schema) == " @tag(name: \"pii\")")
    }

    @Test func printsEnumArgumentUnquoted() throws {
        let schema = try schemaWithDirectives()
        let map: AppliedDirectiveMap = [
            .member(type: "User", member: "email"): [
                AppliedDirective(name: "auth", arguments: [("role", "ADMIN")]),
            ],
        ]
        let result = printAppliedDirectives(.member(type: "User", member: "email"), map, schema)
        #expect(result == " @auth(role: ADMIN)")
    }

    @Test func printsMultipleDirectivesInDeclarationOrder() throws {
        let schema = try schemaWithDirectives()
        let map: AppliedDirectiveMap = [
            .type("User"): [
                AppliedDirective(name: "flag", arguments: []),
                AppliedDirective(name: "tag", arguments: [("name", "pii")]),
            ],
        ]
        #expect(printAppliedDirectives(.type("User"), map, schema) == " @flag @tag(name: \"pii\")")
    }

    @Test func skipsUndeclaredDirectiveRatherThanTrapping() throws {
        let schema = try schemaWithDirectives()
        let map: AppliedDirectiveMap = [
            .type("User"): [AppliedDirective(name: "nope", arguments: [])],
        ]
        #expect(printAppliedDirectives(.type("User"), map, schema) == "")
    }

    @Test func coercionErrorsAreEmptyForValidValues() throws {
        let tag = try GraphQLDirective(
            name: "tag",
            locations: [.object],
            args: ["name": GraphQLArgument(type: GraphQLString)]
        )
        let applied = AppliedDirective(name: "tag", arguments: [("name", "pii")])
        #expect(coercionErrors(for: applied, against: tag).isEmpty)
    }

    @Test func coercionErrorsReportUncoercibleValues() throws {
        let count = try GraphQLDirective(
            name: "count",
            locations: [.object],
            args: ["n": GraphQLArgument(type: GraphQLInt)]
        )
        let applied = AppliedDirective(name: "count", arguments: [("n", "not a number")])
        #expect(!coercionErrors(for: applied, against: count).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AppliedDirectivePrintingTests`
Expected: FAIL to compile — "cannot find type 'AppliedDirective' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/GraphQL/Utilities/AppliedDirectives.swift`:

```swift
/// Identifies a location in a schema where directives may be applied.
///
/// Named types are unique schema-wide, so a single `type` case covers objects,
/// interfaces, unions, enums, input objects and scalars. A single `member` case
/// covers object fields, input fields and enum values.
public enum DirectiveTarget: Hashable, Sendable {
    case schema
    case type(String)
    case member(type: String, member: String)
    case argument(type: String, field: String, argument: String)
}

/// A directive applied to a schema location, to be rendered into SDL.
///
/// Arguments are ordered pairs rather than a dictionary so that emitted SDL is
/// byte-stable across builds.
public struct AppliedDirective: Sendable {
    public let name: String
    public let arguments: [(String, Map)]

    public init(name: String, arguments: [(String, Map)] = []) {
        self.name = name
        self.arguments = arguments
    }
}

public typealias AppliedDirectiveMap = [DirectiveTarget: [AppliedDirective]]

/// Builds a `Directive` AST node from an applied directive, resolving argument
/// values against the declared argument types so enums render unquoted.
///
/// Returns nil when the directive is not declared in the schema. Callers of the
/// public print API may pass anything, so this skips rather than traps.
func directiveNode(
    from applied: AppliedDirective,
    schema: GraphQLSchema
) -> Directive? {
    guard let definition = schema.directives.first(where: { $0.name == applied.name }) else {
        return nil
    }

    var arguments: [Argument] = []
    for (argName, argValue) in applied.arguments {
        guard let argDefinition = definition.args.first(where: { $0.name == argName }) else {
            continue
        }
        guard let valueNode = try? astFromValue(value: argValue, type: argDefinition.type) else {
            continue
        }
        arguments.append(Argument(name: Name(value: argName), value: valueNode))
    }

    return Directive(name: Name(value: applied.name), arguments: arguments)
}

/// Renders the directives applied at `target` as a space-prefixed SDL fragment,
/// or the empty string when there are none.
func printAppliedDirectives(
    _ target: DirectiveTarget,
    _ map: AppliedDirectiveMap,
    _ schema: GraphQLSchema
) -> String {
    guard let applied = map[target], !applied.isEmpty else {
        return ""
    }

    let printed = applied
        .compactMap { directiveNode(from: $0, schema: schema) }
        .map { print(ast: $0) }

    return printed.isEmpty ? "" : " " + printed.joined(separator: " ")
}

/// Returns a human-readable error for each argument value that will not coerce
/// to its declared type, or an empty array when every value is valid.
///
/// This lives here because `astFromValue` is internal to this module; callers
/// outside it (such as Graphiti's schema validation) cannot perform the check
/// themselves. Arguments not present on the definition are ignored — the caller
/// is expected to reject unknown argument names separately.
public func coercionErrors(
    for applied: AppliedDirective,
    against definition: GraphQLDirective
) -> [String] {
    var errors: [String] = []

    for (argName, argValue) in applied.arguments {
        guard let argDefinition = definition.args.first(where: { $0.name == argName }) else {
            continue
        }
        let node = try? astFromValue(value: argValue, type: argDefinition.type)
        if node == nil {
            errors.append(
                "Value for argument \(argName) of directive @\(applied.name) does not coerce to \(argDefinition.type)."
            )
        }
    }

    return errors
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AppliedDirectivePrintingTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/GraphQL/Utilities/AppliedDirectives.swift Tests/GraphQLTests/UtilitiesTests/AppliedDirectivesTests.swift
git commit -m "feat: add applied directive types and AST conversion"
```

---

### Task 3: Thread the map through `printSchema` onto named types

Add the defaulted parameter to the public entry point and the type-level print functions. This task covers objects, interfaces, unions, enums, input objects and scalars — the `.type(String)` target.

**Files:**
- Modify: `Sources/GraphQL/Utilities/PrintSchema.swift`
- Test: `Tests/GraphQLTests/UtilitiesTests/PrintSchemaDirectivesTests.swift` (create)

**Interfaces:**
- Consumes: `printAppliedDirectives(_:_:_:)`, `AppliedDirectiveMap`, `DirectiveTarget` from Task 2.
- Produces: `public func printSchema(schema: GraphQLSchema, appliedDirectives: AppliedDirectiveMap = [:]) -> String`

**Note on the existing test helper:** `Tests/GraphQLTests/UtilitiesTests/PrintSchemaTests.swift` defines `expectPrintedSchema(schema:)`, which round-trips through `buildSchema`. **Do not use it for directive tests** — applied directives live in a side map, not on the type objects, so they cannot survive `buildSchema`. Call `printSchema(schema:appliedDirectives:)` directly instead.

- [ ] **Step 1: Write the failing test**

Create `Tests/GraphQLTests/UtilitiesTests/PrintSchemaDirectivesTests.swift`:

```swift
@testable import GraphQL
import Testing

private func directiveDefinitions() throws -> [GraphQLDirective] {
    [
        try GraphQLDirective(
            name: "model",
            locations: [.object, .interface, .union, .enum, .inputObject, .scalar],
            args: ["table": GraphQLArgument(type: GraphQLString)]
        ),
    ]
}

@Suite struct PrintSchemaTypeDirectivesTests {
    @Test func printsDirectiveOnObjectType() throws {
        let user = try GraphQLObjectType(
            name: "User",
            fields: ["id": GraphQLField(type: GraphQLString)]
        )
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["user": GraphQLField(type: user)]
        )
        let schema = try GraphQLSchema(
            query: query,
            directives: specifiedDirectives + directiveDefinitions()
        )
        let sdl = printSchema(
            schema: schema,
            appliedDirectives: [
                .type("User"): [AppliedDirective(name: "model", arguments: [("table", "users")])],
            ]
        )
        #expect(sdl.contains("type User @model(table: \"users\") {"))
    }

    @Test func printsDirectiveAfterImplementsClause() throws {
        let node = try GraphQLInterfaceType(
            name: "Node",
            fields: ["id": GraphQLField(type: GraphQLString)]
        )
        let user = try GraphQLObjectType(
            name: "User",
            fields: ["id": GraphQLField(type: GraphQLString)],
            interfaces: [node]
        )
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["user": GraphQLField(type: user)]
        )
        let schema = try GraphQLSchema(
            query: query,
            types: [node, user],
            directives: specifiedDirectives + directiveDefinitions()
        )
        let sdl = printSchema(
            schema: schema,
            appliedDirectives: [.type("User"): [AppliedDirective(name: "model")]]
        )
        #expect(sdl.contains("type User implements Node @model {"))
    }

    @Test func printsDirectiveOnEnumBeforeBrace() throws {
        let role = try GraphQLEnumType(
            name: "Role",
            values: ["ADMIN": GraphQLEnumValue(value: .string("ADMIN"))]
        )
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["role": GraphQLField(type: role)]
        )
        let schema = try GraphQLSchema(
            query: query,
            directives: specifiedDirectives + directiveDefinitions()
        )
        let sdl = printSchema(
            schema: schema,
            appliedDirectives: [.type("Role"): [AppliedDirective(name: "model")]]
        )
        #expect(sdl.contains("enum Role @model {"))
    }

    @Test func printsDirectiveOnUnionBeforeEquals() throws {
        let a = try GraphQLObjectType(name: "A", fields: ["x": GraphQLField(type: GraphQLString)])
        let b = try GraphQLObjectType(name: "B", fields: ["y": GraphQLField(type: GraphQLString)])
        let result = try GraphQLUnionType(name: "Result", types: [a, b])
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["r": GraphQLField(type: result)]
        )
        let schema = try GraphQLSchema(
            query: query,
            directives: specifiedDirectives + directiveDefinitions()
        )
        let sdl = printSchema(
            schema: schema,
            appliedDirectives: [.type("Result"): [AppliedDirective(name: "model")]]
        )
        #expect(sdl.contains("union Result @model = A | B"))
    }

    @Test func printsDirectiveOnInputObjectBeforeBrace() throws {
        let filter = try GraphQLInputObjectType(
            name: "Filter",
            fields: ["q": InputObjectField(type: GraphQLString)]
        )
        let query = try GraphQLObjectType(
            name: "Query",
            fields: [
                "search": GraphQLField(
                    type: GraphQLString,
                    args: ["filter": GraphQLArgument(type: filter)]
                ),
            ]
        )
        let schema = try GraphQLSchema(
            query: query,
            directives: specifiedDirectives + directiveDefinitions()
        )
        let sdl = printSchema(
            schema: schema,
            appliedDirectives: [.type("Filter"): [AppliedDirective(name: "model")]]
        )
        #expect(sdl.contains("input Filter @model {"))
    }

    @Test func printsDirectiveOnScalar() throws {
        let dateTime = try GraphQLScalarType(name: "DateTime")
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["now": GraphQLField(type: dateTime)]
        )
        let schema = try GraphQLSchema(
            query: query,
            directives: specifiedDirectives + directiveDefinitions()
        )
        let sdl = printSchema(
            schema: schema,
            appliedDirectives: [.type("DateTime"): [AppliedDirective(name: "model")]]
        )
        #expect(sdl.contains("scalar DateTime @model"))
    }

    @Test func emptyMapProducesIdenticalOutputToLegacyEntryPoint() throws {
        let user = try GraphQLObjectType(
            name: "User",
            fields: ["id": GraphQLField(type: GraphQLString)]
        )
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["user": GraphQLField(type: user)]
        )
        let schema = try GraphQLSchema(query: query)
        #expect(printSchema(schema: schema) == printSchema(schema: schema, appliedDirectives: [:]))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PrintSchemaTypeDirectivesTests`
Expected: FAIL to compile — `printSchema` has no `appliedDirectives` parameter.

- [ ] **Step 3: Write minimal implementation**

In `Sources/GraphQL/Utilities/PrintSchema.swift`, change the entry point and thread the map down. The functions below replace their current definitions:

```swift
public func printSchema(
    schema: GraphQLSchema,
    appliedDirectives: AppliedDirectiveMap = [:]
) -> String {
    return printFilteredSchema(
        schema: schema,
        directiveFilter: { n in !isSpecifiedDirective(n) },
        typeFilter: isDefinedType,
        appliedDirectives: appliedDirectives
    )
}

public func printIntrospectionSchema(schema: GraphQLSchema) -> String {
    return printFilteredSchema(
        schema: schema,
        directiveFilter: isSpecifiedDirective,
        typeFilter: isIntrospectionType,
        appliedDirectives: [:]
    )
}

func printFilteredSchema(
    schema: GraphQLSchema,
    directiveFilter: (GraphQLDirective) -> Bool,
    typeFilter: (GraphQLNamedType) -> Bool,
    appliedDirectives: AppliedDirectiveMap = [:]
) -> String {
    let directives = schema.directives.filter { directiveFilter($0) }
    let types = schema.typeMap.values.filter { typeFilter($0) }

    var result = [printSchemaDefinition(schema: schema)]
    result.append(contentsOf: directives.map { printDirective(directive: $0) })
    result.append(contentsOf: types.map {
        printType(type: $0, appliedDirectives: appliedDirectives, schema: schema)
    })

    return result.compactMap { $0 }
        .joined(separator: "\n\n")
}
```

`printType` keeps its existing public one-argument form as a wrapper so external
call sites do not break, and gains an internal directive-aware form:

```swift
public func printType(type: GraphQLNamedType) -> String {
    return printType(type: type, appliedDirectives: [:], schema: nil)
}

func printType(
    type: GraphQLNamedType,
    appliedDirectives: AppliedDirectiveMap,
    schema: GraphQLSchema?
) -> String {
    let directives: String = {
        guard let schema = schema else { return "" }
        return printAppliedDirectives(.type(type.name), appliedDirectives, schema)
    }()

    if let type = type as? GraphQLScalarType {
        return printScalar(type: type, directives: directives)
    }
    if let type = type as? GraphQLObjectType {
        return printObject(type: type, directives: directives)
    }
    if let type = type as? GraphQLInterfaceType {
        return printInterface(type: type, directives: directives)
    }
    if let type = type as? GraphQLUnionType {
        return printUnion(type: type, directives: directives)
    }
    if let type = type as? GraphQLEnumType {
        return printEnum(type: type, directives: directives)
    }
    if let type = type as? GraphQLInputObjectType {
        return printInputObject(type: type, directives: directives)
    }

    // Not reachable, all possible types have been considered.
    fatalError("Unexpected type: " + type.name)
}
```

Then give each type printer a defaulted `directives` parameter, inserted at the
position from the spec's injection table:

```swift
func printScalar(type: GraphQLScalarType, directives: String = "") -> String {
    return printDescription(type.description) +
        "scalar \(type.name)" +
        printSpecifiedByURL(scalar: type) +
        directives
}

func printObject(type: GraphQLObjectType, directives: String = "") -> String {
    return
        printDescription(type.description) +
        "type \(type.name)" +
        printImplementedInterfaces(interfaces: (try? type.getInterfaces()) ?? []) +
        directives +
        printFields(fields: (try? type.getFields()) ?? [:])
}

func printInterface(type: GraphQLInterfaceType, directives: String = "") -> String {
    return
        printDescription(type.description) +
        "interface \(type.name)" +
        printImplementedInterfaces(interfaces: (try? type.getInterfaces()) ?? []) +
        directives +
        printFields(fields: (try? type.getFields()) ?? [:])
}

func printUnion(type: GraphQLUnionType, directives: String = "") -> String {
    let types = (try? type.getTypes()) ?? []
    return
        printDescription(type.description) +
        "union \(type.name)" +
        directives +
        (types.isEmpty ? "" : " = " + types.map { $0.name }.joined(separator: " | "))
}

func printEnum(type: GraphQLEnumType, directives: String = "") -> String {
    let values = type.values.enumerated().map { i, value in
        printDescription(value.description, indentation: "  ", firstInBlock: i == 0) +
            "  " +
            value.name +
            printDeprecated(reason: value.deprecationReason)
    }

    return printDescription(type.description) + "enum \(type.name)" + directives +
        printBlock(items: values)
}

func printInputObject(type: GraphQLInputObjectType, directives: String = "") -> String {
    let inputFields = (try? type.getFields()) ?? [:]
    let fields = inputFields.values.enumerated().map { i, f in
        printDescription(f.description, indentation: "  ", firstInBlock: i == 0) + "  " +
            printInputValue(arg: f)
    }

    return
        printDescription(type.description) +
        "input \(type.name)" +
        (type.isOneOf ? " @oneOf" : "") +
        directives +
        printBlock(items: fields)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PrintSchemaTypeDirectivesTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Run the full fork suite to catch formatting drift**

Run: `swift test`
Expected: PASS. The existing `PrintSchemaTests` suite asserts exact SDL text for dozens of schemas and round-trips each through `buildSchema`; it is the regression net for this refactor. Any failure here means a stray space or newline was introduced — fix it before committing.

- [ ] **Step 6: Commit**

```bash
git add Sources/GraphQL/Utilities/PrintSchema.swift Tests/GraphQLTests/UtilitiesTests/PrintSchemaDirectivesTests.swift
git commit -m "feat: render applied directives on named types"
```

---

### Task 4: Render directives on members and arguments

Fields, input fields, enum values (all `.member`) and field arguments (`.argument`). These printers currently receive no owning-type name, so it has to be threaded in.

**Files:**
- Modify: `Sources/GraphQL/Utilities/PrintSchema.swift`
- Test: `Tests/GraphQLTests/UtilitiesTests/PrintSchemaDirectivesTests.swift`

**Interfaces:**
- Consumes: everything from Task 3.
- Produces: no new public API — internal printers gain `typeName`, `appliedDirectives` and `schema` parameters.

- [ ] **Step 1: Write the failing test**

Append to `Tests/GraphQLTests/UtilitiesTests/PrintSchemaDirectivesTests.swift`:

```swift
private func memberDirectiveDefinitions() throws -> [GraphQLDirective] {
    [
        try GraphQLDirective(
            name: "unique",
            locations: [.fieldDefinition, .enumValue, .inputFieldDefinition, .argumentDefinition]
        ),
    ]
}

@Suite struct PrintSchemaMemberDirectivesTests {
    @Test func printsDirectiveOnObjectField() throws {
        let user = try GraphQLObjectType(
            name: "User",
            fields: ["email": GraphQLField(type: GraphQLString)]
        )
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["user": GraphQLField(type: user)]
        )
        let schema = try GraphQLSchema(
            query: query,
            directives: specifiedDirectives + memberDirectiveDefinitions()
        )
        let sdl = printSchema(
            schema: schema,
            appliedDirectives: [
                .member(type: "User", member: "email"): [AppliedDirective(name: "unique")],
            ]
        )
        #expect(sdl.contains("email: String @unique"))
    }

    @Test func printsDirectiveAfterDeprecatedOnField() throws {
        let user = try GraphQLObjectType(
            name: "User",
            fields: [
                "old": GraphQLField(type: GraphQLString, deprecationReason: "gone"),
            ]
        )
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["user": GraphQLField(type: user)]
        )
        let schema = try GraphQLSchema(
            query: query,
            directives: specifiedDirectives + memberDirectiveDefinitions()
        )
        let sdl = printSchema(
            schema: schema,
            appliedDirectives: [
                .member(type: "User", member: "old"): [AppliedDirective(name: "unique")],
            ]
        )
        #expect(sdl.contains("old: String @deprecated(reason: \"gone\") @unique"))
    }

    @Test func printsDirectiveOnEnumValue() throws {
        let role = try GraphQLEnumType(
            name: "Role",
            values: ["ADMIN": GraphQLEnumValue(value: .string("ADMIN"))]
        )
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["role": GraphQLField(type: role)]
        )
        let schema = try GraphQLSchema(
            query: query,
            directives: specifiedDirectives + memberDirectiveDefinitions()
        )
        let sdl = printSchema(
            schema: schema,
            appliedDirectives: [
                .member(type: "Role", member: "ADMIN"): [AppliedDirective(name: "unique")],
            ]
        )
        #expect(sdl.contains("  ADMIN @unique"))
    }

    @Test func printsDirectiveOnInputField() throws {
        let filter = try GraphQLInputObjectType(
            name: "Filter",
            fields: ["q": InputObjectField(type: GraphQLString)]
        )
        let query = try GraphQLObjectType(
            name: "Query",
            fields: [
                "search": GraphQLField(
                    type: GraphQLString,
                    args: ["filter": GraphQLArgument(type: filter)]
                ),
            ]
        )
        let schema = try GraphQLSchema(
            query: query,
            directives: specifiedDirectives + memberDirectiveDefinitions()
        )
        let sdl = printSchema(
            schema: schema,
            appliedDirectives: [
                .member(type: "Filter", member: "q"): [AppliedDirective(name: "unique")],
            ]
        )
        #expect(sdl.contains("q: String @unique"))
    }

    @Test func printsDirectiveOnFieldArgument() throws {
        let query = try GraphQLObjectType(
            name: "Query",
            fields: [
                "user": GraphQLField(
                    type: GraphQLString,
                    args: ["id": GraphQLArgument(type: GraphQLString)]
                ),
            ]
        )
        let schema = try GraphQLSchema(
            query: query,
            directives: specifiedDirectives + memberDirectiveDefinitions()
        )
        let sdl = printSchema(
            schema: schema,
            appliedDirectives: [
                .argument(type: "Query", field: "user", argument: "id"): [
                    AppliedDirective(name: "unique"),
                ],
            ]
        )
        #expect(sdl.contains("user(id: String @unique): String"))
    }

    @Test func emittedSDLParsesCleanly() throws {
        let user = try GraphQLObjectType(
            name: "User",
            fields: ["email": GraphQLField(type: GraphQLString)]
        )
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["user": GraphQLField(type: user)]
        )
        let schema = try GraphQLSchema(
            query: query,
            directives: specifiedDirectives + memberDirectiveDefinitions()
        )
        let sdl = printSchema(
            schema: schema,
            appliedDirectives: [
                .member(type: "User", member: "email"): [AppliedDirective(name: "unique")],
            ]
        )
        _ = try parse(source: Source(body: sdl))
    }

    @Test func outputIsDeterministicAcrossRuns() throws {
        func render() throws -> String {
            let user = try GraphQLObjectType(
                name: "User",
                fields: [
                    "email": GraphQLField(type: GraphQLString),
                    "name": GraphQLField(type: GraphQLString),
                ]
            )
            let query = try GraphQLObjectType(
                name: "Query",
                fields: ["user": GraphQLField(type: user)]
            )
            let schema = try GraphQLSchema(
                query: query,
                directives: specifiedDirectives + memberDirectiveDefinitions()
            )
            return printSchema(
                schema: schema,
                appliedDirectives: [
                    .member(type: "User", member: "email"): [
                        AppliedDirective(name: "unique"),
                    ],
                ]
            )
        }
        #expect(try render() == render())
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PrintSchemaMemberDirectivesTests`
Expected: FAIL — directives do not appear on members; assertions fail.

- [ ] **Step 3: Write minimal implementation**

In `Sources/GraphQL/Utilities/PrintSchema.swift`, thread the owning type name and map down through the member printers. Replace the current definitions:

```swift
func printFields(
    fields: GraphQLFieldDefinitionMap,
    typeName: String = "",
    appliedDirectives: AppliedDirectiveMap = [:],
    schema: GraphQLSchema? = nil
) -> String {
    let fields = fields.values.enumerated().map { i, f in
        let fieldDirectives: String = {
            guard let schema = schema else { return "" }
            return printAppliedDirectives(
                .member(type: typeName, member: f.name),
                appliedDirectives,
                schema
            )
        }()

        return printDescription(f.description, indentation: "  ", firstInBlock: i == 0) +
            "  " +
            f.name +
            printArgs(
                args: f.args,
                indentation: "  ",
                typeName: typeName,
                fieldName: f.name,
                appliedDirectives: appliedDirectives,
                schema: schema
            ) +
            ": " +
            f.type.debugDescription +
            printDeprecated(reason: f.deprecationReason) +
            fieldDirectives
    }
    return printBlock(items: fields)
}

func printArgs(
    args: [GraphQLArgumentDefinition],
    indentation: String = "",
    typeName: String = "",
    fieldName: String = "",
    appliedDirectives: AppliedDirectiveMap = [:],
    schema: GraphQLSchema? = nil
) -> String {
    if args.isEmpty {
        return ""
    }

    func directives(for arg: GraphQLArgumentDefinition) -> String {
        guard let schema = schema else { return "" }
        return printAppliedDirectives(
            .argument(type: typeName, field: fieldName, argument: arg.name),
            appliedDirectives,
            schema
        )
    }

    // If every arg does not have a description, print them on one line.
    if args.allSatisfy({ $0.description == nil }) {
        return "(" + args.map { printArgValue(arg: $0) + directives(for: $0) }
            .joined(separator: ", ") + ")"
    }

    return
        "(\n" +
        args.enumerated().map { i, arg in
            printDescription(
                arg.description,
                indentation: "  " + indentation,
                firstInBlock: i == 0
            ) +
                "  " +
                indentation +
                printArgValue(arg: arg) +
                directives(for: arg)
        }.joined(separator: "\n") +
        "\n" +
        indentation +
        ")"
}
```

Update `printObject`, `printInterface`, `printEnum` and `printInputObject` from Task 3 to pass the new arguments. Their signatures gain `appliedDirectives` and `schema`:

```swift
func printObject(
    type: GraphQLObjectType,
    directives: String = "",
    appliedDirectives: AppliedDirectiveMap = [:],
    schema: GraphQLSchema? = nil
) -> String {
    return
        printDescription(type.description) +
        "type \(type.name)" +
        printImplementedInterfaces(interfaces: (try? type.getInterfaces()) ?? []) +
        directives +
        printFields(
            fields: (try? type.getFields()) ?? [:],
            typeName: type.name,
            appliedDirectives: appliedDirectives,
            schema: schema
        )
}

func printInterface(
    type: GraphQLInterfaceType,
    directives: String = "",
    appliedDirectives: AppliedDirectiveMap = [:],
    schema: GraphQLSchema? = nil
) -> String {
    return
        printDescription(type.description) +
        "interface \(type.name)" +
        printImplementedInterfaces(interfaces: (try? type.getInterfaces()) ?? []) +
        directives +
        printFields(
            fields: (try? type.getFields()) ?? [:],
            typeName: type.name,
            appliedDirectives: appliedDirectives,
            schema: schema
        )
}

func printEnum(
    type: GraphQLEnumType,
    directives: String = "",
    appliedDirectives: AppliedDirectiveMap = [:],
    schema: GraphQLSchema? = nil
) -> String {
    let values = type.values.enumerated().map { i, value in
        let valueDirectives: String = {
            guard let schema = schema else { return "" }
            return printAppliedDirectives(
                .member(type: type.name, member: value.name),
                appliedDirectives,
                schema
            )
        }()

        return printDescription(value.description, indentation: "  ", firstInBlock: i == 0) +
            "  " +
            value.name +
            printDeprecated(reason: value.deprecationReason) +
            valueDirectives
    }

    return printDescription(type.description) + "enum \(type.name)" + directives +
        printBlock(items: values)
}

func printInputObject(
    type: GraphQLInputObjectType,
    directives: String = "",
    appliedDirectives: AppliedDirectiveMap = [:],
    schema: GraphQLSchema? = nil
) -> String {
    let inputFields = (try? type.getFields()) ?? [:]
    let fields = inputFields.values.enumerated().map { i, f in
        let fieldDirectives: String = {
            guard let schema = schema else { return "" }
            return printAppliedDirectives(
                .member(type: type.name, member: f.name),
                appliedDirectives,
                schema
            )
        }()

        return printDescription(f.description, indentation: "  ", firstInBlock: i == 0) + "  " +
            printInputValue(arg: f) + fieldDirectives
    }

    return
        printDescription(type.description) +
        "input \(type.name)" +
        (type.isOneOf ? " @oneOf" : "") +
        directives +
        printBlock(items: fields)
}
```

Finally, update the internal `printType(type:appliedDirectives:schema:)` from Task 3 to forward the two new arguments to `printObject`, `printInterface`, `printEnum` and `printInputObject`:

```swift
    if let type = type as? GraphQLObjectType {
        return printObject(
            type: type,
            directives: directives,
            appliedDirectives: appliedDirectives,
            schema: schema
        )
    }
```

Apply the same forwarding to the interface, enum and input-object branches. The scalar and union branches take no members and keep the Task 3 form.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PrintSchemaMemberDirectivesTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Run the full fork suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/GraphQL/Utilities/PrintSchema.swift Tests/GraphQLTests/UtilitiesTests/PrintSchemaDirectivesTests.swift
git commit -m "feat: render applied directives on members and arguments"
```

---

### Task 5: Force the schema block when a schema-level directive is applied

`printSchemaDefinition` returns nil when root operation types use the default names, omitting the `schema { }` block entirely. A directive applied to `.schema` would silently vanish.

**Files:**
- Modify: `Sources/GraphQL/Utilities/PrintSchema.swift:38-66`
- Test: `Tests/GraphQLTests/UtilitiesTests/PrintSchemaDirectivesTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2-4.
- Produces: no new public API.

- [ ] **Step 1: Write the failing test**

Append to `Tests/GraphQLTests/UtilitiesTests/PrintSchemaDirectivesTests.swift`:

```swift
@Suite struct PrintSchemaDefinitionDirectivesTests {
    private func linkSchema() throws -> GraphQLSchema {
        let link = try GraphQLDirective(
            name: "link",
            locations: [.schema],
            args: ["url": GraphQLArgument(type: GraphQLString)]
        )
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["a": GraphQLField(type: GraphQLString)]
        )
        return try GraphQLSchema(query: query, directives: specifiedDirectives + [link])
    }

    @Test func schemaBlockIsOmittedWithoutSchemaDirective() throws {
        let sdl = printSchema(schema: try linkSchema())
        #expect(!sdl.contains("schema"))
    }

    @Test func schemaDirectiveForcesSchemaBlockToPrint() throws {
        let sdl = printSchema(
            schema: try linkSchema(),
            appliedDirectives: [
                .schema: [
                    AppliedDirective(name: "link", arguments: [("url", "https://example.com/v1")]),
                ],
            ]
        )
        #expect(sdl.contains("schema @link(url: \"https://example.com/v1\") {"))
        #expect(sdl.contains("  query: Query"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PrintSchemaDefinitionDirectivesTests`
Expected: FAIL — `schemaDirectiveForcesSchemaBlockToPrint` fails; the block is not printed.

- [ ] **Step 3: Write minimal implementation**

Replace `printSchemaDefinition` in `Sources/GraphQL/Utilities/PrintSchema.swift`:

```swift
func printSchemaDefinition(
    schema: GraphQLSchema,
    appliedDirectives: AppliedDirectiveMap = [:]
) -> String? {
    let queryType = schema.queryType
    let mutationType = schema.mutationType
    let subscriptionType = schema.subscriptionType

    // Special case: When a schema has no root operation types, no valid schema
    // definition can be printed.
    if queryType == nil, mutationType == nil, subscriptionType == nil {
        return nil
    }

    let directives = printAppliedDirectives(.schema, appliedDirectives, schema)

    // Only print a schema definition if there is a description, an applied
    // directive that would otherwise be lost, or if it should not be omitted
    // because of having default type names.
    if schema.description != nil || !directives.isEmpty ||
        !hasDefaultRootOperationTypes(schema: schema)
    {
        var result = printDescription(schema.description) +
            "schema" + directives + " {\n"
        if let queryType = queryType {
            result = result + "  query: \(queryType.name)\n"
        }
        if let mutationType = mutationType {
            result = result + "  mutation: \(mutationType.name)\n"
        }
        if let subscriptionType = subscriptionType {
            result = result + "  subscription: \(subscriptionType.name)\n"
        }
        result = result + "}"
        return result
    }
    return nil
}
```

Note the original built the header as `"schema {\n"`; it is now `"schema" + directives + " {\n"` so that the empty-directives case produces the identical string.

Update the call site in `printFilteredSchema` (Task 3):

```swift
    var result = [printSchemaDefinition(schema: schema, appliedDirectives: appliedDirectives)]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PrintSchemaDefinitionDirectivesTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the full fork suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 6: Commit and push the fork branch**

```bash
git add Sources/GraphQL/Utilities/PrintSchema.swift Tests/GraphQLTests/UtilitiesTests/PrintSchemaDirectivesTests.swift
git commit -m "feat: force schema block when schema directive applied"
git push -u origin feat/sdl-applied-directives
```

---

## Phase B — Dependency pin

### Task 6: Bump the Graphiti pin to the fork commit

**Files:**
- Modify: `Package.swift:12` (in `~/src/graphiti`)

**Interfaces:**
- Consumes: the pushed fork branch from Task 5.
- Produces: a Graphiti checkout that builds against the new `printSchema` API.

- [ ] **Step 1: Get the fork commit SHA**

```bash
cd ~/src/graphql-swift && git rev-parse HEAD
```

- [ ] **Step 2: Update the pin**

In `~/src/graphiti/Package.swift:12`, replace the revision with the SHA from Step 1:

```swift
.package(url: "https://github.com/tripleclabs/GraphQL.git", revision: "<SHA FROM STEP 1>"),
```

- [ ] **Step 3: Drop the local edit override and resolve**

```bash
cd ~/src/graphiti
swift package unedit GraphQL
swift package resolve
swift build
```

Expected: builds cleanly. Graphiti does not use the new API yet, so nothing should change behaviourally.

- [ ] **Step 4: Run the Graphiti suite**

Run: `swift test`
Expected: PASS. This confirms the fork changes broke nothing downstream.

- [ ] **Step 5: Commit**

```bash
git add Package.swift
git commit -m "build: bump GraphQL pin for applied directive rendering"
```

---

## Phase C — Graphiti

### Task 7: `DirectiveAnnotatable` protocol and conformances

Five independent modifier hosts need `.directive(...)`. None share a base class, so the modifier goes in a protocol extension to avoid five copies.

**Files:**
- Create: `Sources/Graphiti/Directive/DirectiveAnnotatable.swift`
- Modify: `Sources/Graphiti/Component/Component.swift`, `Sources/Graphiti/Field/Field/FieldComponent.swift`, `Sources/Graphiti/Argument/ArgumentComponent.swift`, `Sources/Graphiti/InputField/InputFieldComponent.swift`, `Sources/Graphiti/Value/Value.swift`
- Test: `Tests/GraphitiTests/DirectiveTests/DirectiveAnnotationTests.swift` (create)

**Interfaces:**
- Consumes: `AppliedDirective` from the fork (Task 2).
- Produces:
  - `public protocol DirectiveAnnotatable: AnyObject { var appliedDirectives: [AppliedDirective] { get set } }`
  - `func directive(_ name: String, _ arguments: (String, Map)...) -> Self` on all conformers

- [ ] **Step 1: Write the failing test**

Create `Tests/GraphitiTests/DirectiveTests/DirectiveAnnotationTests.swift`:

```swift
@testable import Graphiti
import GraphQL
import Testing

private struct User: Codable, Sendable {
    let email: String
}

@Suite struct DirectiveAnnotationTests {
    @Test func fieldComponentRecordsAppliedDirectives() throws {
        let field = Field<User, NoContext, String, NoArguments>("email", at: \.email)
            .directive("unique")
            .directive("tag", ("name", "pii"))

        #expect(field.appliedDirectives.count == 2)
        #expect(field.appliedDirectives[0].name == "unique")
        #expect(field.appliedDirectives[0].arguments.isEmpty)
        #expect(field.appliedDirectives[1].name == "tag")
        #expect(field.appliedDirectives[1].arguments.count == 1)
        #expect(field.appliedDirectives[1].arguments[0].0 == "name")
        #expect(field.appliedDirectives[1].arguments[0].1 == Map.string("pii"))
    }

    @Test func typeComponentRecordsAppliedDirectives() throws {
        let type = Type<Void, NoContext, User>(User.self) {
            Field("email", at: \.email)
        }
        .directive("model", ("table", "users"))

        #expect(type.appliedDirectives.count == 1)
        #expect(type.appliedDirectives[0].name == "model")
        #expect(type.appliedDirectives[0].arguments[0].1 == Map.string("users"))
    }

    @Test func modifiersPreserveArgumentOrder() throws {
        let field = Field<User, NoContext, String, NoArguments>("email", at: \.email)
            .directive("constraint", ("min", 1), ("max", 10))

        let names = field.appliedDirectives[0].arguments.map { $0.0 }
        #expect(names == ["min", "max"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DirectiveAnnotationTests`
Expected: FAIL to compile — "value of type 'Field<...>' has no member 'directive'".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/Graphiti/Directive/DirectiveAnnotatable.swift`:

```swift
import GraphQL

/// A DSL component that can carry directives applied to its schema location.
///
/// The modifier lives in a protocol extension so that the five independent
/// component hierarchies do not each need their own copy.
public protocol DirectiveAnnotatable: AnyObject {
    var appliedDirectives: [AppliedDirective] { get set }
}

public extension DirectiveAnnotatable {
    /// Apply a directive to this schema location.
    ///
    /// The directive must be declared with a `Directive` component in the same
    /// schema, or schema construction throws. Argument values are rendered
    /// against the declared argument types, so a string passed to an enum-typed
    /// argument prints unquoted.
    ///
    /// - Parameters:
    ///   - name: The directive name, without the leading `@`.
    ///   - arguments: Ordered name/value pairs. Order is preserved in the
    ///     emitted SDL so output is byte-stable across builds.
    @discardableResult
    func directive(_ name: String, _ arguments: (String, Map)...) -> Self {
        appliedDirectives.append(AppliedDirective(name: name, arguments: arguments))
        return self
    }
}
```

Add the stored property and conformance to each of the five hosts. In
`Sources/Graphiti/Component/Component.swift`, add to the `Component` class body:

```swift
    public var appliedDirectives: [AppliedDirective] = []
```

and after the class declaration:

```swift
extension Component: DirectiveAnnotatable {}
```

Repeat the identical two edits in `FieldComponent`
(`Sources/Graphiti/Field/Field/FieldComponent.swift`), `ArgumentComponent`
(`Sources/Graphiti/Argument/ArgumentComponent.swift`), `InputFieldComponent`
(`Sources/Graphiti/InputField/InputFieldComponent.swift`) and `Value`
(`Sources/Graphiti/Value/Value.swift`), each time adding the stored property to
the class body and an `extension X: DirectiveAnnotatable {}` after it.

Do **not** refactor the existing duplicated `.description(_:)` modifiers into
this protocol — out of scope for this work.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DirectiveAnnotationTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Graphiti/Directive Sources/Graphiti/Component/Component.swift Sources/Graphiti/Field/Field/FieldComponent.swift Sources/Graphiti/Argument/ArgumentComponent.swift Sources/Graphiti/InputField/InputFieldComponent.swift Sources/Graphiti/Value/Value.swift Tests/GraphitiTests/DirectiveTests/DirectiveAnnotationTests.swift
git commit -m "feat: add directive application modifier to DSL components"
```

---

### Task 8: `Directive` declaration component

Declares a directive definition and feeds `SchemaTypeProvider.directives`, merged with `specifiedDirectives` so `@skip` and `@include` survive.

**Files:**
- Create: `Sources/Graphiti/Directive/Directive.swift`, `Sources/Graphiti/Directive/DirectiveArgument.swift`
- Modify: `Sources/Graphiti/Schema/Schema.swift:33`
- Test: `Tests/GraphitiTests/DirectiveTests/DirectiveDeclarationTests.swift` (create)

**Interfaces:**
- Consumes: `Component`, `ComponentType` from `Sources/Graphiti/Component/Component.swift`; `SchemaTypeProvider.directives`.
- Produces:
  - `public final class Directive<Resolver, Context>: Component<Resolver, Context>` with `init(_ name: String, on locations: DirectiveLocation..., repeatable: Bool = false, @DirectiveArgumentBuilder _ arguments: () -> [DirectiveArgument] = { [] })`
  - `public struct DirectiveArgument` with `init<T>(_ name: String, at type: T.Type, description: String? = nil, defaultValue: Map? = nil)`
  - `@resultBuilder public struct DirectiveArgumentBuilder`

- [ ] **Step 1: Write the failing test**

Create `Tests/GraphitiTests/DirectiveTests/DirectiveDeclarationTests.swift`:

```swift
@testable import Graphiti
import GraphQL
import Testing

private struct User: Codable, Sendable {
    let email: String
}

private struct DeclarationResolver: Sendable {
    func user(context: NoContext, arguments: NoArguments) -> User {
        User(email: "a@b.c")
    }
}

@Suite struct DirectiveDeclarationTests {
    private func schema() throws -> Schema<DeclarationResolver, NoContext> {
        try Schema<DeclarationResolver, NoContext> {
            Directive("model", on: .object) {
                DirectiveArgument("table", at: String.self)
            }
            Directive("tag", on: .fieldDefinition, .object, repeatable: true) {
                DirectiveArgument("name", at: String.self)
            }
            Type(User.self) {
                Field("email", at: \.email)
            }
            Query {
                Field("user", at: DeclarationResolver.user)
            }
        }
    }

    @Test func declaredDirectivesAppearInSchema() throws {
        let names = try schema().schema.directives.map { $0.name }
        #expect(names.contains("model"))
        #expect(names.contains("tag"))
    }

    @Test func specifiedDirectivesArePreserved() throws {
        let names = try schema().schema.directives.map { $0.name }
        #expect(names.contains("skip"))
        #expect(names.contains("include"))
        #expect(names.contains("deprecated"))
        #expect(names.contains("specifiedBy"))
    }

    @Test func declaredDirectiveCarriesLocationsAndRepeatability() throws {
        let directives = try schema().schema.directives
        let tag = try #require(directives.first { $0.name == "tag" })
        #expect(tag.isRepeatable)
        #expect(tag.locations.contains(.fieldDefinition))
        #expect(tag.locations.contains(.object))

        let model = try #require(directives.first { $0.name == "model" })
        #expect(!model.isRepeatable)
        #expect(model.locations == [.object])
    }

    @Test func declaredDirectiveCarriesArguments() throws {
        let directives = try schema().schema.directives
        let model = try #require(directives.first { $0.name == "model" })
        #expect(model.args.count == 1)
        #expect(model.args[0].name == "table")
        #expect(model.args[0].type is GraphQLScalarType)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DirectiveDeclarationTests`
Expected: FAIL to compile — "cannot find 'Directive' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/Graphiti/Directive/DirectiveArgument.swift`:

```swift
import GraphQL

/// An argument in a directive declaration.
public struct DirectiveArgument {
    let name: String
    let type: Any.Type
    let description: String?
    let defaultValue: Map?

    public init<ArgumentType>(
        _ name: String,
        at type: ArgumentType.Type,
        description: String? = nil,
        defaultValue: Map? = nil
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.defaultValue = defaultValue
    }
}

@resultBuilder
public struct DirectiveArgumentBuilder {
    public static func buildBlock(_ components: DirectiveArgument...) -> [DirectiveArgument] {
        components
    }

    public static func buildArray(_ components: [[DirectiveArgument]]) -> [DirectiveArgument] {
        components.flatMap { $0 }
    }
}
```

Create `Sources/Graphiti/Directive/Directive.swift`:

```swift
import GraphQL

/// Declares a custom directive definition.
///
/// The definition is rendered into SDL and is what applied directives are
/// validated against. Apply it with `.directive(_:_:)` on any component.
public final class Directive<Resolver: Sendable, Context: Sendable>: Component<Resolver, Context> {
    let locations: [DirectiveLocation]
    let isRepeatable: Bool
    let arguments: [DirectiveArgument]

    public init(
        _ name: String,
        on locations: DirectiveLocation...,
        repeatable: Bool = false,
        @DirectiveArgumentBuilder _ arguments: () -> [DirectiveArgument] = { [] }
    ) {
        self.locations = locations
        isRepeatable = repeatable
        self.arguments = arguments()
        super.init(name: name, type: .directive)
    }

    override func update(typeProvider: SchemaTypeProvider, coders _: Coders) throws {
        var args: GraphQLArgumentConfigMap = [:]
        for argument in arguments {
            let inputType = try typeProvider.getInputType(
                from: argument.type,
                field: argument.name
            )
            args[argument.name] = GraphQLArgument(
                type: inputType,
                description: argument.description,
                defaultValue: argument.defaultValue
            )
        }

        typeProvider.directives.append(
            try GraphQLDirective(
                name: name,
                description: description,
                locations: locations,
                args: args,
                isRepeatable: isRepeatable
            )
        )
    }
}
```

Add the case to `ComponentType` in `Sources/Graphiti/Component/Component.swift`:

```swift
    case directive
```

In `Sources/Graphiti/Schema/Schema.swift:33`, merge with the spec directives so
they are not dropped:

```swift
            directives: specifiedDirectives + typeProvider.directives,
```

`getInputType(from:field:)` is defined at
`Sources/Graphiti/Definition/TypeProvider.swift:105`; it throws rather than
returning an optional, and it wraps non-optional Swift types in
`GraphQLNonNull`. So `DirectiveArgument("table", at: String.self)` declares a
required `String!` argument, and `String?.self` declares a nullable one.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DirectiveDeclarationTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the existing directive suite**

Run: `swift test --filter DirectiveTests`
Expected: PASS — in particular `skip()` and `include()`, which prove the
`specifiedDirectives` merge works.

- [ ] **Step 6: Commit**

```bash
git add Sources/Graphiti/Directive Sources/Graphiti/Component/Component.swift Sources/Graphiti/Schema/Schema.swift Tests/GraphitiTests/DirectiveTests/DirectiveDeclarationTests.swift
git commit -m "feat: add Directive declaration component"
```

---

### Task 9: Register applied directives into the side table

Components carry their applied directives; the schema needs them keyed by path. Registration happens during the existing `update(typeProvider:coders:)` pass.

**Files:**
- Modify: `Sources/Graphiti/Schema/SchemaTypeProvider.swift`, `Sources/Graphiti/Type/Type.swift`, `Sources/Graphiti/Enum/Enum.swift`, `Sources/Graphiti/Input/Input.swift`, `Sources/Graphiti/Interface/Interface.swift`, `Sources/Graphiti/Union/Union.swift`, `Sources/Graphiti/Scalar/Scalar.swift`
- Test: `Tests/GraphitiTests/DirectiveTests/DirectiveSideTableTests.swift` (create)

**Interfaces:**
- Consumes: `DirectiveTarget`, `AppliedDirectiveMap` from the fork; `appliedDirectives` from Task 7.
- Produces: `var appliedDirectiveMap: AppliedDirectiveMap` on `SchemaTypeProvider`, plus `func register(_ directives: [AppliedDirective], at target: DirectiveTarget)`.

- [ ] **Step 1: Write the failing test**

Create `Tests/GraphitiTests/DirectiveTests/DirectiveSideTableTests.swift`:

```swift
@testable import Graphiti
import GraphQL
import Testing

private struct User: Codable, Sendable {
    let email: String
}

private struct SideTableResolver: Sendable {
    func user(context: NoContext, arguments: NoArguments) -> User {
        User(email: "a@b.c")
    }
}

@Suite struct DirectiveSideTableTests {
    private func provider() throws -> SchemaTypeProvider {
        let provider = SchemaTypeProvider()
        let coders = Coders()
        let components: [Component<SideTableResolver, NoContext>] = [
            Directive("model", on: .object) {
                DirectiveArgument("table", at: String.self)
            },
            Directive("unique", on: .fieldDefinition),
            Type(User.self) {
                Field("email", at: \.email).directive("unique")
            }
            .directive("model", ("table", "users")),
            Query {
                Field("user", at: SideTableResolver.user)
            },
        ]
        for component in components {
            try component.update(typeProvider: provider, coders: coders)
        }
        return provider
    }

    @Test func typeLevelDirectiveIsRegistered() throws {
        let map = try provider().appliedDirectiveMap
        let applied = try #require(map[.type("User")])
        #expect(applied.count == 1)
        #expect(applied[0].name == "model")
    }

    @Test func fieldLevelDirectiveIsRegistered() throws {
        let map = try provider().appliedDirectiveMap
        let applied = try #require(map[.member(type: "User", member: "email")])
        #expect(applied.count == 1)
        #expect(applied[0].name == "unique")
    }

    @Test func unannotatedLocationsAreAbsent() throws {
        let map = try provider().appliedDirectiveMap
        #expect(map[.type("Query")] == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DirectiveSideTableTests`
Expected: FAIL to compile — "value of type 'SchemaTypeProvider' has no member 'appliedDirectiveMap'".

- [ ] **Step 3: Write minimal implementation**

In `Sources/Graphiti/Schema/SchemaTypeProvider.swift`, add to the class body:

```swift
    var appliedDirectiveMap: AppliedDirectiveMap = [:]

    func register(_ directives: [AppliedDirective], at target: DirectiveTarget) {
        guard !directives.isEmpty else {
            return
        }
        appliedDirectiveMap[target, default: []].append(contentsOf: directives)
    }
```

In `Sources/Graphiti/Type/Type.swift`, inside `update(typeProvider:coders:)`,
after the `try typeProvider.add(type:as:)` call, register the type's own
directives and its fields':

```swift
        typeProvider.register(appliedDirectives, at: .type(name))
        for field in fields {
            typeProvider.register(
                field.appliedDirectives,
                at: .member(type: name, member: field.name)
            )
        }
```

`FieldComponent` does not currently expose its name. Add to
`Sources/Graphiti/Field/Field/FieldComponent.swift`:

```swift
    var name: String {
        fatalError()
    }
```

and override it in `Field` (`Sources/Graphiti/Field/Field/Field.swift`) to return
the stored field name, matching how `ArgumentComponent.getName()` is structured.

Apply the equivalent registration in the `update` method of `Enum`
(registering `.member(type:member:)` per `Value`), `Input` (per
`InputFieldComponent`), `Interface` (per field), `Union` and `Scalar` (type-level
only).

For field arguments, register inside `Field`'s argument handling using
`.argument(type:field:argument:)`, taking the argument name from
`ArgumentComponent.getName()`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DirectiveSideTableTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Graphiti Tests/GraphitiTests/DirectiveTests/DirectiveSideTableTests.swift
git commit -m "feat: register applied directives into schema side table"
```

---

### Task 10: Validate applied directives at schema-build time

A directive may be applied by a `Type` the builder visits before the `Directive` that declares it, so validation runs as a second pass after all components are processed.

**Files:**
- Create: `Sources/Graphiti/Directive/DirectiveValidation.swift`
- Modify: `Sources/Graphiti/Schema/Schema.swift`
- Test: `Tests/GraphitiTests/DirectiveTests/DirectiveValidationTests.swift` (create)

**Interfaces:**
- Consumes: `appliedDirectiveMap` and `directives` from `SchemaTypeProvider`.
- Produces: `func validateAppliedDirectives(_ map: AppliedDirectiveMap, against definitions: [GraphQLDirective]) throws` — throws `SchemaError`.

- [ ] **Step 1: Write the failing test**

Create `Tests/GraphitiTests/DirectiveTests/DirectiveValidationTests.swift`:

```swift
@testable import Graphiti
import GraphQL
import Testing

private struct User: Codable, Sendable {
    let email: String
}

private struct ValidationResolver: Sendable {
    func user(context: NoContext, arguments: NoArguments) -> User {
        User(email: "a@b.c")
    }
}

@Suite struct DirectiveValidationTests {
    private func build(
        @ComponentBuilder<ValidationResolver, NoContext> _ components: ()
            -> [Component<ValidationResolver, NoContext>]
    ) throws -> Schema<ValidationResolver, NoContext> {
        try Schema<ValidationResolver, NoContext>(components: components())
    }

    @Test func rejectsUndeclaredDirective() throws {
        #expect(throws: SchemaError.self) {
            try build {
                Type(User.self) {
                    Field("email", at: \.email)
                }
                .directive("nope")
                Query {
                    Field("user", at: ValidationResolver.user)
                }
            }
        }
    }

    @Test func rejectsDirectiveAtIllegalLocation() throws {
        #expect(throws: SchemaError.self) {
            try build {
                Directive("auth", on: .fieldDefinition)
                Type(User.self) {
                    Field("email", at: \.email)
                }
                .directive("auth")
                Query {
                    Field("user", at: ValidationResolver.user)
                }
            }
        }
    }

    @Test func rejectsUnknownArgumentName() throws {
        #expect(throws: SchemaError.self) {
            try build {
                Directive("model", on: .object) {
                    DirectiveArgument("table", at: String.self)
                }
                Type(User.self) {
                    Field("email", at: \.email)
                }
                .directive("model", ("tabel", "users"))
                Query {
                    Field("user", at: ValidationResolver.user)
                }
            }
        }
    }

    @Test func rejectsMissingRequiredArgument() throws {
        // String.self maps to String! (non-null, no default), so omitting it must throw.
        #expect(throws: SchemaError.self) {
            try build {
                Directive("model", on: .object) {
                    DirectiveArgument("table", at: String.self)
                }
                Type(User.self) {
                    Field("email", at: \.email)
                }
                .directive("model")
                Query {
                    Field("user", at: ValidationResolver.user)
                }
            }
        }
    }

    @Test func rejectsUncoercibleArgumentValue() throws {
        #expect(throws: SchemaError.self) {
            try build {
                Directive("count", on: .object) {
                    DirectiveArgument("n", at: Int.self)
                }
                Type(User.self) {
                    Field("email", at: \.email)
                }
                .directive("count", ("n", "not a number"))
                Query {
                    Field("user", at: ValidationResolver.user)
                }
            }
        }
    }

    @Test func rejectsRepeatedNonRepeatableDirective() throws {
        #expect(throws: SchemaError.self) {
            try build {
                Directive("model", on: .object)
                Type(User.self) {
                    Field("email", at: \.email)
                }
                .directive("model")
                .directive("model")
                Query {
                    Field("user", at: ValidationResolver.user)
                }
            }
        }
    }

    @Test func acceptsRepeatedRepeatableDirective() throws {
        let schema = try build {
            Directive("tag", on: .object, repeatable: true) {
                DirectiveArgument("name", at: String.self)
            }
            Type(User.self) {
                Field("email", at: \.email)
            }
            .directive("tag", ("name", "a"))
            .directive("tag", ("name", "b"))
            Query {
                Field("user", at: ValidationResolver.user)
            }
        }
        #expect(schema.sdl().contains("@tag(name: \"a\") @tag(name: \"b\")"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DirectiveValidationTests`
Expected: FAIL — no errors are thrown; `#expect(throws:)` assertions fail.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/Graphiti/Directive/DirectiveValidation.swift`:

```swift
import GraphQL

/// Maps a directive target to the spec location a directive must permit.
private func location(for target: DirectiveTarget, isEnumValue: Bool) -> [DirectiveLocation] {
    switch target {
    case .schema:
        return [.schema]
    case .type:
        return [.object, .interface, .union, .enum, .inputObject, .scalar]
    case .member:
        return isEnumValue
            ? [.enumValue]
            : [.fieldDefinition, .inputFieldDefinition, .enumValue]
    case .argument:
        return [.argumentDefinition]
    }
}

func validateAppliedDirectives(
    _ map: AppliedDirectiveMap,
    against definitions: [GraphQLDirective]
) throws {
    for (target, applied) in map {
        var seen: Set<String> = []

        for directive in applied {
            guard let definition = definitions.first(where: { $0.name == directive.name }) else {
                throw SchemaError(
                    description: "Directive @\(directive.name) is applied but never declared."
                )
            }

            let permitted = location(for: target, isEnumValue: false)
            guard definition.locations.contains(where: { permitted.contains($0) }) else {
                throw SchemaError(
                    description: "Directive @\(directive.name) is not permitted at \(target)."
                )
            }

            if !definition.isRepeatable, seen.contains(directive.name) {
                throw SchemaError(
                    description: "Directive @\(directive.name) is not repeatable but is applied more than once at \(target)."
                )
            }
            seen.insert(directive.name)

            for (argName, _) in directive.arguments {
                guard definition.args.contains(where: { $0.name == argName }) else {
                    throw SchemaError(
                        description: "Directive @\(directive.name) has no argument named \(argName)."
                    )
                }
            }

            for argDefinition in definition.args {
                let isRequired = argDefinition.type is GraphQLNonNull
                    && argDefinition.defaultValue == nil
                let isProvided = directive.arguments.contains { $0.0 == argDefinition.name }
                if isRequired, !isProvided {
                    throw SchemaError(
                        description: "Directive @\(directive.name) is missing required argument \(argDefinition.name)."
                    )
                }
            }

            // Value coercion can only be checked inside the GraphQL module,
            // where astFromValue lives; coercionErrors is the public helper
            // added for this in Task 2.
            if let error = coercionErrors(for: directive, against: definition).first {
                throw SchemaError(description: error)
            }
        }
    }
}
```

In `Sources/Graphiti/Schema/Schema.swift`, call it after the component loop and
before `GraphQLSchema` is constructed:

```swift
        try validateAppliedDirectives(
            typeProvider.appliedDirectiveMap,
            against: specifiedDirectives + typeProvider.directives
        )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DirectiveValidationTests`
Expected: PASS (7 tests). `acceptsRepeatedRepeatableDirective` depends on
`sdl()` from Task 11 — if executing strictly in order, expect that one test to
fail to compile until Task 11 lands, and move it to Task 11's test file.

- [ ] **Step 5: Commit**

```bash
git add Sources/Graphiti/Directive/DirectiveValidation.swift Sources/Graphiti/Schema/Schema.swift Tests/GraphitiTests/DirectiveTests/DirectiveValidationTests.swift
git commit -m "feat: validate applied directives at schema build time"
```

---

### Task 11: `Schema.sdl()` and documentation

The public entry point, plus the end-to-end tests and the docs note that raw `printSchema` does not see applied directives.

**Files:**
- Modify: `Sources/Graphiti/Schema/Schema.swift`, `UsageGuide.md`
- Test: `Tests/GraphitiTests/DirectiveTests/SDLRenderingTests.swift` (create)

**Interfaces:**
- Consumes: everything from Tasks 7-10.
- Produces: `public func sdl() -> String` on `Schema`.

- [ ] **Step 1: Write the failing test**

Create `Tests/GraphitiTests/DirectiveTests/SDLRenderingTests.swift`:

```swift
@testable import Graphiti
import GraphQL
import Testing

private struct User: Codable, Sendable {
    let email: String
    let role: Role
}

private enum Role: String, Codable, Sendable, CaseIterable {
    case admin = "ADMIN"
    case member = "MEMBER"
}

private struct SDLResolver: Sendable {
    func user(context: NoContext, arguments: NoArguments) -> User {
        User(email: "a@b.c", role: .admin)
    }
}

@Suite struct SDLRenderingTests {
    private func schema() throws -> Schema<SDLResolver, NoContext> {
        try Schema<SDLResolver, NoContext> {
            Enum(Role.self) {
                Value(Role.admin)
                Value(Role.member)
            }
            Directive("model", on: .object) {
                DirectiveArgument("table", at: String.self)
            }
            Directive("auth", on: .fieldDefinition) {
                DirectiveArgument("role", at: Role.self)
            }
            Directive("tag", on: .fieldDefinition, repeatable: true) {
                DirectiveArgument("name", at: String.self)
            }
            Type(User.self) {
                Field("email", at: \.email)
                    .directive("auth", ("role", "ADMIN"))
                    .directive("tag", ("name", "pii"))
                Field("role", at: \.role)
            }
            .directive("model", ("table", "users"))
            Query {
                Field("user", at: SDLResolver.user)
            }
        }
    }

    @Test func rendersDirectiveDefinitions() throws {
        let sdl = try schema().sdl()
        #expect(sdl.contains("directive @model(table: String!) on OBJECT"))
        #expect(sdl.contains("directive @tag(name: String!) repeatable on FIELD_DEFINITION"))
    }

    @Test func rendersTypeAndFieldApplications() throws {
        let sdl = try schema().sdl()
        #expect(sdl.contains("type User @model(table: \"users\") {"))
        #expect(sdl.contains("email: String! @auth(role: ADMIN) @tag(name: \"pii\")"))
    }

    @Test func rendersEnumArgumentUnquotedAndStringQuoted() throws {
        let sdl = try schema().sdl()
        #expect(sdl.contains("@auth(role: ADMIN)"))
        #expect(!sdl.contains("@auth(role: \"ADMIN\")"))
        #expect(sdl.contains("@tag(name: \"pii\")"))
    }

    @Test func emittedSDLParses() throws {
        let sdl = try schema().sdl()
        _ = try parse(source: Source(body: sdl))
    }

    @Test func outputIsDeterministic() throws {
        #expect(try schema().sdl() == schema().sdl())
    }

    @Test func rawPrintSchemaDoesNotSeeApplications() throws {
        let schema = try schema()
        #expect(!printSchema(schema: schema.schema).contains("@model"))
        #expect(schema.sdl().contains("@model"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SDLRenderingTests`
Expected: FAIL to compile — "value of type 'Schema<...>' has no member 'sdl'".

- [ ] **Step 3: Write minimal implementation**

In `Sources/Graphiti/Schema/Schema.swift`, store the map on the class. Add the
stored property next to `public let schema: GraphQLSchema`:

```swift
    let appliedDirectives: AppliedDirectiveMap
```

assign it in `init` before `self.schema = schema`:

```swift
        appliedDirectives = typeProvider.appliedDirectiveMap
```

and add the entry point:

```swift
public extension Schema {
    /// The schema rendered as SDL, including any custom directives declared and
    /// applied through the DSL.
    ///
    /// Note that calling `printSchema(schema:)` on the underlying
    /// `GraphQLSchema` directly will *not* include applied directives — they are
    /// held alongside the schema rather than on its type objects.
    func sdl() -> String {
        printSchema(schema: schema, appliedDirectives: appliedDirectives)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SDLRenderingTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Document it**

Add a section to `UsageGuide.md` covering: declaring a directive with
`Directive(_:on:repeatable:)`, applying it with `.directive(_:_:)`, calling
`schema.sdl()`, and an explicit warning that `printSchema(schema.schema)` omits
applied directives. Include the worked example from the test above.

- [ ] **Step 6: Run the full Graphiti suite**

Run: `swift test`
Expected: PASS — all suites, including the pre-existing `DirectiveTests.skip()`
and `.include()`.

- [ ] **Step 7: Commit**

```bash
git add Sources/Graphiti/Schema/Schema.swift UsageGuide.md Tests/GraphitiTests/DirectiveTests/SDLRenderingTests.swift
git commit -m "feat: render declared and applied directives in schema SDL"
```

---

## Done

At this point: directives can be declared and applied at every spec location, `schema.sdl()` renders both, spec directives survive, and invalid applications fail at build time.

Deliberately not done, per the spec: generating `federatedSDL:` from the existing `Key` model; SDL-to-schema round trip; introspection parity; execution semantics.
