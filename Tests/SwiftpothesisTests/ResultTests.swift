import Synchronization
import Testing

@testable import Swiftpothesis

@Suite(.propertySettings { $0.database = nil })
struct ResultTests {
    @Test func passingResult() {
        let result = forAll(Int.arbitrary(in: 0...9)) { x in #expect(x < 10) }
        #expect(result.passed)
        #expect(result.examples == 100)
    }

    @Test func falsifiedResult() async {
        let result = Mutex<PropertyResult?>(nil)
        _ = await failures {
            let r = forAll(Int.arbitrary(in: 0...100)) { x in #expect(x < 7) }
            result.withLock { $0 = r }
        }
        #expect(result.withLock { $0?.falsification?.counterexample } == "7")
    }

    @Test func requireThrowsExpectationFailedError() async {
        let thrown = Mutex<(any Error)?>(nil)
        _ = await failures {
            do {
                try forAll(Int.arbitrary(in: 0...100)) { x in #expect(x < 7) }.require()
            } catch {
                thrown.withLock { $0 = error }
            }
        }
        #expect(thrown.withLock { $0 } is ExpectationFailedError)
    }
}

/// Without a `propertySettings` trait, synchronous properties fall back to known issues while
/// searching, but still report the shrunk failure.
struct UntraitedTests {
    @Test func syncFallbackStillShrinks() async {
        var settings = Settings.defaults
        settings.database = nil
        let issues = await failures {
            forAll(Int.arbitrary(in: 0...1000), settings: settings) { x in #expect(x < 123) }
        }
        #expect(issues.last?.contains("Counterexample: 123") == true)
    }

    @Test func asyncPropertiesNeedNoTrait() async {
        var settings = Settings.defaults
        settings.database = nil
        let issues = await failures {
            await forAll(Int.arbitrary(in: 0...1000), settings: settings) { x in
                await Task.yield()
                #expect(x < 123)
            }
        }
        #expect(issues.last?.contains("Counterexample: 123") == true)
    }
}
