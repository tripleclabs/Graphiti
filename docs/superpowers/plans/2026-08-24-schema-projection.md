# Directive Queries and Schema Projection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let callers query a schema by applied directive and project it down to the root fields matching a predicate, producing a smaller schema that still executes.

**Architecture:** Projection lives in the GraphQL fork because it needs `GraphQLFieldDefinition.toField()` and `GraphQLObjectType.getFields()`, both internal. Graphiti exposes its directive map, supplies a predicate closing over it, and wraps the reduced `GraphQLSchema`. Same split as directive printing: mechanics in the GraphQL layer, DSL knowledge in Graphiti.

**Tech Stack:** Swift 6.2 (Graphiti) / Swift 5.8 tools (fork), SwiftPM, swift-testing (`@Test` / `#expect`), `tripleclabs/GraphQL`.

**Spec:** `docs/superpowers/specs/2026-08-24-schema-projection-design.md`

## Global Constraints

- Works for **any** directive. No `theme` vocabulary in either repository.
- Projections must **execute**, not merely print — resolvers and subscription sources survive.
- Types are included by **automatic transitive closure** from retained root fields. Only root fields are tagged.
- Root fields with no matching directive are **excluded from every view**. The source schema is unchanged.
- Projections are built **on demand and held by the caller**. No caching, no memoisation, no locking. `Schema` stays `Sendable`.
- Query, mutation and subscription roots are all supported. A view with no query fields is an error; one with no mutations simply omits the mutation root.
- No AST node initializer or `astFromValue` may be made public.
- Graphiti test style is swift-testing: `@Test func name() throws`, `#expect(...)`. Fork adds `@Suite struct`.
- Commit after every task.

## Repository Setup

The fork is at `~/src/graphql-swift` on `main` (already pushed, at the revision `Package.swift:12` pins). Work directly there:

```bash
cd ~/src/graphql-swift
git checkout main && git pull
git checkout -b feat/schema-projection
```

Tasks 1-3 run `swift test` in `~/src/graphql-swift`. Tasks 5-7 run `swift test` in `~/src/graphiti`.

---

## Phase A — GraphQL fork

### Task 1: Argument access on `AppliedDirective`

`AppliedDirective.arguments` is `[(String, Map)]`, and `Map` exposes only `stringValue` and `intValue` publicly, so predicates would otherwise pattern-match `Map` cases by hand.

**Files:**
- Modify: `Sources/GraphQL/Utilities/AppliedDirectives.swift`
- Test: `Tests/GraphQLTests/UtilitiesTests/AppliedDirectivesTests.swift`

**Interfaces:**
- Consumes: `AppliedDirective` (existing).
- Produces:
  - `public subscript(_ argument: String) -> Map?` on `AppliedDirective`
  - `public func argument(_ name: String, contains value: Map) -> Bool` on `AppliedDirective`

- [ ] **Step 1: Write the failing test**

Append to `Tests/GraphQLTests/UtilitiesTests/AppliedDirectivesTests.swift`:

```swift
@Suite struct AppliedDirectiveArgumentAccessTests {
    private let themed = AppliedDirective(
        name: "theme",
        arguments: [("names", ["billing", "admin"]), ("owner", "payments")]
    )

    @Test func subscriptReturnsArgumentValue() throws {
        #expect(themed["owner"] == Map.string("payments"))
    }

    @Test func subscriptReturnsNilForAbsentArgument() throws {
        #expect(themed["nope"] == nil)
    }

    @Test func containsFindsListMembership() throws {
        #expect(themed.argument("names", contains: "billing"))
        #expect(themed.argument("names", contains: "admin"))
    }

    @Test func containsRejectsAbsentMember() throws {
        #expect(!themed.argument("names", contains: "search"))
    }

    @Test func containsIsFalseForAbsentArgument() throws {
        #expect(!themed.argument("nope", contains: "billing"))
    }

    @Test func containsIsFalseForNonListArgument() throws {
        // "owner" is a scalar; contains is list membership only.
        #expect(!themed.argument("owner", contains: "payments"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AppliedDirectiveArgumentAccessTests`
Expected: FAIL to compile — "value of type 'AppliedDirective' has no subscripts".

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/GraphQL/Utilities/AppliedDirectives.swift`:

```swift
public extension AppliedDirective {
    /// The value of a named argument, if the directive was applied with one.
    subscript(_ argument: String) -> Map? {
        arguments.first { $0.0 == argument }?.1
    }

    /// True when the named argument is a list containing `value`.
    ///
    /// Returns false when the argument is absent or is not a list — this is
    /// list membership, not equality.
    func argument(_ name: String, contains value: Map) -> Bool {
        guard case let .array(values)? = self[name] else {
            return false
        }
        return values.contains(value)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AppliedDirectiveArgumentAccessTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/GraphQL/Utilities/AppliedDirectives.swift Tests/GraphQLTests/UtilitiesTests/AppliedDirectivesTests.swift
git commit -m "feat: add argument access to AppliedDirective"
```

---

### Task 2: `GraphQLSchema.projected(rootFieldsWhere:)`

Root field filtering plus automatic type closure. Interface completeness lands in Task 3 — this task deliberately ships without it, and Task 3's test proves why it is needed.

**Files:**
- Create: `Sources/GraphQL/Utilities/SchemaProjection.swift`
- Test: `Tests/GraphQLTests/UtilitiesTests/SchemaProjectionTests.swift` (create)

**Interfaces:**
- Consumes: `GraphQLFieldDefinition.toField()` (internal, `Type/Definition.swift:629`), `GraphQLObjectType.getFields()` (internal), `GraphQLSchema.typeMap` (public), `GraphQLSchema.directives` (public).
- Produces:
  - `public func projected(rootFieldsWhere keep: (String, String) -> Bool) throws -> GraphQLSchema` on `GraphQLSchema` — `keep` receives (root type name, field name)
  - `public func contains(_ target: DirectiveTarget) -> Bool` on `GraphQLSchema`

- [ ] **Step 1: Write the failing test**

Create `Tests/GraphQLTests/UtilitiesTests/SchemaProjectionTests.swift`:

```swift
@testable import GraphQL
import Testing

private func sampleSchema() throws -> GraphQLSchema {
    let billingAccount = try GraphQLObjectType(
        name: "BillingAccount",
        fields: ["id": GraphQLField(type: GraphQLString)]
    )
    let product = try GraphQLObjectType(
        name: "Product",
        fields: ["sku": GraphQLField(type: GraphQLString)]
    )
    let query = try GraphQLObjectType(
        name: "Query",
        fields: [
            "billing": GraphQLField(
                type: billingAccount,
                resolve: { _, _, _, _ in ["id": "acct-1"] }
            ),
            "search": GraphQLField(type: product),
        ]
    )
    let mutation = try GraphQLObjectType(
        name: "Mutation",
        fields: [
            "pay": GraphQLField(type: GraphQLString),
            "reindex": GraphQLField(type: GraphQLString),
        ]
    )
    return try GraphQLSchema(query: query, mutation: mutation)
}

@Suite struct SchemaProjectionTests {
    @Test func keepsOnlyMatchingRootFields() throws {
        let projected = try sampleSchema().projected { _, field in field == "billing" }
        let queryFields = try #require(projected.queryType).getFields()
        #expect(try queryFields.keys.sorted() == ["billing"])
    }

    @Test func includesTypesReachableFromKeptFields() throws {
        let projected = try sampleSchema().projected { _, field in field == "billing" }
        #expect(projected.typeMap["BillingAccount"] != nil)
    }

    @Test func excludesTypesReachableOnlyFromDroppedFields() throws {
        let projected = try sampleSchema().projected { _, field in field == "billing" }
        #expect(projected.typeMap["Product"] == nil)
    }

    @Test func filtersEachRootTypeIndependently() throws {
        let projected = try sampleSchema().projected { rootType, field in
            (rootType == "Query" && field == "billing") ||
                (rootType == "Mutation" && field == "pay")
        }
        let mutationFields = try #require(projected.mutationType).getFields()
        #expect(try mutationFields.keys.sorted() == ["pay"])
    }

    @Test func omitsRootTypeWithNoSurvivingFields() throws {
        let projected = try sampleSchema().projected { rootType, field in
            rootType == "Query" && field == "billing"
        }
        #expect(projected.mutationType == nil)
    }

    @Test func throwsWhenNoQueryFieldsMatch() throws {
        #expect(throws: (any Error).self) {
            try sampleSchema().projected { rootType, _ in rootType == "Mutation" }
        }
    }

    @Test func projectionStillExecutes() async throws {
        let projected = try sampleSchema().projected { _, field in field == "billing" }
        let result = try await graphql(schema: projected, request: "{ billing { id } }")
        #expect(result.data?["billing"]["id"].string == "acct-1")
        #expect(result.errors.isEmpty)
    }

    @Test func projectionPreservesSubscriptionSources() throws {
        // toField() carries `subscribe` as well as `resolve`; without it a
        // projected subscription root would print but never fire.
        let subscription = try GraphQLObjectType(
            name: "Subscription",
            fields: [
                "ticks": GraphQLField(
                    type: GraphQLString,
                    resolve: { source, _, _, _ in source },
                    subscribe: { _, _, _, _ in AsyncStream<String> { $0.finish() } }
                ),
                "noise": GraphQLField(type: GraphQLString),
            ]
        )
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["billing": GraphQLField(type: GraphQLString)]
        )
        let schema = try GraphQLSchema(query: query, subscription: subscription)

        let projected = try schema.projected { rootType, field in
            rootType == "Query" || field == "ticks"
        }

        let fields = try #require(projected.subscriptionType).getFields()
        #expect(try fields.keys.sorted() == ["ticks"])
        #expect(try #require(fields["ticks"]).subscribe != nil)
    }

    @Test func containsReportsSurvivingElements() throws {
        let projected = try sampleSchema().projected { _, field in field == "billing" }
        #expect(projected.contains(.type("BillingAccount")))
        #expect(!projected.contains(.type("Product")))
        #expect(projected.contains(.member(type: "Query", member: "billing")))
        #expect(!projected.contains(.member(type: "Query", member: "search")))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SchemaProjectionTests`
Expected: FAIL to compile — "value of type 'GraphQLSchema' has no member 'projected'".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/GraphQL/Utilities/SchemaProjection.swift`:

```swift
public extension GraphQLSchema {
    /// A schema containing only the root fields satisfying `keep`, plus every
    /// type reachable from them.
    ///
    /// Field definitions are rebuilt with their resolvers and subscription
    /// sources intact, so the result executes rather than merely printing.
    ///
    /// - Parameter keep: called with the root type name ("Query", "Mutation",
    ///   "Subscription") and the field name.
    /// - Throws: when no query fields match — GraphQL requires a query root —
    ///   or when the reduced schema fails validation.
    func projected(
        rootFieldsWhere keep: (String, String) -> Bool
    ) throws -> GraphQLSchema {
        let query = try reducedRoot(queryType, keep: keep)
        guard query != nil else {
            throw GraphQLError(
                message: "Projection matched no root query fields. A GraphQL schema requires a query type."
            )
        }

        let schema = try GraphQLSchema(
            query: query,
            mutation: try reducedRoot(mutationType, keep: keep),
            subscription: try reducedRoot(subscriptionType, keep: keep),
            directives: directives
        )

        let errors = try validateSchema(schema: schema)
        guard errors.isEmpty else {
            throw GraphQLErrors(errors)
        }

        return schema
    }

    /// Whether the element a directive target names still exists in this schema.
    func contains(_ target: DirectiveTarget) -> Bool {
        switch target {
        case .schema:
            return true
        case let .type(name):
            return typeMap[name] != nil
        case let .member(typeName, member):
            return containsMember(member, of: typeName)
        case let .argument(typeName, fieldName, argumentName):
            return arguments(ofField: fieldName, on: typeName)
                .contains { $0.name == argumentName }
        }
    }
}

private extension GraphQLSchema {
    func reducedRoot(
        _ root: GraphQLObjectType?,
        keep: (String, String) -> Bool
    ) throws -> GraphQLObjectType? {
        guard let root = root else {
            return nil
        }

        var fields: GraphQLFieldMap = [:]
        for (fieldName, definition) in try root.getFields() where keep(root.name, fieldName) {
            fields[fieldName] = definition.toField()
        }

        guard !fields.isEmpty else {
            return nil
        }

        return try GraphQLObjectType(
            name: root.name,
            description: root.description,
            fields: fields,
            interfaces: try root.getInterfaces(),
            isTypeOf: root.isTypeOf
        )
    }

    func containsMember(_ member: String, of typeName: String) -> Bool {
        guard let type = typeMap[typeName] else {
            return false
        }
        if let object = type as? GraphQLObjectType {
            return (try? object.getFields())?[member] != nil
        }
        if let interface = type as? GraphQLInterfaceType {
            return (try? interface.getFields())?[member] != nil
        }
        if let input = type as? GraphQLInputObjectType {
            return (try? input.getFields())?[member] != nil
        }
        if let enumType = type as? GraphQLEnumType {
            return enumType.values.contains { $0.name == member }
        }
        return false
    }

    func arguments(ofField fieldName: String, on typeName: String) -> [GraphQLArgumentDefinition] {
        if let object = typeMap[typeName] as? GraphQLObjectType {
            return (try? object.getFields())?[fieldName]?.args ?? []
        }
        if let interface = typeMap[typeName] as? GraphQLInterfaceType {
            return (try? interface.getFields())?[fieldName]?.args ?? []
        }
        return []
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SchemaProjectionTests`
Expected: PASS (9 tests).

- [ ] **Step 5: Run the full fork suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/GraphQL/Utilities/SchemaProjection.swift Tests/GraphQLTests/UtilitiesTests/SchemaProjectionTests.swift
git commit -m "feat: add schema projection by root field"
```

---

### Task 3: Interface completeness

`typeMapReducer` (`Type/Schema.swift:337`) walks unions down to their members and objects up to their interfaces, but for an interface it walks only that interface's own fields — never its implementations. A projection whose kept root field returns an interface therefore omits every concrete type, and execution fails at runtime.

**Files:**
- Modify: `Sources/GraphQL/Utilities/SchemaProjection.swift`
- Test: `Tests/GraphQLTests/UtilitiesTests/SchemaProjectionTests.swift`

**Interfaces:**
- Consumes: `GraphQLSchema.implementations` (public, `Type/Schema.swift:46`), `InterfaceImplementations.objects` / `.interfaces` (public, `Type/Schema.swift:324-326`).
- Produces: no new API — `projected(rootFieldsWhere:)` gains the completeness pass.

- [ ] **Step 1: Write the failing test**

Append to `Tests/GraphQLTests/UtilitiesTests/SchemaProjectionTests.swift`:

```swift
private func interfaceSchema() throws -> GraphQLSchema {
    let node = try GraphQLInterfaceType(
        name: "Node",
        fields: ["id": GraphQLField(type: GraphQLString)]
    )
    let account = try GraphQLObjectType(
        name: "Account",
        fields: ["id": GraphQLField(type: GraphQLString)],
        interfaces: [node],
        isTypeOf: { source, _ in
            (source as? [String: String])?["kind"] == "account"
        }
    )
    let query = try GraphQLObjectType(
        name: "Query",
        fields: [
            "node": GraphQLField(
                type: node,
                resolve: { _, _, _, _ in ["id": "n-1", "kind": "account"] }
            ),
        ]
    )
    return try GraphQLSchema(query: query, types: [account], mutation: nil)
}

@Suite struct SchemaProjectionInterfaceTests {
    @Test func includesInterfaceImplementations() throws {
        let projected = try interfaceSchema().projected { _, field in field == "node" }
        #expect(projected.typeMap["Node"] != nil)
        #expect(projected.typeMap["Account"] != nil)
    }

    @Test func projectionResolvesConcreteTypeAtRuntime() async throws {
        let projected = try interfaceSchema().projected { _, field in field == "node" }
        let result = try await graphql(
            schema: projected,
            request: "{ node { __typename id } }"
        )
        #expect(result.errors.isEmpty)
        #expect(result.data?["node"]["__typename"].string == "Account")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SchemaProjectionInterfaceTests`
Expected: FAIL — `includesInterfaceImplementations` finds `Account` missing, and the execution test errors on abstract type resolution.

- [ ] **Step 3: Write minimal implementation**

In `Sources/GraphQL/Utilities/SchemaProjection.swift`, replace the body of
`projected(rootFieldsWhere:)` between building the roots and validating:

```swift
    func projected(
        rootFieldsWhere keep: (String, String) -> Bool
    ) throws -> GraphQLSchema {
        let query = try reducedRoot(queryType, keep: keep)
        guard query != nil else {
            throw GraphQLError(
                message: "Projection matched no root query fields. A GraphQL schema requires a query type."
            )
        }
        let mutation = try reducedRoot(mutationType, keep: keep)
        let subscription = try reducedRoot(subscriptionType, keep: keep)

        // Type closure does not walk an interface down to its implementations,
        // so they must be added back explicitly. Each addition can pull in
        // further types, which may retain further interfaces, so this repeats
        // until it stops growing.
        var extraTypes: [GraphQLNamedType] = []
        var schema = try GraphQLSchema(
            query: query,
            mutation: mutation,
            subscription: subscription,
            types: extraTypes,
            directives: directives
        )

        while true {
            var additions: [GraphQLNamedType] = []
            for type in schema.typeMap.values {
                guard
                    let interface = type as? GraphQLInterfaceType,
                    let impls = implementations[interface.name]
                else {
                    continue
                }
                for object in impls.objects where schema.typeMap[object.name] == nil {
                    additions.append(object)
                }
                for sub in impls.interfaces where schema.typeMap[sub.name] == nil {
                    additions.append(sub)
                }
            }

            guard !additions.isEmpty else {
                break
            }

            extraTypes.append(contentsOf: additions)
            schema = try GraphQLSchema(
                query: query,
                mutation: mutation,
                subscription: subscription,
                types: extraTypes,
                directives: directives
            )
        }

        let errors = try validateSchema(schema: schema)
        guard errors.isEmpty else {
            throw GraphQLErrors(errors)
        }

        return schema
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SchemaProjectionInterfaceTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the full fork suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 6: Commit and push**

```bash
git add Sources/GraphQL/Utilities/SchemaProjection.swift Tests/GraphQLTests/UtilitiesTests/SchemaProjectionTests.swift
git commit -m "feat: include interface implementations in projections"
git push -u origin feat/schema-projection
```

**Stop here and confirm with the user before merging to the fork's `main`.**

---

## Phase B — Dependency pin

### Task 4: Bump the Graphiti pin

**Files:**
- Modify: `Package.swift:12` (in `~/src/graphiti`)

**Interfaces:**
- Consumes: the merged fork commit from Task 3.
- Produces: a Graphiti checkout that builds against `projected(rootFieldsWhere:)` and `contains(_:)`.

- [ ] **Step 1: Get the merged fork SHA**

```bash
cd ~/src/graphql-swift && git rev-parse HEAD
```

- [ ] **Step 2: Update the pin**

In `~/src/graphiti/Package.swift:12`, replace the revision with that SHA:

```swift
.package(url: "https://github.com/tripleclabs/GraphQL.git", revision: "<SHA FROM STEP 1>"),
```

- [ ] **Step 3: Resolve and build**

```bash
cd ~/src/graphiti
swift package resolve
swift build
```

Expected: builds cleanly; Graphiti does not use the new API yet.

- [ ] **Step 4: Run the Graphiti suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Package.swift
git commit -m "build: bump GraphQL pin for schema projection"
```

---

## Phase C — Graphiti

### Task 5: Expose the directive map and add the wrapping initializer

**Files:**
- Modify: `Sources/Graphiti/Schema/Schema.swift`
- Test: `Tests/GraphitiTests/DirectiveTests/DirectiveQueryTests.swift` (create)

**Interfaces:**
- Consumes: `AppliedDirective.argument(_:contains:)` from Task 1.
- Produces:
  - `public let appliedDirectives: AppliedDirectiveMap` on `Schema`
  - `init(schema: GraphQLSchema, appliedDirectives: AppliedDirectiveMap)` — internal, used by Task 6

- [ ] **Step 1: Write the failing test**

Create `Tests/GraphitiTests/DirectiveTests/DirectiveQueryTests.swift`. Note this
file uses a plain `import Graphiti`, **not** `@testable` — the point is proving
the map is visible to external callers.

```swift
import Graphiti
import GraphQL
import Testing

private struct QueryUser: Codable, Sendable {
    let email: String
}

private struct QueryResolver: Sendable {
    func billing(context _: NoContext, arguments _: NoArguments) -> QueryUser {
        QueryUser(email: "a@b.c")
    }

    func search(context _: NoContext, arguments _: NoArguments) -> QueryUser {
        QueryUser(email: "a@b.c")
    }

    func untagged(context _: NoContext, arguments _: NoArguments) -> QueryUser {
        QueryUser(email: "a@b.c")
    }
}

@Suite struct DirectiveQueryTests {
    private func schema() throws -> Schema<QueryResolver, NoContext> {
        try Schema<QueryResolver, NoContext> {
            Directive("theme", on: .fieldDefinition) {
                DirectiveArgument("names", at: [String].self)
            }
            Type(QueryUser.self) { Field("email", at: \.email) }
            Query {
                Field("billing", at: QueryResolver.billing)
                    .directive("theme", ("names", ["billing", "admin"]))
                Field("search", at: QueryResolver.search)
                    .directive("theme", ("names", ["search"]))
                Field("untagged", at: QueryResolver.untagged)
            }
        }
    }

    @Test func rootFieldsAreQueryableByDirectiveValue() throws {
        let matches = try schema().appliedDirectives
            .compactMap { target, directives -> String? in
                guard
                    case let .member(type, member) = target,
                    type == "Query",
                    directives.contains(where: {
                        $0.name == "theme" && $0.argument("names", contains: "billing")
                    })
                else { return nil }
                return member
            }
            .sorted()
        #expect(matches == ["billing"])
    }

    @Test func untaggedFieldsAreAbsentFromTheMap() throws {
        let map = try schema().appliedDirectives
        #expect(map[.member(type: "Query", member: "untagged")] == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DirectiveQueryTests`
Expected: FAIL to compile — `appliedDirectives` is inaccessible due to internal protection level.

- [ ] **Step 3: Write minimal implementation**

In `Sources/Graphiti/Schema/Schema.swift`, make the stored property public and
document it:

```swift
    /// Every directive application in this schema, keyed by schema location.
    ///
    /// Filter this to answer questions like "which root fields carry this
    /// directive with this value?" — see `AppliedDirective.argument(_:contains:)`.
    public let appliedDirectives: AppliedDirectiveMap
```

Add the wrapping initializer after the existing `init`:

```swift
    /// Wraps an already-built GraphQL schema. Used by projection, which
    /// constructs its schema rather than building one from components.
    init(schema: GraphQLSchema, appliedDirectives: AppliedDirectiveMap) {
        self.schema = schema
        self.appliedDirectives = appliedDirectives
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DirectiveQueryTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Graphiti/Schema/Schema.swift Tests/GraphitiTests/DirectiveTests/DirectiveQueryTests.swift
git commit -m "feat: expose applied directives for querying"
```

---

### Task 6: `Schema.projection(rootFieldsWhere:)`

**Files:**
- Create: `Sources/Graphiti/Schema/SchemaProjection.swift`
- Test: `Tests/GraphitiTests/DirectiveTests/SchemaProjectionTests.swift` (create)

**Interfaces:**
- Consumes: `GraphQLSchema.projected(rootFieldsWhere:)` and `GraphQLSchema.contains(_:)` from Tasks 2-3; the internal `Schema.init(schema:appliedDirectives:)` from Task 5.
- Produces: `public func projection(rootFieldsWhere keep: (String, String, [AppliedDirective]) -> Bool) throws -> Schema<Resolver, Context>`

- [ ] **Step 1: Write the failing test**

Create `Tests/GraphitiTests/DirectiveTests/SchemaProjectionTests.swift`:

```swift
@testable import Graphiti
import GraphQL
import Testing

private struct ProjUser: Codable, Sendable {
    let email: String
}

private struct ProjProduct: Codable, Sendable {
    let sku: String
}

private struct ProjResolver: Sendable {
    func billing(context _: NoContext, arguments _: NoArguments) -> ProjUser {
        ProjUser(email: "a@b.c")
    }

    func search(context _: NoContext, arguments _: NoArguments) -> ProjProduct {
        ProjProduct(sku: "sku-1")
    }

    func pay(context _: NoContext, arguments _: NoArguments) -> String { "ok" }
}

@Suite struct GraphitiSchemaProjectionTests {
    private func schema() throws -> Schema<ProjResolver, NoContext> {
        try Schema<ProjResolver, NoContext> {
            Directive("theme", on: .fieldDefinition) {
                DirectiveArgument("names", at: [String].self)
            }
            Type(ProjUser.self) { Field("email", at: \.email) }
            Type(ProjProduct.self) { Field("sku", at: \.sku) }
            Query {
                Field("billing", at: ProjResolver.billing)
                    .directive("theme", ("names", ["billing"]))
                Field("search", at: ProjResolver.search)
                    .directive("theme", ("names", ["search"]))
            }
            Mutation {
                Field("pay", at: ProjResolver.pay)
                    .directive("theme", ("names", ["billing"]))
            }
        }
    }

    private func billingView() throws -> Schema<ProjResolver, NoContext> {
        try schema().projection { _, _, directives in
            directives.contains { $0.name == "theme" && $0.argument("names", contains: "billing") }
        }
    }

    @Test func keepsOnlyMatchingRootFields() throws {
        let sdl = try billingView().sdl()
        #expect(sdl.contains("billing: ProjUser!"))
        #expect(!sdl.contains("search:"))
    }

    @Test func includesReachableTypesAndExcludesOthers() throws {
        let sdl = try billingView().sdl()
        #expect(sdl.contains("type ProjUser"))
        #expect(!sdl.contains("type ProjProduct"))
    }

    @Test func projectionSpansMutationRoots() throws {
        let sdl = try billingView().sdl()
        #expect(sdl.contains("type Mutation"))
        #expect(sdl.contains("pay: String!"))
    }

    @Test func predicateCanScopeToOneOperationKind() throws {
        let queryOnly = try schema().projection { rootType, _, directives in
            rootType == "Query" &&
                directives.contains { $0.name == "theme" && $0.argument("names", contains: "billing") }
        }
        #expect(!queryOnly.sdl().contains("type Mutation"))
    }

    @Test func projectionExecutes() async throws {
        let result = try await billingView().execute(
            request: "{ billing { email } }",
            resolver: ProjResolver(),
            context: NoContext()
        )
        #expect(result.errors.isEmpty)
        #expect(result.data?["billing"]["email"].string == "a@b.c")
    }

    @Test func projectionKeepsDirectivesOnSurvivingElements() throws {
        let map = try billingView().appliedDirectives
        #expect(map[.member(type: "Query", member: "billing")]?.map(\.name) == ["theme"])
    }

    @Test func projectionDropsDirectivesOnAbsentElements() throws {
        let map = try billingView().appliedDirectives
        #expect(map[.member(type: "Query", member: "search")] == nil)
    }

    @Test func projectionRendersDirectivesInSDL() throws {
        #expect(try billingView().sdl().contains("@theme(names: [\"billing\"])"))
    }

    @Test func projectionIsDeterministic() throws {
        #expect(try billingView().sdl() == billingView().sdl())
    }

    @Test func mutationOnlyThemeThrows() throws {
        // GraphQL requires a query root, so a view of only mutations cannot
        // stand alone — every theme needs at least one query field.
        #expect(throws: SchemaError.self) {
            try schema().projection { rootType, _, _ in rootType == "Mutation" }
        }
    }

    @Test func throwsWhenNoFieldsMatchAtAll() throws {
        #expect(throws: SchemaError.self) {
            try schema().projection { _, _, directives in
                directives.contains { $0.name == "theme" && $0.argument("names", contains: "nothing") }
            }
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GraphitiSchemaProjectionTests`
Expected: FAIL to compile — "value of type 'Schema<...>' has no member 'projection'".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/Graphiti/Schema/SchemaProjection.swift`:

```swift
import GraphQL

public extension Schema {
    /// A schema containing only the root fields satisfying `keep`, plus every
    /// type reachable from them.
    ///
    /// The result executes as well as prints — resolvers and subscription
    /// sources are preserved — and carries a directive map reduced to the
    /// elements it actually contains.
    ///
    /// Nothing is cached: each call builds a new schema, and the caller decides
    /// how long to hold it.
    ///
    /// - Parameter keep: called with the root type name ("Query", "Mutation",
    ///   "Subscription"), the field name, and the directives applied to it.
    /// - Throws: `SchemaError` when no root query fields match, since GraphQL
    ///   requires a query type.
    func projection(
        rootFieldsWhere keep: (String, String, [AppliedDirective]) -> Bool
    ) throws -> Schema<Resolver, Context> {
        let map = appliedDirectives

        let projected: GraphQLSchema
        do {
            projected = try schema.projected { rootType, field in
                keep(rootType, field, map[.member(type: rootType, member: field)] ?? [])
            }
        } catch let error as GraphQLError {
            throw SchemaError(description: error.message)
        }

        return Schema(
            schema: projected,
            appliedDirectives: map.filter { projected.contains($0.key) }
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GraphitiSchemaProjectionTests`
Expected: PASS (11 tests).

- [ ] **Step 5: Run the full Graphiti suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/Graphiti/Schema/SchemaProjection.swift Tests/GraphitiTests/DirectiveTests/SchemaProjectionTests.swift
git commit -m "feat: add schema projection by root field directives"
```

---

### Task 7: Document it

**Files:**
- Modify: `UsageGuide.md` (the `## Directives` section added by the previous plan)

**Interfaces:**
- Consumes: everything from Tasks 5-6.
- Produces: no code.

- [ ] **Step 1: Add a subsection to `UsageGuide.md`**

Immediately after the existing `## Directives` section and before `## Federation`, add:

````markdown
### Querying and projecting by directive

`schema.appliedDirectives` exposes every directive application, keyed by
location, so a schema can be queried in plain Swift:

```swift
let billingFields = schema.appliedDirectives.compactMap { target, directives -> String? in
    guard
        case let .member(type, member) = target, type == "Query",
        directives.contains(where: {
            $0.name == "theme" && $0.argument("names", contains: "billing")
        })
    else { return nil }
    return member
}
```

`projection(rootFieldsWhere:)` turns such a predicate into a smaller schema
containing only the matching root fields and the types reachable from them:

```swift
let billingView = try schema.projection { _, _, directives in
    directives.contains { $0.name == "theme" && $0.argument("names", contains: "billing") }
}

print(billingView.sdl())
```

The projection executes as well as prints, so `billingView.execute(...)` works
against the same resolvers. Nothing is cached — hold onto the result for as long
as you need it.

The predicate also receives the root type name, so a view can be scoped to one
operation kind:

```swift
try schema.projection { rootType, field, directives in
    rootType == "Query" && directives.contains { $0.name == "theme" }
}
```

Two things to know. A projection must contain at least one query field, because
GraphQL requires a query root — a predicate matching only mutations throws.
And if a kept root field *returns* an interface, every type implementing that
interface is pulled in, along with everything they reference, because otherwise
the concrete type could not be resolved at runtime. Returning concrete types
keeps views small — merely implementing an interface does not inflate a view,
only returning one does.
````

- [ ] **Step 2: Verify the documented example compiles**

The `UsageGuide.md` snippets mirror `Tests/GraphitiTests/DirectiveTests/SchemaProjectionTests.swift`. Confirm that suite still passes:

Run: `swift test --filter GraphitiSchemaProjectionTests`
Expected: PASS (11 tests).

- [ ] **Step 3: Run the full Graphiti suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add UsageGuide.md
git commit -m "docs: document directive queries and schema projection"
```

---

## Done

Callers can query a schema by any applied directive and project it to a smaller schema that still executes, across query, mutation and subscription roots.

Deliberately not done, per the spec: caching or memoisation of projections; a `theme` vocabulary in the library; a declarative matcher type; tagging of types rather than root fields; pruning unused directive definitions from a projection.
