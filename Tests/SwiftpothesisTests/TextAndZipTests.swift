import Testing

@testable import Swiftpothesis

@Suite(.propertyOverrides { $0.database = nil })
struct TextAndZipTests {
    @Test func alphabetsLimitStrings() async {
        await forAll(String.arbitrary(alphabet: "aA.:", count: 1...3)) { string in
            #expect(string.unicodeScalars.allSatisfy { "aA.:".unicodeScalars.contains($0) })
            #expect((1...3).contains(string.unicodeScalars.count))
        }
    }

    @Test(.propertyOverrides { $0.derandomize = true })
    func smallAlphabetsFindCollisions() async {
        // A case-insensitive file name collides for "a" and "A".
        let issues = await failures {
            await forAll(
                String.arbitrary(alphabet: "aA.", count: 1...2),
                String.arbitrary(alphabet: "aA.", count: 1...2)
            ) { a, b in
                try assume(a != b)
                #expect(a.lowercased() != b.lowercased())
            }
        }
        // Either order is a minimal collision.
        #expect(
            issues.last.map {
                $0.contains(#"Counterexample: ("a", "A")"#)
                    || $0.contains(#"Counterexample: ("A", "a")"#)
            } == true)
    }

    @Test func scalarRangesSkipSurrogates() async {
        let result = await forAll(Unicode.Scalar.arbitrary(in: "\u{D7F0}"..."\u{E010}")) { s in
            #expect(!(0xD800...0xDFFF).contains(s.value))
            #expect((0xD7F0...0xE010).contains(s.value))
            label(s.value > 0xDFFF ? "above" : "below")
        }
        #expect(result.labels["above", default: 0] > 0)
        #expect(result.labels["below", default: 0] > 0)
    }

    @Test func categoriesLimitScalars() async {
        await forAll(
            Unicode.Scalar.arbitrary(categories: [.uppercaseLetter], in: "\u{0}"..."\u{2FF}")
        ) { s in
            #expect(s.properties.generalCategory == .uppercaseLetter)
        }
    }

    @Test func zipFlatMapPassesSeparateArguments() async {
        let grids = zip(Int.arbitrary(in: 1...4), Int.arbitrary(in: 1...4)).flatMap { w, h in
            [UInt8].arbitrary(UInt8.arbitrary, count: (w * h)...(w * h)).map { (w, h, $0) }
        }
        await forAll(grids) { grid in
            #expect(grid.2.count == grid.0 * grid.1)
        }
    }
}
