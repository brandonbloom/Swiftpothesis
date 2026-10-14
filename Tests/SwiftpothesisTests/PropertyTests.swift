import Synchronization
import Testing

@testable import Swiftpothesis

@Suite(.propertySettings { $0.database = nil })
struct PropertyTests {
    @Test func passingPropertyRecordsNoIssues() async {
        await forAll(.integers(in: 0...100)) { x in
            #expect(x >= 0 && x <= 100)
        }
    }

    @Test func arbitraryArguments() async {
        await forAll { (a: Int, b: Int, s: String) in
            #expect(a &+ b == b &+ a)
            #expect(String(s.unicodeScalars) == s)
        }
    }

    @Test func integerShrinksToBoundary() async {
        let issues = await failures {
            await forAll(.integers(in: 0...1_000_000)) { x in
                #expect(x < 1234)
            }
        }
        #expect(issues.filter { $0.contains("Property falsified") }.count == 1)
        #expect(issues.last?.contains("Counterexample: 1234") == true)
    }

    @Test func negativeIntegersShrinkTowardZero() async {
        let issues = await failures {
            await forAll(.integers(in: -1000...1000)) { x in
                #expect(x > -17)
            }
        }
        #expect(issues.last?.contains("Counterexample: -17") == true)
    }

    @Test func arrayShrinksToSingleMinimalElement() async {
        let issues = await failures {
            await forAll(.arrays(of: .integers(in: 0...1000))) { array in
                #expect(array.allSatisfy { $0 < 50 })
            }
        }
        #expect(issues.last?.contains("Counterexample: [50]") == true)
    }

    @Test func shrinkingSurvivesFlatMap() async {
        // An array, then an index into it: dependent generation that integrated shrinking
        // handles poorly.
        let generator = Generators.Arrays(element: .integers(in: 0...100), count: 1...20).flatMap {
            array in zip(.just(array), .integers(in: 0...(array.count - 1)))
        }
        let issues = await failures {
            await forAll(generator) { pair in
                #expect(pair.0[pair.1] < 10)
            }
        }
        #expect(issues.last?.contains("Counterexample: ([10], 0)") == true)
    }

    @Test func thrownErrorsFail() async {
        struct Boom: Error {}
        let issues = await failures {
            await forAll(.integers(in: 0...100)) { x in
                if x > 3 { throw Boom() }
            }
        }
        #expect(issues.last?.contains("Counterexample: 4") == true)
    }

    @Test func assumptionsDiscard() async {
        await forAll(.integers(in: 0...100)) { x in
            try assume(x % 2 == 0)
            #expect(x % 2 == 0)
        }
    }

    @Test func notesAppearInReport() async {
        let issues = await failures {
            await forAll(.integers(in: 0...100)) { x in
                note("doubled: \(x * 2)")
                #expect(x < 5)
            }
        }
        #expect(issues.last?.contains("Note: doubled: 10") == true)
    }

    @Test func databaseReplaysFailures() async {
        let database = InMemoryDatabase()
        var settings = Settings.defaults
        settings.database = database
        // Failures are saved per call site, so both runs share one.
        func check(_ settings: Settings) async -> [String] {
            await failures {
                await forAll(.integers(in: 0...1000), settings: settings) { x in #expect(x < 500) }
            }
        }
        _ = await check(settings)
        settings.phases = [.reuse]
        let replayed = await check(settings)
        #expect(replayed.last?.contains("Counterexample: 500") == true)
    }

    @Test func seedReproducesRun() async {
        var settings = Settings.defaults
        settings.database = nil
        settings.seed = 42
        settings.phases = [.generate]
        let first = await failures {
            await forAll(.integers(in: 0...1000), settings: settings) { x in #expect(x < 900) }
        }
        let second = await failures {
            await forAll(.integers(in: 0...1000), settings: settings) { x in #expect(x < 900) }
        }
        #expect(first == second)
    }

    @MainActor @Test func runsOnCallersActor() async {
        await forAll(.booleans()) { _ in
            MainActor.assertIsolated()
        }
    }
}

/// Runs `body`, expecting it to record issues, and returns their descriptions.
func failures(_ body: () async -> Void) async -> [String] {
    let recorded = Mutex<[String]>([])
    await withKnownIssue {
        await body()
    } matching: { issue in
        recorded.withLock { $0.append(issue.comments.map(\.rawValue).joined(separator: "\n")) }
        return true
    }
    return recorded.withLock { $0 }
}

@Suite(.propertySettings { $0.database = nil })
struct TestCaseTests {
    @Test func drawsDependOnEarlierResults() async {
        let issues = await failures {
            await forAll { test in
                let array = try test.draw(.arrays(of: .integers(in: 0...100), count: 1...20))
                let index = try test.draw(.integers(in: 0...(array.count - 1)))
                #expect(array[index] < 10)
            }
        }
        #expect(issues.last?.contains("Draw 1: [10]\nDraw 2: 0") == true)
    }

    @Test func streamsDrawOnDemand() async {
        let issues = await failures {
            await forAll { test in
                let total = test.stream(of: .integers(in: 0...10)).prefix(5).reduce(0, +)
                #expect(total < 20)
            }
        }
        #expect(issues.last?.contains("Counterexample:") == true)
    }
}
