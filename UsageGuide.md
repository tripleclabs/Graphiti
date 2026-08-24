
# Usage Guide

The following sections build up a Graphiti schema and detail how to use some of the main features.

## Hello World

Here is an example of a basic `"Hello world"` GraphQL schema:

```swift
import Graphiti

struct HelloResolver {
    func hello(context: NoContext, arguments: NoArguments) -> String {
        return "world"
    }
}

struct HelloAPI : API {
    typealias ContextType = NoContext
    let resolver = HelloResolver()
    let schema = try! Schema<HelloResolver, NoContext> {
        Query {
            Field("hello", at: HelloResolver.hello)
        }
    }
}
```

This schema can be queried in Swift using the `execute` function. :

```swift
let result = try await HelloAPI().execute(
    request: "{ hello }",
    context: NoContext()
)
print(result)
```

The result of this query is a `GraphQLResult` that encodes to the following JSON:

```json
{ "hello": "world" }
```

## Swift Types

Graphiti includes support for using Swift types in the schema itself. To connect the Swift type with the GraphQL one, include a `Type` block in the API declaration, composed of `Field`s. For example, we can integrate a `Person` object into the API:

```swift
import Graphiti

struct Person: Codable {
    let name: String
    let age: Int
    let height: Double
}

let characters = [
    Person(name: "Johnny Utah", age: 23, height: 1.85),
    Person(name: "Bodhi", age: 27, height: 1.8),
]

struct PersonResolver {
    func people(context: NoContext, arguments: NoArguments) -> [Person] {
        return characters
    }
}

struct PointBreakAPI : API {
    typealias ContextType = NoContext
    let resolver = PersonResolver()
    let schema = try! Schema<PersonResolver, NoContext> {
        Type(Person.self) {
            Field("name", at: \.name)
            Field("age", at: \.age)
            Field("height", at: \.height)
        }
        Query {
            Field("people", at: PersonResolver.people)
        }
    }
}

let result = try await PointBreakAPI().execute(
    request: """
    {
      people {
        name
        age
      }
    }
    """,
    context: NoContext()
)
```

The `result` above could be decoded to a JSON of the form:

```json
{
  "people" : [
    {
      "name" : "Johnny Utah",
      "age" : 23
    },
    {
      "name" : "Bodhi",
      "age" : 27
    }
  ]
}
```

## Arguments

Arguments can be defined within an API using the `Argument` initializer in a `Field` builder. Adjusting our previous example, we can add in an argument to filter people by their age.

```swift
struct PeopleArguments: Codable {
    let olderThan: Int
}

struct PersonResolver {
    func people(context: NoContext, arguments: PeopleArguments) -> [Person] {
        return characters.filter { $0.age > arguments.olderThan }
    }
}

struct PointBreakAPI : API {
    typealias ContextType = NoContext
    let resolver = PersonResolver()
    let schema = try! Schema<PersonResolver, NoContext> {
        Type(Person.self) {
            Field("name", at: \.name)
            Field("age", at: \.age)
            Field("height", at: \.height)
        }
        Query {
            Field("people", at: PersonResolver.people) {
                Argument("olderThan", at: \.olderThan)
            }
        }
    }
}
```

A request string for this might be:

```graphql
{
  people(olderThan: 25) {
    name
  }
}
```

which would generate the response:

```json
{
  "people" : [
    {
      "name" : "Bodhi"
    }
  ]
}
```

## Mutations

Mutations are defined using a `Mutation` block in the API, and are typically used to change an underlying dataset. We can expand our example to include a mutation that creates a new person:

```swift
struct NewPersonArguments: Codable {
    let name: String
    let age: Int
    let height: Double
}

struct PersonResolver {
    func people(context: NoContext, arguments: NoArguments) -> [Person] {
        return characters
    }
    func newPerson(context: NoContext, arguments: NewPersonArguments) -> Person {
        return Person(
            name: arguments.name,
            age: arguments.age,
            height: arguments.height
        )
    }
}

struct PointBreakAPI : API {
    typealias ContextType = NoContext
    let resolver = PersonResolver()
    let schema = try! Schema<PersonResolver, NoContext> {
        Type(Person.self) {
            Field("name", at: \.name)
            Field("age", at: \.age)
            Field("height", at: \.height)
        }
        Query {
            Field("people", at: PersonResolver.people)
        }
        Mutation {
            Field("newPerson", at: PersonResolver.newPerson) {
                Argument("name", at: \.name)
                Argument("age", at: \.age)
                Argument("height", at: \.height)
            }
        }
    }
}
```

A request string for this might be:

```graphql
mutation {
  newPerson(name: "Tyler Endicott", age: 22, height: 1.63) {
    name
  }
}
```

which would generate the response:

```json
{
  "newPerson" : {
    "name" : "Tyler Endicott"
  }
}
```

## Input Objects

Sometimes we'd like to pass a complex argument. `Input`s allow us to do this and are declared by including an `Input` block in the API declaration, composed of `InputField`s. Our example can be changed to include a mutation that creates multiple new people, each passed as an input object:

```swift
struct InputPerson: Codable {
    let name: String
    let age: Int
    let height: Double
}

struct NewPeopleArguments: Codable {
    let individuals: [InputPerson]
}

struct PersonResolver {
    func people(context: NoContext, arguments: NoArguments) -> [Person] {
        return characters
    }
    func newPeople(context: NoContext, arguments: NewPeopleArguments) -> [Person] {
        return arguments.individuals.map { person in
            Person(
                name: person.name,
                age: person.age,
                height: person.height
            )
        }
    }
}

struct PointBreakAPI : API {
    typealias ContextType = NoContext
    let resolver = PersonResolver()
    let schema = try! Schema<PersonResolver, NoContext> {
        Type(Person.self) {
            Field("name", at: \.name)
            Field("age", at: \.age)
            Field("height", at: \.height)
        }
        Input(InputPerson.self) {
            InputField("name", at: \.name)
            InputField("age", at: \.age)
            InputField("height", at: \.height)
        }
        Query {
            Field("people", at: PersonResolver.people)
        }
        Mutation {
            Field("newPeople", at: PersonResolver.newPeople) {
                Argument("individuals", at: \.individuals)
            }
        }
    }
}
```

A request might look like:

```graphql
mutation {
  newPeople(individuals: [
    {name: "Tyler Endicott", age: 22, height: 1.63},
    {name: "Angelo Pappas", age: 45, height: 1.91},
  ]) {
    name
  }
}
```

which would generate the response:

```json
{
  "newPeople" : [
    {
      "name" : "Tyler Endicott"
    },
    {
      "name" : "Angelo Pappas"
    }
  ]
}
```

## Subscriptions

Subscriptions are reactive queries that return a result whenever an event occurs. This functionality is built on Swift Concurrency using `AsyncThrowingStream`. To create a subscription, include a `Subscription` block in the API declaration composed of `SubscriptionFields`. We can change our example API to include a subscription alert:

```swift
import Foundation
import GraphQL

let timer: Timer!

struct PersonResolver: Sendable {
    func people(context: NoContext, arguments: NoArguments) -> [Person] {
        return characters
    }
    func fiftyYearStormAlert(context: NoContext, arguments: NoArguments) -> ConcurrentEventStream<String> {
        let asyncStream = AsyncThrowingStream<String, Error> { continuation in
            timer = Timer.scheduledTimer(
                withTimeInterval: 60 * 60 * 24 * 365 * 50,
                repeats: true
            ) { _ in
                continuation.yield("A 50-year storm is occurring!")
            }
        }
        return ConcurrentEventStream<String>.init(asyncStream)
    }
}

struct PointBreakAPI : API {
    typealias ContextType = NoContext
    let resolver = PersonResolver()
    let schema = try! Schema<PersonResolver, NoContext> {
        Type(Person.self) {
            Field("name", at: \.name)
            Field("age", at: \.age)
            Field("height", at: \.height)
        }
        Query {
            Field("people", at: PersonResolver.people)
        }
        Subscription {
            SubscriptionField(
                "fiftyYearStormAlert",
                at: FiftyYearStorm.message,
                atSub: PersonResolver.fiftyYearStormAlert
            )
        }
    }
}
```

This schema can be subscribed to in Swift using the `subscribe` function. The example below illustrates this and prints the result on each occurance (To see results, you should probably change the timer to execute on a period faster than 50 years):

```swift
let api = PointBreakAPI()
let stream = try await api.subscribe(
    request: "subscription { fiftyYearStormAlert }",
    context: NoContext()
)
for try await event in stream {
    try print(event)
}
```

Each time an event fires, the following message will be generated:

```json
{
  "fiftyYearStormAlert": "A 50-year storm is occurring!"
}
```

## Cursor Connections

This package supports pagination using the [Relay-based GraphQL Cursor Connections Specification](https://relay.dev/graphql/connections.htm). To use this pagination style you must:

1. Ensure any `node` types implement the `Identifiable` protocol (they must have a unique `id` field)
2. Change the relevant resolver types to use `PaginationArguments` and return a `Connection`
3. Add the `PaginationArguments` arguments to the schema declaration

Here's an example using the schema above:

```swift
struct Person: Codable, Identifiable, Sendable {
    let id: Int
    let name: String
}

let characters = [
    Person(id: 1, name: "Johnny Utah"),
    Person(id: 2, name: "Bodhi"),
]

struct PersonResolver: Sendable {
    func people(context: NoContext, arguments: PaginationArguments) throws -> Connection<Person> {
        return try characters.connection(from: arguments)
    }
}

struct PointBreakAPI : API {
    typealias ContextType = NoContext
    let resolver = PersonResolver()
    let schema = try! Schema<PersonResolver, NoContext> {
        Type(Person.self) {
            Field("id", at: \.id)
            Field("name", at: \.name)
        }
        ConnectionType(Person.self)
        Query {
            Field("people", at: PersonResolver.people) {
                Argument("first", at: \.first)
                Argument("last", at: \.last)
                Argument("after", at: \.after)
                Argument("before", at: \.before)
            }
        }
    }
}
```

A request string for this might be:

```graphql
{
    people {
        edges {
            cursor
            node {
                id
                name
            }
        }
        pageInfo {
            hasPreviousPage
            hasNextPage
            startCursor
            endCursor
        }
    }
}
```

The result of this query is a `GraphQLResult` that encodes to the following JSON:

```json
{
    "people": {
        "edges": [
            {
                "cursor": "MQ==",
                "node": {
                    "id": 1,
                    "name": "Johnny Utah"
                }
            },
            {
                "cursor": "Mg==",
                "node": {
                    "id": 2,
                    "name": "Bodhi"
                }
            },
        ],
        "pageInfo": {
            "hasPreviousPage": false,
            "hasNextPage": false,
            "startCursor": "MQ==",
            "endCursor": "Mg=="
        }
    }
}
```

## Directives

GraphQL directives annotate a schema with metadata. Graphiti can declare custom
directive definitions and apply them at any type-system location, then render
both into SDL — useful when the SDL is consumed by code generators, schema
registries, or gateways that read directives as metadata.

Declare a directive with the `Directive` component, alongside your types:

```swift
Directive("model", on: .object) {
    DirectiveArgument("table", at: String.self)
}
Directive("auth", on: .fieldDefinition) {
    DirectiveArgument("role", at: Role.self)
}
Directive("tag", on: .fieldDefinition, repeatable: true) {
    DirectiveArgument("name", at: String.self)
}
```

A non-optional Swift type declares a required argument, so `String.self` above
becomes `table: String!`. Use `String?.self` for a nullable one.

Apply directives with `.directive(_:_:)`, which is available on every component
— types, fields, arguments, input fields and enum values:

```swift
Type(User.self) {
    Field("email", at: \.email)
        .directive("auth", ("role", "ADMIN"))
        .directive("tag", ("name", "pii"))
    Field("role", at: \.role)
}
.directive("model", ("table", "users"))
```

Arguments are ordered name/value pairs rather than a dictionary, so the emitted
SDL is byte-stable across builds — important when the output is committed.

### Directives on the schema definition

Every component above declares a named type, so none of them can carry a
directive applied to the `schema { }` block itself. `SchemaDirectives` is the
component for that location. It declares no type of its own and exists only to
carry applications:

```swift
Directive("validator", on: .schema, repeatable: true) {
    DirectiveArgument("name", at: String.self)
}
SchemaDirectives()
    .directive("validator", ("name", "lua-typecheck"))
    .directive("validator", ("name", "sql-lint"))
```

```graphql
schema @validator(name: "lua-typecheck") @validator(name: "sql-lint") {
  query: Query
}
```

Applications are emitted in the order written. They are addressable in
`schema.appliedDirectives` under `DirectiveTarget.schema`, which is how a
consumer reading the map finds them.

Render the schema with `sdl()`:

```swift
print(schema.sdl())
```

```graphql
directive @model(table: String!) on OBJECT

directive @auth(role: Role!) on FIELD_DEFINITION

directive @tag(name: String!) repeatable on FIELD_DEFINITION

enum Role {
  ADMIN
  MEMBER
}

type User @model(table: "users") {
  email: String! @auth(role: ADMIN) @tag(name: "pii")
  role: Role!
}
```

Note that `("role", "ADMIN")` renders as `@auth(role: ADMIN)` — unquoted —
because the value is resolved against the declared argument type, which is an
enum. The same string against a `String` argument renders quoted.

> **Important:** applied directives are held alongside the schema rather than on
> its type objects, so calling `printSchema(schema: schema.schema)` directly
> returns SDL *without* them. Always use `schema.sdl()`.

Applying a directive that was never declared, at a location its declaration does
not list, with an unknown or missing argument, or more than once when it is not
`repeatable`, throws a `SchemaError` when the schema is built.

Directives are schema metadata only — Graphiti does not give them execution
semantics, and GraphQL introspection cannot expose applied directives at all, so
consumers must read the printed SDL.

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

```graphql
directive @theme(names: [String!]!) on FIELD_DEFINITION

type Query {
  billing: BillingAccount! @theme(names: ["billing"])
}

type BillingAccount {
  id: String!
}

type Mutation {
  pay: String! @theme(names: ["billing"])
}
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
keeps views small; merely implementing an interface does not inflate a view,
only returning one does.

## Federation

Federation allows you split your GraphQL API into smaller services and link them back together so clients see a single larger API. More information can be found [here](https://www.apollographql.com/docs/federation). To enable federation you must:

1. Define `Keys` on the entity types, which specify the primary key fields and the resolver function used to load an entity from that key.
2. Provide the schema SDL to the schema itself.

Here's an example for the following schema:

```graphql
extend schema @link(url: "https://specs.apollo.dev/federation/v2.0", import: [ "@extends", "@external", "@key", "@inaccessible", "@override", "@provides", "@requires", "@shareable", "@tag"])

type Product {
    id: ID!
    sku: String
    createdBy: User
}

extend type Query {
  product(id: ID!): Product
}

extend type User @key(fields: "email") {
  email: ID! @external
  name: String @override(from: "users")
  totalProductsCreated: Int @external
  yearsOfEmployment: Int! @external
}
```

```swift
import Foundation
import Graphiti

struct Product: Codable, Sendable {
    let id: String
    let sku: String
    let createdBy: User
}

struct User: Codable, Sendable {
    let email: String
    let name: String?
    let totalProductsCreated: Int?
    let yearsOfEmployment: Int
}

struct ProductContext: Sendable {
    func getUser(email: String) -> User { ... }
}

struct ProductResolver: Sendable {
    struct UserArguments: Codable, Sendable {
        let email: String
    }

    func user(context: ProductContext, arguments: UserArguments) -> User? {
        context.getUser(email: arguments.email)
    }
}

final class ProductSchema: PartialSchema<ProductResolver, ProductContext> {
    @TypeDefinitions
    override var types: Types {
        Type(Product.self) {
            Field("id", at: \.id)
            Field("sku", at: \.sku)
            Field("createdBy", at: \.createdBy)
        }

        Type(
            User.self,
            keys: {
                Key(at: ProductResolver.user) {
                    Argument("email", at: \.email)
                }
            }
        ) {
            Field("email", at: \.email)
            Field("name", at: \.name)
            Field("totalProductsCreated", at: \.totalProductsCreated)
            Field("yearsOfEmployment", at: \.yearsOfEmployment)
        }
    }
}

struct ProductAPI: API {
    let resolver: ProductResolver
    let schema: Schema<ProductResolver, ProductContext>
}

let schema = try SchemaBuilder(ProductResolver.self, ProductContext.self)
    .use(partials: [ProductSchema()])
    .setFederatedSDL(to: getSDL())
    .build()

let api = ProductAPI(resolver: ProductResolver(), schema: schema)

try await api.execute(
    request: """
    query {
      _entities(representations: {__typename: "User", email: "abc@def.com"}) {
        ... on User {
          email
          name
        }
      }
    }
    """,
    context: ProductContext()
)
```
