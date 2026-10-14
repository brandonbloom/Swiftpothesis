import Synchronization
import Testing

/// Runs one test case: draws values from it, describes them in the context, and checks the
/// property. Drawing and checking may interleave.
typealias TestFunction = (TestCase, PropertyContext) async throws -> Void

/// The result of running one test case.
enum Outcome {
    case passed
    case discarded(Rejection)
    case failed(Failure)
}

/// What went wrong in a failing test case.
struct Failure {
    var issues: [Issue]
    var error: (any Error)?

    /// Identifies the bug, so shrinking doesn't slip from one bug to a different one.
    var signature: String {
        if let location = issues.first?.sourceLocation { return "issue@\(location)" }
        if let error { return "error:\(type(of: error))" }
        return "unknown"
    }
}

/// Per-test-case state that ``note(_:)``, ``label(_:)``, and ``target(_:label:)`` write to.
final class PropertyContext: @unchecked Sendable {
    /// The generated values, as shown in a failure report.
    var description = ""
    /// Every value drawn from the test case, in order.
    var draws: [String] = []
    var notes: [String] = []
    var labels: Set<String> = []
    var targets: [String: Double] = [:]

    @TaskLocal static var current: PropertyContext?
}

/// Decides which choice sequences to run, in which phase, without running any of them.
///
/// The driver is a state machine: ``next()`` proposes a source for the next test case, and
/// ``record(_:source:)`` reports how it went. Keeping it apart from the loop that runs test cases
/// lets another loop reuse it, such as a synchronous one or one that runs test cases in parallel.
struct Driver {
    let settings: Settings
    let databaseKey: String
    let seed: UInt64
    private(set) var examples = 0
    private(set) var found: (choices: [UInt64], failure: Failure)?
    private(set) var healthCheck: String?
    private var state: State

    private enum State {
        case reuse(saved: [ChoiceSequence], index: Int)
        case generate(random: Xoshiro256, discards: Int)
        case shrink(Shrinker)
        case done
    }

    // Gives up when this many test cases in a row are discarded.
    private var maxConsecutiveDiscards: Int { settings.maxExamples * 10 }

    init(settings: Settings, databaseKey: String) {
        self.settings = settings
        self.databaseKey = databaseKey
        seed = settings.seed ?? UInt64.random(in: .min ... .max)
        let saved =
            settings.phases.contains(.reuse) ? settings.database?.fetch(databaseKey) ?? [] : []
        state = .reuse(saved: saved, index: 0)
    }

    /// The source for the next test case, or nil when testing is done.
    mutating func next() -> Source? {
        while true {
            switch state {
            case .reuse(let saved, let index):
                if index < saved.count { return Source(prefix: saved[index].choices, random: nil) }
                state =
                    settings.phases.contains(.generate)
                    ? .generate(random: Xoshiro256(seed: seed), discards: 0) : .done
            case .generate(let random, let discards):
                if examples < settings.maxExamples, discards < maxConsecutiveDiscards {
                    return Source(random: random)
                }
                if discards >= maxConsecutiveDiscards,
                    !settings.suppressedHealthChecks.contains(.filterTooMuch)
                {
                    healthCheck =
                        "Health check failed: \(discards) test cases in a row were discarded by filters or assumptions. Generate valid values directly, or suppress HealthCheck.filterTooMuch."
                }
                state = .done
            case .shrink(var shrinker):
                if let candidate = shrinker.nextCandidate() {
                    state = .shrink(shrinker)
                    return Source(prefix: candidate, random: nil)
                }
                found = (shrinker.choices, shrinker.failure)
                state = .done
            case .done:
                if let found {
                    settings.database?.save(ChoiceSequence(found.choices), for: databaseKey)
                }
                return nil
            }
        }
    }

    /// Records the outcome of the test case run from the last source ``next()`` returned.
    mutating func record(_ outcome: Outcome, source: Source) {
        switch state {
        case .reuse(let saved, let index):
            if case .failed(let failure) = outcome {
                foundFailure(source.choices, failure)
            } else {
                settings.database?.delete(saved[index], for: databaseKey)
                state = .reuse(saved: saved, index: index + 1)
            }
        case .generate(_, let discards):
            let random = source.random!
            switch outcome {
            case .passed:
                examples += 1
                state = .generate(random: random, discards: 0)
            case .discarded:
                state = .generate(random: random, discards: discards + 1)
            case .failed(let failure):
                foundFailure(source.choices, failure)
            }
        case .shrink(var shrinker):
            if case .failed(let failure) = outcome {
                shrinker.record((source.choices, failure))
            } else {
                shrinker.record(nil)
            }
            state = .shrink(shrinker)
        case .done:
            break
        }
    }

    private mutating func foundFailure(_ choices: [UInt64], _ failure: Failure) {
        found = (choices, failure)
        state =
            settings.phases.contains(.shrink)
            ? .shrink(Shrinker(choices: choices, failure: failure, budget: settings.maxShrinks))
            : .done
    }
}

/// Runs the phases of testing one property and reports the result through Swift Testing.
///
/// The ``Driver`` decides what to run; the engine runs test cases with their issues captured, then
/// replays and reports the shrunk failure.
struct Engine {
    let settings: Settings
    let sourceLocation: SourceLocation

    /// The key under which this property's failures are saved: the running test's ID and the
    /// call site.
    private var databaseKey: String {
        let test = Test.current.map { "\($0.id)" } ?? ""
        return "\(test)|\(sourceLocation.fileID):\(sourceLocation.line)"
    }

    func run(isolation: isolated (any Actor)?, _ test: TestFunction) async -> PropertyResult {
        var driver = Driver(settings: settings, databaseKey: databaseKey)
        while let source = driver.next() {
            let context = PropertyContext()
            let testCase = TestCase(source)
            let captured = await withIssuesCaptured(isolation: isolation) {
                try await PropertyContext.$current.withValue(context) {
                    try await test(testCase, context)
                }
            }
            driver.record(outcome(captured), source: testCase.close())
        }
        guard let found = driver.found else { return finish(driver) }
        // Replay the shrunk failure with its issues recorded.
        let context = PropertyContext()
        let testCase = TestCase(Source(prefix: found.choices, random: nil))
        do {
            try await PropertyContext.$current.withValue(context) {
                try await test(testCase, context)
            }
        } catch {
            recordReplayError(error)
        }
        _ = testCase.close()
        let required = await withIssuesCaptured(isolation: isolation) { try requireFailure() }
        return finish(driver, context: context, requireError: required.error)
    }

    private func outcome(_ captured: (issues: [Issue], error: (any Error)?)) -> Outcome {
        if let rejection = captured.error as? Rejection { return .discarded(rejection) }
        if captured.issues.isEmpty, captured.error == nil { return .passed }
        return .failed(Failure(issues: captured.issues, error: captured.error))
    }

    private func recordReplayError(_ error: any Error) {
        if error is Rejection {
            Issue.record(
                "Flaky: the shrunk example was discarded when replayed.",
                sourceLocation: sourceLocation)
        } else if !(error is ExpectationFailedError) {
            // A failed `#require` already recorded its issue.
            Issue.record(error, sourceLocation: sourceLocation)
        }
    }

    /// Fails a `#require`, to obtain the error that `PropertyResult.require()` throws.
    ///
    /// `ExpectationFailedError` has no public initializer, and Swift Testing doesn't report it
    /// again when it ends a test, because `#require` already recorded an issue. Callers run this
    /// with that issue captured, since the summary issue already reports the failure.
    private func requireFailure() throws {
        try #require(Bool(false), "Property falsified", sourceLocation: sourceLocation)
    }

    private func finish(
        _ driver: Driver, context: PropertyContext? = nil, requireError: (any Error)? = nil
    ) -> PropertyResult {
        if let healthCheck = driver.healthCheck {
            Issue.record(Comment(rawValue: healthCheck), sourceLocation: sourceLocation)
        }
        guard let found = driver.found, let context else {
            return PropertyResult(
                examples: driver.examples, seed: driver.seed, falsification: nil,
                requireError: nil)
        }
        let draws = context.draws.enumerated().map { "Draw \($0.offset + 1): \($0.element)" }
        let counterexample =
            context.description.isEmpty ? draws.joined(separator: "\n") : context.description
        let falsification = PropertyResult.Falsification(
            counterexample: counterexample, notes: context.notes,
            choices: ChoiceSequence(found.choices))
        var lines = ["Property falsified after \(driver.examples + 1) examples."]
        lines.append(
            context.description.isEmpty
                ? "Counterexample:\n\(counterexample)" : "Counterexample: \(counterexample)")
        lines += context.notes.map { "Note: \($0)" }
        lines.append("Choices: [\(falsification.choices)]")
        lines.append(
            "Reproduce with SWIFTPOTHESIS_SEED=\(driver.seed), or rerun to replay it from the database."
        )
        Issue.record(
            Comment(rawValue: lines.joined(separator: "\n")), sourceLocation: sourceLocation)
        return PropertyResult(
            examples: driver.examples, seed: driver.seed, falsification: falsification,
            requireError: requireError)
    }
}
