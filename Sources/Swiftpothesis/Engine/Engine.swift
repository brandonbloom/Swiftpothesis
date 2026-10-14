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

    /// Where the failure showed itself, for reports: the first issue's source location, or the
    /// thrown error's type.
    ///
    /// Shrinking doesn't require candidates to fail at the same origin. Different origins don't
    /// prove different bugs, nor the same origin the same bug, and a smaller failing input is the
    /// more useful report either way. See ``Shrinker``.
    var origin: String {
        if error is DeadlineExceeded { return "the deadline" }
        if let location = issues.first?.sourceLocation {
            return "\(location.fileName):\(location.line)"
        }
        if let error { return "a thrown \(type(of: error))" }
        return "an unknown location"
    }
}

/// The error for a test case that ran past ``Settings/deadline``.
struct DeadlineExceeded: Error, CustomStringConvertible {
    var elapsed: Duration
    var deadline: Duration

    var description: String {
        "Deadline exceeded: the test case took \(format(elapsed)), and the deadline is \(format(deadline))."
    }
}

/// A duration in milliseconds, for reports.
func format(_ duration: Duration) -> String {
    let milliseconds =
        Double(duration.components.seconds) * 1000
        + Double(duration.components.attoseconds) / 1e15
    return "\(Int(milliseconds.rounded())) ms"
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
    /// The failure first found, before shrinking.
    private(set) var original: (choices: [UInt64], failure: Failure)?
    /// Failing examples that shrinking left behind when it moved to a failure at another origin.
    private(set) var leftBehind: [(choices: [UInt64], failure: Failure)] = []
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
                leftBehind = shrinker.leftBehind
                state = .done
            case .done:
                // Save examples that may fail differently, too, so a rare bug that shrinking moved
                // away from fails again on the next run rather than waiting to be rediscovered.
                if let found {
                    for example in [found] + leftBehind {
                        settings.database?.save(ChoiceSequence(example.choices), for: databaseKey)
                    }
                }
                return nil
            }
        }
    }

    /// Whether the driver is shrinking a failure.
    var isShrinking: Bool {
        if case .shrink = state { true } else { false }
    }

    /// Whether the driver is generating new test cases.
    var isGenerating: Bool {
        if case .generate = state { true } else { false }
    }

    /// Ends the generate phase early, as when ``Settings/timeLimit`` runs out.
    mutating func endGeneration() {
        if isGenerating { state = .done }
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
        original = (choices, failure)
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
        let clock = ContinuousClock()
        let start = clock.now
        var isFirst = true
        while true {
            if let timeLimit = settings.timeLimit, driver.isGenerating,
                clock.now - start > timeLimit
            {
                driver.endGeneration()
            }
            guard let source = driver.next() else { break }
            // The first test case is exempt from the deadline, and shrinking allows a margin.
            let deadline =
                isFirst ? nil : settings.deadline.map { driver.isShrinking ? $0 * 1.25 : $0 }
            isFirst = false
            let context = PropertyContext()
            let testCase = TestCase(source)
            let run = await execute(
                test, testCase, context, deadline: deadline, capturing: true, isolation: isolation)
            driver.record(outcome(run, deadline: deadline), source: testCase.close())
        }
        guard let found = driver.found else { return finish(driver) }
        // Replay the shrunk failure with its issues recorded.
        let context = PropertyContext()
        let testCase = TestCase(Source(prefix: found.choices, random: nil))
        let replay = await execute(
            test, testCase, context, deadline: settings.deadline.map { $0 * 1.25 },
            capturing: false,
            isolation: isolation)
        _ = testCase.close()
        if let late = found.failure.error as? DeadlineExceeded {
            if let deadline = settings.deadline, replay.elapsed > deadline {
                Issue.record(
                    Comment(
                        rawValue: DeadlineExceeded(elapsed: replay.elapsed, deadline: deadline)
                            .description), sourceLocation: sourceLocation)
            } else {
                Issue.record(
                    "Flaky: the test case exceeded its deadline while searching, taking \(format(late.elapsed)), but took \(format(replay.elapsed)) when replayed.",
                    sourceLocation: sourceLocation)
            }
        } else if let error = replay.error {
            recordReplayError(error)
        }
        let required = await withIssuesCaptured(isolation: isolation) { try requireFailure() }
        return finish(driver, context: context, requireError: required.error)
    }

    /// Runs one test case on `isolation`, cancelling it if it runs past `deadline`, and measures
    /// how long it took. When `capturing`, the issues it records are held back and returned.
    private func execute(
        _ test: TestFunction, _ testCase: TestCase, _ context: PropertyContext,
        deadline: Duration?, capturing: Bool, isolation: isolated (any Actor)?
    ) async -> (issues: [Issue], error: (any Error)?, elapsed: Duration, timedOut: Bool) {
        // The closures built here don't outlive this function, which waits for its tasks.
        await withoutActuallyEscaping(test) { test in
            let body = {
                try await PropertyContext.$current.withValue(context) {
                    try await test(testCase, context)
                }
            }
            let clock = ContinuousClock()
            let start = clock.now
            guard let deadline else {
                let result = await run(body, capturing: capturing, isolation: isolation)
                return (result.issues, result.error, clock.now - start, false)
            }
            // Race the test case against a timer, in child tasks so the timer can cancel it. The test
            // case still runs on `isolation`. `body` isn't Sendable, but it's safe to smuggle into the
            // child task: this function waits for the group, so `body` never runs concurrently with
            // its caller.
            nonisolated(unsafe) let unsafeBody = body
            let result = Mutex<(issues: [Issue], error: (any Error)?)>(([], nil))
            let timedOut = Mutex(false)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    let outcome = await self.run(
                        unsafeBody, capturing: capturing, isolation: isolation)
                    result.withLock { $0 = outcome }
                }
                group.addTask {
                    guard (try? await Task.sleep(for: deadline)) != nil else { return }
                    timedOut.withLock { $0 = true }
                }
                await group.next()
                group.cancelAll()
            }
            let (issues, error) = result.withLock { $0 }
            return (issues, error, clock.now - start, timedOut.withLock { $0 })

        }
    }

    private func run(
        _ body: () async throws -> Void, capturing: Bool, isolation: isolated (any Actor)?
    ) async -> (issues: [Issue], error: (any Error)?) {
        if capturing { return await withIssuesCaptured(isolation: isolation, body) }
        do {
            try await body()
            return ([], nil)
        } catch {
            return ([], error)
        }
    }

    private func outcome(
        _ run: (issues: [Issue], error: (any Error)?, elapsed: Duration, timedOut: Bool),
        deadline: Duration?
    ) -> Outcome {
        if let deadline, run.timedOut || run.elapsed > deadline {
            return .failed(
                Failure(
                    issues: [], error: DeadlineExceeded(elapsed: run.elapsed, deadline: deadline)))
        }
        if let rejection = run.error as? Rejection { return .discarded(rejection) }
        if run.issues.isEmpty, run.error == nil { return .passed }
        return .failed(Failure(issues: run.issues, error: run.error))
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
        if let original = driver.original, original.failure.origin != found.failure.origin {
            lines.append(
                "Shrinking moved from a failure at \(original.failure.origin) to one at \(found.failure.origin). An example of the original failure is saved and replays on the next run."
            )
        }
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
