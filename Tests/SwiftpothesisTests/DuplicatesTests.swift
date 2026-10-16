import Foundation
import Testing

@testable import Swiftpothesis

@Suite(.propertyOverrides { $0.database = nil })
struct DuplicatesTests {
    /// Case variants are neighbors in this alphabet, so a near copy can differ only in case.
    static var names: some Generator<String> {
        String.arbitrary(alphabet: "aAbBcCdDeEfFgGhH", count: 3...6)
    }

    @Test func producesExactCopies() async {
        let names = Self.names.withDuplicates(probability: 0.5)
        let result = await forAll(names, names) { a, b in
            label(a == b ? "equal" : "different")
        }
        #expect(result.labels["equal", default: 0] > 10)
    }

    @Test func doesntDuplicateAcrossSeparateGenerators() async {
        let result = await forAll(
            Self.names.withDuplicates(probability: 1), Self.names.withDuplicates(probability: 1)
        ) { a, b in
            label(a == b ? "equal" : "different")
        }
        #expect(result.labels["equal", default: 0] < 5)
    }

    /// Whether a case-insensitive collision is found, with or without duplicates.
    func findsCollision(duplicates: Bool, seed: UInt64) async -> Bool {
        var settings = Settings.defaults
        settings.database = nil
        settings.seed = seed
        settings.phases.remove(.target)
        let base = Self.names
        let result: PropertyResult
        if duplicates {
            let names = base.withDuplicates()
            result = await failuresResult {
                await forAll(names, names, settings: settings) { a, b in
                    try assume(a != b)
                    #expect(a.lowercased() != b.lowercased())
                }
            }
        } else {
            result = await failuresResult {
                await forAll(base, base, settings: settings) { a, b in
                    try assume(a != b)
                    #expect(a.lowercased() != b.lowercased())
                }
            }
        }
        return !result.passed
    }

    @Test func makesRareCollisionsCommon() async {
        var with = 0
        var without = 0
        for seed in 1...10 as ClosedRange<UInt64> {
            if await findsCollision(duplicates: true, seed: seed) { with += 1 }
            if await findsCollision(duplicates: false, seed: seed) { without += 1 }
        }
        #expect(with >= 8, "with: \(with)")
        #expect(without <= 2, "without: \(without)")
    }

    @Test(.propertyOverrides { $0.derandomize = true })
    func collisionsShrink() async {
        let names = Self.names.withDuplicates()
        let issues = await failures {
            await forAll(names, names) { a, b in
                try assume(a != b)
                #expect(a.lowercased() != b.lowercased())
            }
        }
        // The shortest strings differing only in case: "aaa" and a case variant of it.
        #expect(issues.last?.contains(#""aaa""#) == true, "\(issues.last ?? "")")
    }

    @Test func dataIsArbitrary() async {
        await forAll { (data: Data) in
            #expect(data.count <= 100)
        }
        await forAll(Data.arbitrary(count: 4...4)) { data in #expect(data.count == 4) }
    }
}
