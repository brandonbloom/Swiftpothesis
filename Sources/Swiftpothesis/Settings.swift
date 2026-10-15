import Foundation
import Testing

/// Options that control how a property is tested.
///
/// Settings come from, in increasing precedence: the defaults, the `SWIFTPOTHESIS_*` environment
/// variables, `.propertySettings(_:)` traits on enclosing suites and tests, and the
/// `settings` argument of ``forAll(_:id:settings:sourceLocation:isolation:_:)``.
///
/// TODO: Named profiles, such as a `ci` profile with more examples and no deadline, selected by
/// `SWIFTPOTHESIS_PROFILE`.
public struct Settings: Sendable {
    /// The number of valid test cases to try before the property passes.
    public var maxExamples = 100

    /// The seed for the run's random choices. Nil chooses a fresh seed each run, which is reported
    /// with any failure.
    public var seed: UInt64?

    /// The most test cases to run while shrinking a failure.
    public var maxShrinks = 1000

    /// The longest one test case may take before it fails. Nil disables the deadline.
    ///
    /// A test case that runs past its deadline is cancelled and fails, and shrinking looks for the
    /// smallest input that's still slow: often an accidentally quadratic algorithm or an unbounded
    /// loop. Cancellation is cooperative, so a property that never suspends or checks for
    /// cancellation runs to completion first, and is then reported as late. To guard against hangs,
    /// also use Swift Testing's `.timeLimit(_:)` trait.
    ///
    /// The run's first test case is exempt, since one-time setup often makes it slow. While
    /// shrinking, a test case must exceed the deadline by 25% to count as slow, so timing noise
    /// doesn't steer shrinking. If the shrunk example meets its deadline when replayed, the failure
    /// is reported as flaky.
    public var deadline: Duration? = .seconds(1)

    /// The longest the ``Phase/generate`` phase may take. Nil, the default, means no limit.
    ///
    /// When the time is up, generation stops and the property passes with fewer than
    /// ``maxExamples`` examples. ``PropertyResult/examples`` reports how many ran.
    public var timeLimit: Duration?

    /// Where failing examples are saved and replayed from. Nil disables persistence.
    public var database: (any ExampleDatabase)? = DirectoryDatabase.default

    /// The phases to run.
    public var phases: Set<Phase> = Set(Phase.allCases)

    /// Health checks that don't fail the property when they trip.
    public var suppressedHealthChecks: Set<HealthCheck> = []

    /// Settings with every option at its default, ignoring the environment and traits.
    public static let defaults = Settings()

    /// The settings in effect for the current task: the defaults, overridden by the environment,
    /// overridden by any `.propertySettings(_:)` traits on the running test.
    public static var current: Settings { scoped ?? environment }

    @TaskLocal static var scoped: Settings?

    static let environment: Settings = {
        var settings = Settings()
        let env = ProcessInfo.processInfo.environment
        if let seed = env["SWIFTPOTHESIS_SEED"].flatMap(UInt64.init) { settings.seed = seed }
        if let examples = env["SWIFTPOTHESIS_MAX_EXAMPLES"].flatMap(Int.init) {
            settings.maxExamples = examples
        }
        return settings
    }()
}

/// A stage of testing a property.
public enum Phase: Sendable, CaseIterable {
    /// Replays examples saved in the ``Settings/database`` by earlier failing runs.
    case reuse
    /// Generates new random examples.
    case generate
    /// Steers generation toward examples that maximize ``target(_:label:)`` scores.
    case target
    /// Simplifies a failing example.
    case shrink
    /// Reports which parts of a shrunk example can vary without the property passing.
    case explain
}

/// A check that the property is being tested effectively, independent of whether it passes.
public enum HealthCheck: Sendable, CaseIterable {
    /// Most test cases were discarded by filters or assumptions.
    case filterTooMuch
    /// Generating test cases took most of the run's time.
    case tooSlow
    /// Test cases routinely exceeded the engine's limit on choices.
    case dataTooLarge
}

// MARK: - Traits

/// A trait that adjusts ``Settings`` for the properties in a test or suite.
public struct PropertySettingsTrait: TestTrait, SuiteTrait, TestScoping {
    let transform: @Sendable (inout Settings) -> Void

    public var isRecursive: Bool { true }

    public func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        var settings = Settings.current
        transform(&settings)
        try await Settings.$scoped.withValue(settings) { try await function() }
    }
}

extension Trait where Self == PropertySettingsTrait {
    /// Adjusts the ``Settings`` of every property in a test or suite.
    ///
    /// ```swift
    /// @Test(.propertySettings { $0.maxExamples = 1000 })
    /// func roundTrip() async { … }
    /// ```
    public static func propertySettings(
        _ transform: @escaping @Sendable (inout Settings) -> Void
    ) -> Self {
        PropertySettingsTrait(transform: transform)
    }
}
