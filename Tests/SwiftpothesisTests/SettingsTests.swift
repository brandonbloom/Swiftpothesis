import Synchronization
import Testing

@testable import Swiftpothesis

@Suite(.propertySettings { $0.database = nil })
struct SettingsTests {
    @Test(.propertySettings { $0.derandomize = true })
    func derandomizedRunsRepeat() async {
        func run() async -> PropertyResult {
            // An explicit ID gives both runs the same identity, and so the same seed.
            await forAll(Int.arbitrary, id: "same") { _ in }
        }
        let first = await run()
        let second = await run()
        #expect(first.seed == second.seed)
    }

    @Test func derandomizedSeedsDependOnIdentityAndSalt() {
        var settings = Settings.defaults
        settings.derandomize = true
        let a = Driver(settings: settings, databaseKey: "", seedKey: "a").seed
        let b = Driver(settings: settings, databaseKey: "", seedKey: "b").seed
        settings.seed = 42
        let salted = Driver(settings: settings, databaseKey: "", seedKey: "a").seed
        #expect(a != b)
        #expect(a != salted)
        #expect(Driver(settings: settings, databaseKey: "", seedKey: "a").seed == salted)
    }

    @Test(
        .propertySettings {
            $0.slowWarning = .milliseconds(5)
            $0.maxExamples = 5
        })
    func slowPropertiesWarnOnce() async {
        let warnings = Mutex(0)
        await withKnownIssue(isIntermittent: true) {
            await forAll(Bool.arbitrary) { _ in try await Task.sleep(for: .milliseconds(10)) }
        } matching: { issue in
            if issue.severity == .warning { warnings.withLock { $0 += 1 } }
            return issue.severity == .warning
        }
        #expect(warnings.withLock { $0 } == 1)
    }

    @Test(.propertySettings { $0.maxShrinkAttempts = 2 })
    func runningOutOfShrinkAttemptsIsReported() async {
        let issues = await failures {
            await forAll([Int].arbitrary(Int.arbitrary(in: 0...1000), count: 20...20)) { xs in
                #expect(xs.allSatisfy { $0 < 1 })
            }
        }
        #expect(issues.last?.contains("Shrinking stopped after 2 attempts") == true)
    }
}
