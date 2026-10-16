/// Runs a test case's code under a controlled executor, so interleavings become generated,
/// shrinkable, and reproducible inputs. See ``Settings/scheduling``.
final class Scheduler: Sendable {
    let executor: ControlledExecutor
    let clock: VirtualClock

    init(_ testCase: TestCase) {
        let clock = testCase.clock
        self.clock = clock
        executor = ControlledExecutor(
            choose: { count in Int((try? testCase.choose(atMost: UInt64(count - 1))) ?? 0) },
            idle: { clock.advance() })
    }

    /// Runs `body` on the controlled executor.
    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        clock.setDriven(true)
        executor.start()
        defer {
            executor.stop()
            clock.setDriven(false)
        }
        return try await withTaskExecutorPreference(executor, isolation: nil) { try await body() }
    }

    /// How many jobs arrived from outside the scheduler's control.
    var escapedJobs: Int { executor.foreignEnqueues }

    /// How many times the scheduler chose among several ready jobs.
    var choicePoints: Int { executor.choicePoints }

    /// The task chosen at each choice point, for failure reports.
    var interleaving: [String] { executor.interleaving }
}
