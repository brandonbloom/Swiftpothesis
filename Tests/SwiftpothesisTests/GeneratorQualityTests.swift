import Testing

@testable import Swiftpothesis

@Suite(.propertyOverrides { $0.database = nil })
struct GeneratorQualityTests {
    @Test func doublesCoverNarrowRanges() async {
        let result = await forAll(Double.arbitrary(in: 0...1)) { x in
            #expect((0...1).contains(x))
            label(x == 0 || x == 1 ? "end" : "interior")
        }
        #expect(result.labels["interior", default: 0] > 25)
    }

    @Test func doublesShrinkTowardSimpleValues() async {
        let issues = await failures {
            await forAll(Double.arbitrary(in: -1000...1000)) { x in #expect(x < 12.5) }
        }
        // Integers are the simplest kind of double, so the smallest failing integer wins.
        #expect(issues.last?.contains("Counterexample: 13.0") == true)
    }

    @Test func setsReachTheirMinimumCount() async {
        await forAll(Set<Int>.arbitrary(Int.arbitrary(in: 0...20), count: 5...10)) { set in
            #expect(set.count >= 5)
        }
    }

    @Test func setsShrinkToFewerSmallerElements() async {
        let issues = await failures {
            await forAll(Set<Int>.arbitrary(Int.arbitrary(in: 0...100))) { set in
                #expect(set.count < 3)
            }
        }
        #expect(issues.last?.contains("Counterexample: Set([") == true)
    }

    @Test func cancellingAVirtualSleepWakesIt() async {
        await forAll { test in
            let clock = test.clock
            let sleeper = Task { try await clock.sleep(for: .seconds(3600)) }
            sleeper.cancel()
            await #expect(throws: CancellationError.self) { try await sleeper.value }
        }
    }
}
