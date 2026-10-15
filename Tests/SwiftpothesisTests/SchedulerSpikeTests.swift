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

/// Records which thread an actor's methods run on.
actor Probe {
    func threadName() -> String? { Thread.current.name }
}

@Suite(.propertySettings { $0.database = nil })
struct SchedulerSpikeTests {
    /// Risk 1: do default actors run on the controlled executor?
    @Test func defaultActorsRunOnTheControlledExecutor() async {
        await forAll { test in
            let scheduler = Scheduler(test)
            let names = await scheduler.run {
                let probe = Probe()
                async let child = probe.threadName()
                return (await probe.threadName(), await child, currentThreadName())
            }
            #expect(names.0 == ControlledExecutor.threadName)
            #expect(names.1 == ControlledExecutor.threadName)
            #expect(names.2 == ControlledExecutor.threadName)
            #expect(scheduler.escapedJobs == 0)
        }
    }

    /// Risk 4: is a race found and shrunk?
    @Test func findsAndShrinksALostUpdate() async {
        let issues = await failures {
            await forAll { test in
                let scheduler = Scheduler(test)
                let (value, log) = await scheduler.run {
                    let counter = Counter()
                    async let a: Void = counter.increment("a")
                    async let b: Void = counter.increment("b")
                    _ = await (a, b)
                    return (await counter.value, await counter.log)
                }
                note(log.joined(separator: ", "))
                #expect(value == 2)
            }
        }
        let summary = issues.last ?? ""
        #expect(summary.contains("Property falsified"))
        #expect(!summary.contains("Flaky"))
    }

    /// Risk 2: do the same choices give the same interleaving?
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

    /// Risk 3: does virtual time order sleeps without waiting in real time?
    @Test func virtualTimeOrdersSleepsInstantly() async throws {
        let testCase = TestCase(Source(random: Xoshiro256(seed: 1)))
        let scheduler = Scheduler(testCase)
        let clock = scheduler.clock
        let start = ContinuousClock.now
        let order = await scheduler.run {
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
            return log.withLock { $0 }
        }
        _ = testCase.close()
        #expect(order == ["fast", "slow"])
        #expect(clock.now.offset == .seconds(3600))
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    /// Code generic over `Clock` runs on the virtual clock without knowing about Swiftpothesis.
    @Test func codeTakesAnyClock() async {
        let testCase = TestCase(Source(random: Xoshiro256(seed: 1)))
        let scheduler = Scheduler(testCase)
        let clock = scheduler.clock
        let tried = await scheduler.run { await retry(clock: clock, attempts: 5) }
        _ = testCase.close()
        #expect(tried == 5)
        #expect(clock.now.offset == .seconds(150))
    }

    /// Escaping work is detected rather than silently nondeterministic.
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
}
