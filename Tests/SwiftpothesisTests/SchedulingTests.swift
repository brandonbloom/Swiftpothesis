import Dispatch
import Foundation
import Synchronization
import Testing

@testable import Swiftpothesis

/// An actor with a lost-update race: `increment` reads, suspends, then writes.
actor Counter {
    var value = 0
    var log: [String] = []

    func increment(_ name: String) async {
        let read = value
        log.append("\(name) read \(read)")
        await Task.yield()
        value = read + 1
        log.append("\(name) wrote \(read + 1)")
    }
}

/// Records which thread an actor's methods run on.
actor Probe {
    func threadName() -> String? { Thread.current.name }
}

/// The current thread's name. Synchronous, since `Thread.current` is unavailable in async code.
func currentThreadName() -> String? { Thread.current.name }

/// Generic over the standard `Clock` protocol, as code under test would be.
func retry<C: Clock<Duration>>(clock: C, attempts: Int) async -> Int {
    var tried = 0
    for _ in 0..<attempts {
        tried += 1
        try? await clock.sleep(for: .seconds(30))
    }
    return tried
}

@Suite(.propertySettings { $0.database = nil })
struct SchedulingTests {
    @Test func propertiesRunOnTheControlledExecutor() async {
        await forAll(Bool.arbitrary) { _ in
            let probe = Probe()
            async let child = probe.threadName()
            #expect(await probe.threadName() == ControlledExecutor.threadName)
            #expect(await child == ControlledExecutor.threadName)
            #expect(currentThreadName() == ControlledExecutor.threadName)
        }
    }

    @Test func findsAndShrinksALostUpdate() async {
        let issues = await failures {
            await forAll { (_: Bool) in
                let counter = Counter()
                await withTaskGroup(of: Void.self) { group in
                    group.addTask(name: "a") { await counter.increment("a") }
                    group.addTask(name: "b") { await counter.increment("b") }
                }
                let log = await counter.log
                note(log.joined(separator: ", "))
                #expect(await counter.value == 2)
            }
        }
        let summary = issues.last ?? ""
        #expect(summary.contains("Property falsified"))
        #expect(summary.contains("Interleaving: "))
        #expect(summary.contains("a") && summary.contains("b"))
        #expect(!summary.contains("Flaky"))
        #expect(!summary.contains("outside Swiftpothesis's scheduler"))
    }

    @Test func sameChoicesReplayTheSameInterleaving() async {
        func interleaving(_ choices: [UInt64]) async -> [String] {
            let testCase = TestCase(Source(prefix: choices, random: nil))
            let scheduler = Scheduler(testCase)
            let log = await scheduler.run {
                let counter = Counter()
                async let a: Void = counter.increment("a")
                async let b: Void = counter.increment("b")
                async let c: Void = counter.increment("c")
                _ = await (a, b, c)
                return await counter.log
            }
            _ = testCase.close()
            return log
        }
        for choices in [[], [1], [2, 1, 0, 1], [1, 1, 1, 1, 1, 1]] as [[UInt64]] {
            let first = await interleaving(choices)
            for _ in 0..<20 {
                #expect(await interleaving(choices) == first, "choices \(choices)")
            }
        }
        // Different choices reach different interleavings.
        #expect(await interleaving([]) != interleaving([1, 1, 1, 1, 1, 1]))
    }

    @Test func virtualTimeOrdersSleepsInstantly() async {
        let start = ContinuousClock.now
        await forAll { test in
            let clock = test.clock
            let log = Mutex<[String]>([])
            async let slow: Void = {
                try? await clock.sleep(for: .seconds(3600))
                log.withLock { $0.append("slow") }
            }()
            async let fast: Void = {
                try? await clock.sleep(for: .seconds(60))
                log.withLock { $0.append("fast") }
            }()
            _ = await (slow, fast)
            #expect(log.withLock { $0 } == ["fast", "slow"])
            #expect(clock.now.offset == .seconds(3600))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func codeTakesAnyClock() async {
        await forAll { test in
            let attempts = try test.draw(Int.arbitrary(in: 1...5))
            let clock = test.clock
            #expect(await retry(clock: clock, attempts: attempts) == attempts)
            #expect(clock.now.offset == .seconds(30 * attempts))
        }
    }

    @Test func escapedWorkIsDetected() async {
        let testCase = TestCase(Source(random: Xoshiro256(seed: 1)))
        let scheduler = Scheduler(testCase)
        await scheduler.run {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async { continuation.resume() }
            }
        }
        _ = testCase.close()
        #expect(scheduler.escapedJobs > 0)
    }

    @Test(.propertySettings { $0.scheduling = .system })
    func systemSchedulingOptsOut() async {
        await forAll { test in
            #expect(currentThreadName() != ControlledExecutor.threadName)
            // Without a scheduler, sleeps advance the virtual clock and return at once.
            try? await test.clock.sleep(for: .seconds(3600))
            #expect(test.clock.now.offset == .seconds(3600))
        }
    }
}
