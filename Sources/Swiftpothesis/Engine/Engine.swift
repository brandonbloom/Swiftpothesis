import Synchronization
import Testing

/// Runs one test case: draws values from the source, describes them in the context, and checks
/// the property. Stateful tests interleave drawing and checking.
typealias TestFunction = (inout Source, PropertyContext) async throws -> Void

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
    var description: String
    var notes: [String]

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
    var notes: [String] = []
    var labels: Set<String> = []
    var targets: [String: Double] = [:]

    @TaskLocal static var current: PropertyContext?
}

/// Runs the phases of testing one property and reports the result through Swift Testing.
struct Engine {
    let settings: Settings
    let sourceLocation: SourceLocation

    // Gives up when this many test cases in a row are discarded.
    private var maxConsecutiveDiscards: Int { settings.maxExamples * 10 }

    /// The key under which this property's failures are saved: the running test's ID, or the
    /// call site outside a test.
    private var databaseKey: String {
        let test = Test.current.map { "\($0.id)" } ?? ""
        return "\(test)|\(sourceLocation.fileID):\(sourceLocation.line)"
    }

    func run(isolation: isolated (any Actor)?, _ test: TestFunction) async {
        let seed = settings.seed ?? UInt64.random(in: .min ... .max)
        var found: (choices: [UInt64], failure: Failure)?
        var examples = 0

        if settings.phases.contains(.reuse), let database = settings.database {
            for saved in database.fetch(databaseKey) where found == nil {
                var source = Source(prefix: saved.choices, random: nil)
                if case .failed(let failure) = await execute(&source, test, isolation: isolation) {
                    found = (source.choices, failure)
                } else {
                    database.delete(saved, for: databaseKey)
                }
            }
        }

        if found == nil, settings.phases.contains(.generate) {
            var random = Xoshiro256(seed: seed)
            var discards = 0
            while examples < settings.maxExamples, discards < maxConsecutiveDiscards {
                var source = Source(random: random)
                let outcome = await execute(&source, test, isolation: isolation)
                random = source.random!
                switch outcome {
                case .passed:
                    examples += 1
                    discards = 0
                case .discarded:
                    discards += 1
                case .failed(let failure):
                    found = (source.choices, failure)
                }
                if found != nil { break }
            }
            if found == nil, discards >= maxConsecutiveDiscards,
                !settings.suppressedHealthChecks.contains(.filterTooMuch)
            {
                Issue.record(
                    "Health check failed: \(discards) test cases in a row were discarded by filters or assumptions. Generate valid values directly, or suppress HealthCheck.filterTooMuch.",
                    sourceLocation: sourceLocation)
                return
            }
        }

        guard var (choices, failure) = found else { return }

        if settings.phases.contains(.shrink) {
            var shrinker = Shrinker(choices: choices, failure: failure, budget: settings.maxShrinks)
            (choices, failure) = await shrinker.shrink { candidate in
                var source = Source(prefix: candidate, random: nil)
                guard case .failed(let f) = await execute(&source, test, isolation: isolation)
                else { return nil }
                return (source.choices, f)
            }
        }

        settings.database?.save(ChoiceSequence(choices), for: databaseKey)
        await report(choices, failure, seed: seed, examples: examples, test, isolation: isolation)
    }

    /// Runs one test case, holding back the issues it records.
    private func execute(
        _ source: inout Source, _ test: TestFunction, isolation: isolated (any Actor)?
    ) async -> Outcome {
        let context = PropertyContext()
        var drawn = source
        let captured = await withIssuesCaptured(isolation: isolation) {
            try await PropertyContext.$current.withValue(context) {
                try await test(&drawn, context)
            }
        }
        source = drawn
        if let rejection = captured.error as? Rejection { return .discarded(rejection) }
        if captured.issues.isEmpty, captured.error == nil { return .passed }
        return .failed(
            Failure(
                issues: captured.issues, error: captured.error, description: context.description,
                notes: context.notes))
    }

    /// Replays the shrunk failure with its issues recorded, then summarizes it.
    private func report(
        _ choices: [UInt64], _ failure: Failure, seed: UInt64, examples: Int,
        _ test: TestFunction, isolation: isolated (any Actor)?
    ) async {
        var source = Source(prefix: choices, random: nil)
        let context = PropertyContext()
        do {
            try await PropertyContext.$current.withValue(context) {
                try await test(&source, context)
            }
        } catch is Rejection {
            Issue.record(
                "Flaky: the shrunk example was discarded when replayed.",
                sourceLocation: sourceLocation)
        } catch {
            Issue.record(error, sourceLocation: sourceLocation)
        }
        var lines = [
            "Property falsified after \(examples + 1) examples.",
            "Counterexample: \(context.description)",
        ]
        lines += context.notes.map { "Note: \($0)" }
        lines.append("Choices: [\(ChoiceSequence(choices))]")
        lines.append(
            "Reproduce with SWIFTPOTHESIS_SEED=\(seed), or rerun to replay it from the database.")
        Issue.record(
            Comment(rawValue: lines.joined(separator: "\n")), sourceLocation: sourceLocation)
    }
}
