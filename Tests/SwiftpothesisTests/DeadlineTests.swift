import Synchronization
import Testing

@testable import Swiftpothesis

@Suite(.propertyOverrides { $0.database = nil })
struct DeadlineTests {
    // Deadlines here are wide enough for shared CI runners, where scheduling alone can take tens
    // of milliseconds.
    @Test(.propertyOverrides { $0.deadline = .milliseconds(100) })
    func slowExamplesFailAndShrink() async {
        let issues = await failures {
            await forAll(Int.arbitrary(in: 0...500)) { x in
                // Cancellation ends the sleep early, so slow cases cost about the deadline.
                try await Task.sleep(for: .milliseconds(x))
            }
        }
        // The shrunk example is the slow input nearest the deadline, so timing noise sometimes
        // makes its replay fast enough to be reported as flaky instead.
        #expect(issues.contains { $0.contains("Deadline exceeded") || $0.contains("Flaky") })
        let summary = issues.last ?? ""
        #expect(summary.contains("Counterexample:"))
        // Shrinking moves the slow input well below the largest, 500. How far depends on the
        // machine: on a loaded CI runner, scheduling alone can push a 15 ms sleep past the
        // deadline, so there's no reliable lower bound.
        let x = Int(summary.split(separator: "Counterexample: ").last?.prefix { $0.isNumber } ?? "")
        #expect(x.map { (0...150).contains($0) } == true)
    }

    @Test(.propertyOverrides { $0.deadline = .milliseconds(10) })
    func uncancellableLoopsAreReportedAfterTheyFinish() async {
        let issues = await failures {
            await forAll(Bool.arbitrary) { slow in
                guard slow else { return }
                let clock = ContinuousClock()
                let end = clock.now + .milliseconds(30)
                while clock.now < end {}  // Never suspends, so can't be cancelled.
            }
        }
        // Under a loaded machine, even a fast case can run past 10 ms and replay as flaky.
        #expect(issues.contains { $0.contains("Deadline exceeded") || $0.contains("Flaky") })
    }

    @Test(.propertyOverrides { $0.deadline = .milliseconds(100) })
    func fastReplayIsReportedAsFlaky() async {
        let calls = Mutex(0)
        let issues = await failures {
            await forAll(Int.arbitrary(in: 0...9)) { _ in
                // Slow only for the first call after the exempt first one, so shrinking and the
                // replay are fast.
                let call = calls.withLock { count in
                    count += 1
                    return count
                }
                if call == 2 { try await Task.sleep(for: .milliseconds(500)) }
            }
        }
        #expect(issues.contains { $0.contains("Flaky") })
    }

    @Test(
        .propertyOverrides {
            $0.timeLimit = .milliseconds(50)
            $0.maxExamples = 10_000
        })
    func timeLimitEndsGenerationEarly() async {
        let result = await forAll(Bool.arbitrary) { _ in
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(result.passed)
        #expect(result.examples < 10_000)
    }
}
