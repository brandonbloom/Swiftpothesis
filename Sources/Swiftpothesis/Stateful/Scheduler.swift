/// SPIKE: controls the interleaving of concurrent code, so races become generated, shrinkable,
/// and reproducible inputs.
///
/// Code inside ``run(_:)`` runs on one thread under a controlled executor. Every time more than
/// one job is ready, such as two child tasks or an actor's queued calls, which runs next is a
/// choice drawn from the test case. Failing interleavings shrink toward running jobs in the
/// order they became ready.
///
/// ```swift
/// await forAll { test in
///     let scheduler = Scheduler(test)
///     let count = await scheduler.run {
///         let counter = Counter()
///         async let a: Void = counter.increment()
///         async let b: Void = counter.increment()
///         _ = await (a, b)
///         return await counter.value
///     }
///     #expect(count == 2)
/// }
/// ```
public final class Scheduler: Sendable {
    let testCase: TestCase
    let executor: ControlledExecutor

    /// A clock whose time advances only when nothing else can run. Pass it to the code under
    /// test as `some Clock<Duration>`.
    public let clock: VirtualClock

    /// Creates a scheduler that chooses interleavings from a running test case.
    public init(_ testCase: TestCase) {
        self.testCase = testCase
        let clock = VirtualClock()
        self.clock = clock
        executor = ControlledExecutor(
            choose: { count in Int((try? testCase.choose(atMost: UInt64(count - 1))) ?? 0) },
            idle: { clock.advance() })
    }

    /// Runs `body` under the scheduler's control.
    public func run<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        executor.start()
        defer { executor.stop() }
        return try await withTaskExecutorPreference(executor, isolation: nil) { try await body() }
    }

    /// How many jobs arrived from outside the scheduler's control. Nonzero means the run may
    /// not be reproducible.
    var escapedJobs: Int { executor.foreignEnqueues }

    /// How many times the scheduler chose among several ready jobs.
    var choicePoints: Int { executor.choicePoints }
}
