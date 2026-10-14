import Testing

@testable import Swiftpothesis

/// A bounded stack that silently drops pushes past its capacity: a bug only a long enough
/// sequence of commands reveals.
struct LeakyStack {
    var elements: [Int] = []

    mutating func push(_ x: Int) {
        if elements.count < 3 { elements.append(x) }
    }

    mutating func pop() -> Int? {
        elements.popLast()
    }
}

struct StackMachine: StateMachine {
    enum Command: CustomStringConvertible {
        case push(Int)
        case pop

        var description: String {
            switch self {
            case .push(let x): "push(\(x))"
            case .pop: "pop()"
            }
        }
    }

    var initialModel: [Int] { [] }

    func makeSystem() -> LeakyStack { LeakyStack() }

    func commands(for model: [Int]) -> some Generator<Command> {
        .oneOf(Int.arbitrary(in: 0...9).map(Command.push), .constant(.pop))
    }

    func precondition(_ command: Command, model: [Int]) -> Bool {
        if case .pop = command { return !model.isEmpty }
        return true
    }

    func run(_ command: Command, model: inout [Int], system: inout LeakyStack) async throws {
        switch command {
        case .push(let x):
            model.append(x)
            system.push(x)
        case .pop:
            #expect(system.pop() == model.popLast())
        }
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
        #expect(!summary.contains("6. "))
    }
}
