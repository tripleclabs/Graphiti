import Graphiti
import GraphQL

// A deterministic, runtime-composed schema of configurable size, built only
// through public entry points (`Schema(..., runtime:)` and
// `RuntimeSchemaBuilder`) in the way a declarative-resource engine composes
// one. The same file is compiled against tag 0.1.0 to produce the expected
// SDL/error fixtures in `RuntimeScaleFixtures.swift`, so it must keep to the
// 0.1.0 public API.

struct SyntheticRoot: Sendable {
    func native(context _: NoContext, arguments _: NoArguments) -> SyntheticNative { .init(id: "n") }
}

struct SyntheticNative: Codable, Sendable { let id: String }

/// Something that can go wrong in a synthetic build.
enum SyntheticDefect: String, CaseIterable, Sendable {
    case none
    /// `addQueryField` twice with the same name.
    case duplicateRuntimeRootField
    /// A runtime root field with the same name as a native root field.
    case rootFieldCollidesWithNative
    /// A runtime type whose name is already taken.
    case duplicateType
    /// `apply` at a member that does not exist on a runtime-owned type.
    case unknownMemberTarget
    /// `apply` at an argument that does not exist on a runtime root field.
    case unknownArgumentTarget
    /// `apply` at an enum value that does not exist.
    case unknownEnumValueTarget
    /// `apply` at a native-owned type.
    case nativeOwnedTarget
    /// An OBJECT-only directive applied to a field definition.
    case locationViolation
    /// An OBJECT-only directive applied to an enum value and an input field.
    case locationViolationOnValues
    /// A directive applied that was never declared.
    case undeclaredDirective
    /// Several unknown targets at once; the one reported depends on which
    /// target the builder visits first.
    case severalUnknownTargets
}

struct SyntheticRuntimeSchema: Sendable {
    var rootFields: Int
    var mutationFields: Int
    var objectTypes: Int
    var fieldsPerObject: Int
    var enums: Int
    var valuesPerEnum: Int
    var inputs: Int
    var fieldsPerInput: Int
    /// Applications of `@tag` at each root field (arguments get one each).
    var applicationsPerRootField: Int
    /// Plain native `Field`s on the native `Query` (built with `SchemaBuilder`).
    var nativeRootFields = 0
    /// Native `RuntimeField`s on the native `Query`.
    var nativeRuntimeRootFields = 0
    var defect: SyntheticDefect = .none

    /// The size used for the timing and scaling runs: `n` root fields with a
    /// few directive applications each, plus object/enum/input types.
    static func sized(_ n: Int) -> SyntheticRuntimeSchema {
        SyntheticRuntimeSchema(
            rootFields: n, mutationFields: n / 8, objectTypes: max(1, n / 4), fieldsPerObject: 4,
            enums: max(1, n / 16), valuesPerEnum: 4, inputs: max(1, n / 8), fieldsPerInput: 3,
            applicationsPerRootField: 2
        )
    }

    /// The shapes whose 0.1.0 output is pinned in `RuntimeScaleFixtures`.
    static var fixtureShapes: [(name: String, shape: SyntheticRuntimeSchema)] {
        var shapes: [(name: String, shape: SyntheticRuntimeSchema)] = [
            ("tiny", SyntheticRuntimeSchema(
                rootFields: 3, mutationFields: 1, objectTypes: 2, fieldsPerObject: 2, enums: 1,
                valuesPerEnum: 2, inputs: 1, fieldsPerInput: 1, applicationsPerRootField: 1
            )),
            ("rootHeavy", SyntheticRuntimeSchema(
                rootFields: 300, mutationFields: 40, objectTypes: 3, fieldsPerObject: 2, enums: 1,
                valuesPerEnum: 3, inputs: 2, fieldsPerInput: 2, applicationsPerRootField: 3
            )),
            ("typeHeavy", SyntheticRuntimeSchema(
                rootFields: 10, mutationFields: 0, objectTypes: 150, fieldsPerObject: 8, enums: 20,
                valuesPerEnum: 12, inputs: 40, fieldsPerInput: 6, applicationsPerRootField: 1
            )),
            ("sized100", .sized(100)),
            ("sized400", .sized(400)),
        ]
        var nativeRoots = SyntheticRuntimeSchema.sized(60)
        nativeRoots.nativeRootFields = 30
        nativeRoots.nativeRuntimeRootFields = 10
        shapes.append(("nativeRoots", nativeRoots))
        var nativeRootsDefect = nativeRoots
        nativeRootsDefect.defect = .unknownArgumentTarget
        shapes.append(("nativeRoots.unknownArgumentTarget", nativeRootsDefect))
        for defect in SyntheticDefect.allCases where defect != .none {
            var shape = SyntheticRuntimeSchema.sized(40)
            shape.defect = defect
            shapes.append(("defect.\(defect.rawValue)", shape))
        }
        return shapes
    }

    /// Every target this schema applies a directive to (valid builds only).
    var directiveTargetCount: Int {
        let objectTargets = objectTypes * (1 + fieldsPerObject + 1 + 1 + 1) // type, fields, next, query, its arg
        let enumTargets = enums * (1 + valuesPerEnum)
        let inputTargets = inputs * (1 + fieldsPerInput)
        let rootTargets = (rootFields + mutationFields) * 3 // field, id arg, filter arg
        // schema, scalar, interface, interface field, union
        return 5 + objectTargets + enumTargets + inputTargets + rootTargets
    }

    func build() throws -> Schema<SyntheticRoot, NoContext> {
        if nativeRootFields > 0 || nativeRuntimeRootFields > 0 {
            return try buildWithNativeRoots()
        }
        return try Schema<SyntheticRoot, NoContext>(runtime: { runtime in try install(into: runtime) }) {
            Directive("nativeTag", on: .fieldDefinition, .object) { DirectiveArgument("name", at: String.self) }
            Type(SyntheticNative.self, as: "Native") {
                Field("id", at: \.id).directive("nativeTag", ("name", "native-id"))
                RuntimeField("firstObject") { types in GraphQLField(type: try types.output("SynthObj0")) }
            }
            .directive("nativeTag", ("name", "native-type"))
            Query { Field("native", at: SyntheticRoot.native) }
        }
    }

    /// The same schema, with a native `Query` that carries
    /// `nativeRootFields` plain fields and `nativeRuntimeRootFields`
    /// `RuntimeField`s next to the runtime root fields, as an application that
    /// composes runtime resources with its own native API does.
    private func buildWithNativeRoots() throws -> Schema<SyntheticRoot, NoContext> {
        let plain: [FieldComponent<SyntheticRoot, NoContext>] = (0 ..< nativeRootFields).map { i in
            Field("native\(i)", at: SyntheticRoot.native).directive("nativeTag", ("name", .string("native\(i)")))
        }
        let runtimeFields: [FieldComponent<SyntheticRoot, NoContext>] = (0 ..< nativeRuntimeRootFields).map { i in
            RuntimeField("nativeObject\(i)") { types in GraphQLField(type: try types.output("SynthObj\(i % objectTypes)")) }
        }
        let fields = { plain + runtimeFields }
        return try SchemaBuilder(SyntheticRoot.self, NoContext.self)
            .add {
                Directive("nativeTag", on: .fieldDefinition, .object) { DirectiveArgument("name", at: String.self) }
                Type(SyntheticNative.self, as: "Native") { Field("id", at: \.id) }
            }
            .addQuery(fields)
            .build(runtime: { runtime in try install(into: runtime) })
    }

    private func tag(_ name: String) -> AppliedDirective {
        AppliedDirective(name: "tag", arguments: [("name", .string(name))])
    }

    func install(into runtime: RuntimeSchemaBuilder) throws {
        let string = try runtime.types.output("String")
        let id = try runtime.types.input("ID")

        let allLocations: [DirectiveLocation] = [
            .schema, .scalar, .object, .fieldDefinition, .argumentDefinition, .interface,
            .union, .enum, .enumValue, .inputObject, .inputFieldDefinition,
        ]
        try runtime.addDirective(GraphQLDirective(
            name: "tag", locations: allLocations,
            args: ["name": GraphQLArgument(type: GraphQLNonNull(GraphQLString))], isRepeatable: true
        ))
        try runtime.addDirective(GraphQLDirective(name: "objectOnly", locations: [.object]))

        let scalar = try GraphQLScalarType(name: "SynthScalar")
        try runtime.addType(scalar)

        var enumTypes: [GraphQLEnumType] = []
        for e in 0 ..< enums {
            var values = GraphQLEnumValueMap()
            for v in 0 ..< valuesPerEnum { values["V\(v)"] = GraphQLEnumValue(value: .string("V\(v)")) }
            let type = try GraphQLEnumType(name: "SynthEnum\(e)", values: values)
            enumTypes.append(type)
            try runtime.addType(type)
        }

        var inputTypes: [GraphQLInputObjectType] = []
        for i in 0 ..< inputs {
            var fields = InputObjectFieldMap()
            for f in 0 ..< fieldsPerInput { fields["x\(f)"] = InputObjectField(type: GraphQLString) }
            fields["mode"] = InputObjectField(type: enumTypes[i % enumTypes.count])
            let type = try GraphQLInputObjectType(name: "SynthInput\(i)", fields: fields)
            inputTypes.append(type)
            try runtime.addType(type)
        }

        let node = try GraphQLInterfaceType(name: "SynthNode", fields: ["id": GraphQLField(type: string)])
        try runtime.addType(node)

        // Built in reverse so `next` can refer to the following type directly.
        var objects: [GraphQLObjectType] = Array()
        var next: GraphQLObjectType?
        for o in stride(from: objectTypes - 1, through: 0, by: -1) {
            var fields = GraphQLFieldMap()
            fields["id"] = GraphQLField(type: string)
            for f in 0 ..< fieldsPerObject { fields["f\(f)"] = GraphQLField(type: string) }
            fields["mode"] = GraphQLField(type: enumTypes[o % enumTypes.count])
            fields["query"] = GraphQLField(
                type: string, args: ["where": GraphQLArgument(type: inputTypes[o % inputTypes.count])]
            )
            if let next { fields["next"] = GraphQLField(type: next) }
            let type = try GraphQLObjectType(name: "SynthObj\(o)", fields: fields, interfaces: [node])
            objects.append(type)
            next = type
        }
        objects.reverse()
        for object in objects { try runtime.addType(object) }

        let union = try GraphQLUnionType(name: "SynthUnion", types: Array(objects.prefix(3)))
        try runtime.addType(union)

        func rootField(_ o: Int) -> GraphQLField {
            GraphQLField(type: objects[o % objects.count], args: [
                "id": GraphQLArgument(type: id),
                "filter": GraphQLArgument(type: inputTypes[o % inputTypes.count]),
            ])
        }
        for r in 0 ..< rootFields { try runtime.addQueryField("r\(r)", field: rootField(r)) }
        for m in 0 ..< mutationFields { try runtime.addMutationField("m\(m)", field: rootField(m)) }
        try runtime.addQueryField("anyNode", field: GraphQLField(type: union))

        switch defect {
        case .duplicateRuntimeRootField: try runtime.addQueryField("r0", field: GraphQLField(type: string))
        case .rootFieldCollidesWithNative: try runtime.addQueryField("native", field: GraphQLField(type: string))
        case .duplicateType: try runtime.addType(GraphQLObjectType(name: "SynthObj0", fields: ["x": GraphQLField(type: string)]))
        default: break
        }

        // Applications, in a fixed order.
        let query = runtime.queryTypeName
        let mutation = runtime.mutationTypeName
        try runtime.apply([tag("schema")], at: .schema)
        try runtime.apply([tag("scalar")], at: .type("SynthScalar"))
        try runtime.apply([tag("node")], at: .type("SynthNode"))
        try runtime.apply([tag("node-id")], at: .member(type: "SynthNode", member: "id"))
        try runtime.apply([tag("union")], at: .type("SynthUnion"))
        for (e, _) in enumTypes.enumerated() {
            try runtime.apply([tag("enum\(e)")], at: .type("SynthEnum\(e)"))
            for v in 0 ..< valuesPerEnum {
                try runtime.apply([tag("enum\(e).V\(v)")], at: .member(type: "SynthEnum\(e)", member: "V\(v)"))
            }
        }
        for (i, _) in inputTypes.enumerated() {
            try runtime.apply([tag("input\(i)")], at: .type("SynthInput\(i)"))
            for f in 0 ..< fieldsPerInput {
                try runtime.apply([tag("input\(i).x\(f)")], at: .member(type: "SynthInput\(i)", member: "x\(f)"))
            }
        }
        for o in 0 ..< objects.count {
            let name = "SynthObj\(o)"
            try runtime.apply([tag(name)], at: .type(name))
            try runtime.apply([tag("\(name).id")], at: .member(type: name, member: "id"))
            for f in 0 ..< fieldsPerObject {
                try runtime.apply([tag("\(name).f\(f)")], at: .member(type: name, member: "f\(f)"))
            }
            try runtime.apply([tag("\(name).query")], at: .member(type: name, member: "query"))
            try runtime.apply([tag("\(name).query.where")], at: .argument(type: name, field: "query", argument: "where"))
        }
        for (root, prefix, count) in [(query, "r", rootFields), (mutation, "m", mutationFields)] {
            for r in 0 ..< count {
                let field = "\(prefix)\(r)"
                try runtime.apply((0 ..< applicationsPerRootField).map { tag("\(field)#\($0)") }, at: .member(type: root, member: field))
                try runtime.apply([tag("\(field).id")], at: .argument(type: root, field: field, argument: "id"))
                try runtime.apply([tag("\(field).filter")], at: .argument(type: root, field: field, argument: "filter"))
            }
        }

        switch defect {
        case .unknownMemberTarget:
            try runtime.apply([tag("missing")], at: .member(type: "SynthObj0", member: "missing"))
        case .unknownArgumentTarget:
            try runtime.apply([tag("missing")], at: .argument(type: query, field: "r0", argument: "missing"))
        case .unknownEnumValueTarget:
            try runtime.apply([tag("missing")], at: .member(type: "SynthEnum0", member: "MISSING"))
        case .nativeOwnedTarget:
            try runtime.apply([tag("native")], at: .member(type: "Native", member: "id"))
        case .locationViolation:
            try runtime.apply([AppliedDirective(name: "objectOnly")], at: .member(type: query, member: "r0"))
        case .locationViolationOnValues:
            try runtime.apply([AppliedDirective(name: "objectOnly")], at: .member(type: "SynthEnum0", member: "V0"))
            try runtime.apply([AppliedDirective(name: "objectOnly")], at: .member(type: "SynthInput0", member: "x0"))
        case .undeclaredDirective:
            try runtime.apply([AppliedDirective(name: "neverDeclared")], at: .type("SynthObj0"))
        case .severalUnknownTargets:
            try runtime.apply([tag("missing1")], at: .member(type: "SynthObj0", member: "missing1"))
            try runtime.apply([tag("missing2")], at: .argument(type: query, field: "r1", argument: "missing2"))
            try runtime.apply([tag("missing3")], at: .member(type: "SynthEnum0", member: "MISSING3"))
        default: break
        }
    }
}
