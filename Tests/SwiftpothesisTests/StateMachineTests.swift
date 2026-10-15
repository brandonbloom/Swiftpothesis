import Synchronization
import Testing

@testable import Swiftpothesis

/// A bounded stack that silently drops pushes past its capacity: a bug only a long enough
/// sequence of commands reveals.
struct LeakyStack: Sendable {
    var elements: [Int] = []

    mutating func push(_ x: Int) {
        if elements.count < 3 { elements.append(x) }
    }

    mutating func pop() -> Int? {
        elements.popLast()
    }
}

enum StackCommand: CustomStringConvertible, Sendable {
    case push(Int)
    case pop

    var description: String {
        switch self {
        case .push(let x): "push(\(x))"
        case .pop: "pop()"
        }
    }
}

struct StackMachine: SequentialMachine {
    func makeState() -> (model: [Int], stack: LeakyStack) { ([], LeakyStack()) }

    func commands(for state: (model: [Int], stack: LeakyStack)) -> some Generator<StackCommand> {
        .oneOf(Int.arbitrary(in: 0...9).map(StackCommand.push), .constant(.pop))
    }

    func run(_ command: StackCommand, state: inout (model: [Int], stack: LeakyStack)) async throws {
        switch command {
        case .push(let x):
            state.model.append(x)
            state.stack.push(x)
        case .pop:
            guard !state.model.isEmpty else { try skip("empty") }
            #expect(state.stack.pop() == state.model.popLast())
        }
    }
}

/// Counts pushes, and checks only at the end that there were fewer than five.
struct FinishMachine: SequentialMachine {
    func makeState() -> Int { 0 }
    func commands(for state: Int) -> some Generator<StackCommand> {
        Int.arbitrary(in: 0...9).map(StackCommand.push)
    }
    func run(_ command: StackCommand, state: inout Int) async throws { state += 1 }
    func finish(state: inout Int) async throws { #expect(state < 5) }
}

/// The same stack as a linearizable machine, run sequentially.
struct LinearizableStack: LinearizableMachine {
    final class Box: Sendable {
        let stack = Mutex(LeakyStack())
    }

    func makeModel() -> [Int] { [] }
    func makeSystem() -> Box { Box() }
    func commands(for model: [Int]) -> some Generator<StackCommand> {
        .oneOf(Int.arbitrary(in: 0...9).map(StackCommand.push), .constant(.pop))
    }
    func precondition(_ command: StackCommand, model: [Int]) -> Bool {
        if case .pop = command { !model.isEmpty } else { true }
    }
    func apply(_ command: StackCommand, to system: Box) async throws -> Int? {
        switch command {
        case .push(let x):
            system.stack.withLock { $0.push(x) }
            return nil
        case .pop:
            return system.stack.withLock { $0.pop() }
        }
    }
    func next(_ model: [Int], after command: StackCommand, response: Int?) -> [Int] {
        switch command {
        case .push(let x): model + [x]
        case .pop: Array(model.dropLast())
        }
    }
    func postcondition(_ model: [Int], command: StackCommand, response: Int?) -> Bool {
        if case .pop = command { response == model.last } else { true }
    }
}

@Suite(.propertySettings { $0.database = nil })
struct StateMachineTests {
    @Test func findsMinimalFailingSequence() async {
        let issues = await failures {
            await check(StackMachine())
        }
        let summary = issues.last ?? ""
        // Four pushes and a pop is the shortest failing sequence. Shrinking usually finds
        // `push(0)` ×3, `push(1)`, `pop()`, but the values it settles on vary by seed.
        #expect(summary.contains("4. push("))
        #expect(summary.contains("5. pop()"))
        #expect(summary.contains("(finish)"))
        #expect(!summary.contains("6. "))
    }

    @Test func finishFailuresShrink() async {
        let issues = await failures {
            await check(FinishMachine())
        }
        let summary = issues.last ?? ""
        #expect(summary.contains("5. push(0)\n(finish)"))
        #expect(!summary.contains("6. "))
    }

    @Test func skippedCommandsAreMarked() async {
        // Every command is skipped, and the check at the end always fails, so the shortest
        // counterexample is one skipped command.
        struct AlwaysSkips: SequentialMachine {
            func makeState() -> Int { 0 }
            func commands(for state: Int) -> some Generator<StackCommand> { .constant(.pop) }
            func run(_ command: StackCommand, state: inout Int) async throws { try skip("empty") }
            func finish(state: inout Int) async throws { #expect(Bool(false)) }
        }
        let issues = await failures {
            await check(AlwaysSkips(), steps: 1...100)
        }
        #expect(issues.last?.contains("1. pop() (skipped: empty)\n(finish)") == true)
    }

    @Test func averageStepsLengthensHistories() async {
        // `Mutex` isn't copyable, so the machine shares it through a class.
        final class Box: Sendable { let lengths = Mutex<[Int]>([]) }
        let box = Box()
        struct Recorder: SequentialMachine {
            let box: Box
            func makeState() -> Int { 0 }
            func commands(for state: Int) -> some Generator<StackCommand> { .constant(.pop) }
            func run(_ command: StackCommand, state: inout Int) async throws { state += 1 }
            func finish(state: inout Int) async throws { box.lengths.withLock { $0.append(state) } }
        }
        await check(Recorder(box: box), steps: 1...200, averageSteps: 40)
        let recorded = box.lengths.withLock { $0 }
        let mean = Double(recorded.reduce(0, +)) / Double(recorded.count)
        #expect((25...60).contains(mean))
    }

    @Test func finishAloneIsTheMinimalCase() async {
        struct NeverConverges: SequentialMachine {
            func makeState() -> Int { 0 }
            func commands(for state: Int) -> some Generator<StackCommand> { .constant(.pop) }
            func run(_ command: StackCommand, state: inout Int) async throws {}
            func finish(state: inout Int) async throws { #expect(Bool(false)) }
        }
        let issues = await failures {
            await check(NeverConverges())
        }
        #expect(issues.last?.contains("Counterexample: \n(finish)") == true)
    }

    @Test func commandGeneratorsCanThrow() async {
        struct BrokenListing: SequentialMachine {
            struct ListingFailed: Error {}
            func makeState() -> Int { 0 }
            func commands(for state: Int) throws -> Generators.Constant<StackCommand> {
                throw ListingFailed()
            }
            func run(_ command: StackCommand, state: inout Int) async throws {}
        }
        let issues = await failures {
            await check(BrokenListing(), steps: 1...10)
        }
        #expect(issues.contains { $0.contains("ListingFailed") })
    }

    @Test func namedExamplesRunFirstAsGiven() async {
        let issues = await failures {
            await check(
                StackMachine(),
                examples: [
                    "fine": [.push(1), .pop],
                    "overflow": [.push(0), .push(0), .push(0), .push(1), .pop],
                ])
        }
        let summary = issues.last ?? ""
        #expect(summary.contains("Explicit example \"overflow\" failed."))
        #expect(summary.contains("4. push(1)\n5. pop()\n(finish)"))
    }

    @Test func linearizableMachinesRunSequentially() async {
        let issues = await failures {
            await check(LinearizableStack().sequential)
        }
        #expect(issues.last?.contains("5. pop()") == true)
    }
}
