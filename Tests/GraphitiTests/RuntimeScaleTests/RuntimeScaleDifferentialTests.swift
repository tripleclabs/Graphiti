import Graphiti
import GraphQL
import Testing

private func fnv1a64(_ text: String) -> String {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01B3
    }
    return String(hash, radix: 16)
}

/// Runtime-composed schemas must print and fail exactly as they did in 0.1.0.
@Suite struct RuntimeScaleDifferentialTests {
    @Test func everyFixtureShapeIsCovered() {
        let names = Set(SyntheticRuntimeSchema.fixtureShapes.map(\.name))
        #expect(names == Set(RuntimeScaleFixtures.sdl.keys).union(RuntimeScaleFixtures.errors.keys))
    }

    @Test(arguments: SyntheticRuntimeSchema.fixtureShapes.map(\.name))
    func matchesTag010(_ name: String) throws {
        let shape = try #require(SyntheticRuntimeSchema.fixtureShapes.first { $0.name == name }?.shape)
        if let expected = RuntimeScaleFixtures.sdl[name] {
            let sdl = try shape.build().sdl()
            if name == "tiny" { #expect(sdl == RuntimeScaleFixtures.tinySDL) }
            #expect(sdl.utf8.count == expected.bytes)
            #expect(fnv1a64(sdl) == expected.fnv1a64)
        } else {
            let expected = try #require(RuntimeScaleFixtures.errors[name])
            do {
                _ = try shape.build()
                Issue.record("\(name) built, expected one of \(expected)")
            } catch {
                #expect(expected.contains(String(reflecting: error)))
            }
        }
    }
}
