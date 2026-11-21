// Generated from tag 0.1.0 (9dd054d) by building SyntheticRuntimeSchema shapes and
// recording each printed SDL (byte count + FNV-1a 64) or thrown error. Errors
// listed with more than one message were observed to vary between runs of
// 0.1.0 itself (36 runs): which invalid target is reported first follows
// Dictionary iteration order, which is seeded per process.

enum RuntimeScaleFixtures {
    static let sdl: [String: (bytes: Int, fnv1a64: String)] = [
        "nativeRoots": (18907, "b45b61806ffae9c3"),
        "rootHeavy": (54857, "ee55d803944ada13"),
        "sized100": (28760, "cac9b1bcd5fd78b7"),
        "sized400": (116571, "66bdd7ff0e2b0340"),
        "tiny": (1991, "b6bd46c99d3662b"),
        "typeHeavy": (108626, "93b2a4ab91408e46"),
    ]

    static let errors: [String: Set<String>] = [
        "defect.duplicateRuntimeRootField": [
            #"Graphiti.SchemaError(description: "Duplicate runtime root field Query.r0")"#,
        ],
        "defect.duplicateType": [
            #"Graphiti.SchemaError(description: "Duplicate or reserved runtime type SynthObj0")"#,
        ],
        "defect.locationViolation": [
            #"Graphiti.SchemaError(description: "Directive @objectOnly is not permitted on FIELD_DEFINITION.")"#,
        ],
        "defect.locationViolationOnValues": [
            #"Graphiti.SchemaError(description: "Directive @objectOnly is not permitted on ENUM_VALUE.")"#,
            #"Graphiti.SchemaError(description: "Directive @objectOnly is not permitted on INPUT_FIELD_DEFINITION.")"#,
        ],
        "defect.nativeOwnedTarget": [
            #"Graphiti.SchemaError(description: "Directive target is not runtime-owned: member(type: \"Native\", member: \"id\")")"#,
        ],
        "defect.rootFieldCollidesWithNative": [
            #"Graphiti.SchemaError(description: "Duplicate root field Query.native")"#,
        ],
        "defect.severalUnknownTargets": [
            #"Graphiti.SchemaError(description: "Unknown runtime directive target argument(type: \"Query\", field: \"r1\", argument: \"missing2\")")"#,
            #"Graphiti.SchemaError(description: "Unknown runtime directive target member(type: \"SynthEnum0\", member: \"MISSING3\")")"#,
            #"Graphiti.SchemaError(description: "Unknown runtime directive target member(type: \"SynthObj0\", member: \"missing1\")")"#,
        ],
        "defect.undeclaredDirective": [
            #"Graphiti.SchemaError(description: "Directive @neverDeclared is applied but never declared.")"#,
        ],
        "defect.unknownArgumentTarget": [
            #"Graphiti.SchemaError(description: "Unknown runtime directive target argument(type: \"Query\", field: \"r0\", argument: \"missing\")")"#,
        ],
        "defect.unknownEnumValueTarget": [
            #"Graphiti.SchemaError(description: "Unknown runtime directive target member(type: \"SynthEnum0\", member: \"MISSING\")")"#,
        ],
        "defect.unknownMemberTarget": [
            #"Graphiti.SchemaError(description: "Unknown runtime directive target member(type: \"SynthObj0\", member: \"missing\")")"#,
        ],
        "nativeRoots.unknownArgumentTarget": [
            #"Graphiti.SchemaError(description: "Unknown runtime directive target argument(type: \"Query\", field: \"r0\", argument: \"missing\")")"#,
        ],
    ]

    /// The full SDL of the "tiny" shape, so a mismatch shows a readable diff.
    static let tinySDL = #"""
schema @tag(name: "schema") {
  query: Query
  mutation: Mutation
}

directive @nativeTag(name: String!) on FIELD_DEFINITION | OBJECT

directive @tag(name: String!) repeatable on SCHEMA | SCALAR | OBJECT | FIELD_DEFINITION | ARGUMENT_DEFINITION | INTERFACE | UNION | ENUM | ENUM_VALUE | INPUT_OBJECT | INPUT_FIELD_DEFINITION

directive @objectOnly on OBJECT

type Native @nativeTag(name: "native-type") {
  id: String! @nativeTag(name: "native-id")
  firstObject: SynthObj0
}

scalar SynthScalar @tag(name: "scalar")

enum SynthEnum0 @tag(name: "enum0") {
  V0 @tag(name: "enum0.V0")
  V1 @tag(name: "enum0.V1")
}

input SynthInput0 @tag(name: "input0") {
  x0: String @tag(name: "input0.x0")
  mode: SynthEnum0
}

interface SynthNode @tag(name: "node") {
  id: String @tag(name: "node-id")
}

type SynthObj0 implements SynthNode @tag(name: "SynthObj0") {
  id: String @tag(name: "SynthObj0.id")
  f0: String @tag(name: "SynthObj0.f0")
  f1: String @tag(name: "SynthObj0.f1")
  mode: SynthEnum0
  query(where: SynthInput0 @tag(name: "SynthObj0.query.where")): String @tag(name: "SynthObj0.query")
  next: SynthObj1
}

type SynthObj1 implements SynthNode @tag(name: "SynthObj1") {
  id: String @tag(name: "SynthObj1.id")
  f0: String @tag(name: "SynthObj1.f0")
  f1: String @tag(name: "SynthObj1.f1")
  mode: SynthEnum0
  query(where: SynthInput0 @tag(name: "SynthObj1.query.where")): String @tag(name: "SynthObj1.query")
}

union SynthUnion @tag(name: "union") = SynthObj0 | SynthObj1

type Query {
  native: Native!
  r0(id: ID @tag(name: "r0.id"), filter: SynthInput0 @tag(name: "r0.filter")): SynthObj0 @tag(name: "r0#0")
  r1(id: ID @tag(name: "r1.id"), filter: SynthInput0 @tag(name: "r1.filter")): SynthObj1 @tag(name: "r1#0")
  r2(id: ID @tag(name: "r2.id"), filter: SynthInput0 @tag(name: "r2.filter")): SynthObj0 @tag(name: "r2#0")
  anyNode: SynthUnion
}

type Mutation {
  m0(id: ID @tag(name: "m0.id"), filter: SynthInput0 @tag(name: "m0.filter")): SynthObj0 @tag(name: "m0#0")
}
"""#
}
