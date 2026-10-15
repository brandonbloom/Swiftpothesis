import Testing

@testable import Swiftpothesis

/// A counter whose `increment` returns the new value.
protocol CounterSystem: Sendable {
    func increment() async -> Int
    func read() async -> Int
}

/// Increments atomically: linearizable.
actor AtomicCounter: CounterSystem {
    var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
    func read() -> Int { value }
}

/// Reads, suspends, then writes: two concurrent increments can both return 1.
actor RacyCounter: CounterSystem {
    var value = 0
    func increment() async -> Int {
        let read = value
        await Task.yield()
        value = read + 1
        return value
    }
    func read() -> Int { value }
}

enum CounterCommand: CustomStringConvertible, Sendable {
    case increment, read
    var description: String { self == .increment ? "increment()" : "read()" }
}

struct CounterMachine<System: CounterSystem>: LinearizableMachine {
    let makeCounter: @Sendable () -> System

    func makeModel() -> Int { 0 }
    func makeSystem() -> System { makeCounter() }
    func commands(for model: Int) -> some Generator<CounterCommand> {
        element(of: [CounterCommand.increment, .read])
    }
    func apply(_ command: CounterCommand, to system: System) async throws -> Int {
        switch command {
        case .increment: await system.increment()
        case .read: await system.read()
        }
    }
    func next(_ model: Int, after command: CounterCommand, response: Int) -> Int {
        command == .increment ? model + 1 : model
    }
    func postcondition(_ model: Int, command: CounterCommand, response: Int) -> Bool {
        command == .increment ? response == model + 1 : response == model
    }
}

@Suite(.propertyOverrides { $0.database = nil })
struct LinearizabilityTests {
    @Test func atomicCountersAreLinearizable() async {
        let result = await checkLinearizability(CounterMachine { AtomicCounter() })
        #expect(result.passed)
    }

    @Test func racesAreFoundAndShrunk() async {
        let issues = await failures {
            await checkLinearizability(CounterMachine { RacyCounter() })
        }
        let summary = issues.last ?? ""
        #expect(issues.contains { $0.contains("Not linearizable") })
        // The smallest race: one increment in each branch, both returning 1.
        #expect(summary.contains("Branch 1: increment() → 1"))
        #expect(summary.contains("Branch 2: increment() → 1"))
        #expect(!summary.contains("1. "))
    }

    @Test func sequentialAdapterStillWorks() async {
        let result = await check(CounterMachine { AtomicCounter() }.sequential)
        #expect(result.passed)
    }
}
