# Stateful Testing

Test a system against a simpler model of it, under generated sequences of commands.

## Overview

Some bugs need a particular sequence of operations, not a particular value. A ``StateMachine`` describes the operations a system supports, as commands, and a model that predicts how the system responds. ``check(_:steps:settings:sourceLocation:isolation:)`` generates command sequences, runs them against the system and the model, and shrinks any failing sequence to the fewest, simplest commands.

You may not need a state machine. If the operations don't depend on each other's results, a property over an array of commands is simpler.

## Define the machine

```swift
struct StackMachine: StateMachine {
    enum Command: CustomStringConvertible {
        case push(Int), pop
        var description: String { … }
    }

    var initialModel: [Int] { [] }
    func makeSystem() -> BoundedStack { BoundedStack(capacity: 3) }

    func commands(for model: [Int]) -> some Generator<Command> {
        .oneOf(Int.arbitrary(in: 0...9).map(Command.push), .constant(.pop))
    }

    func precondition(_ command: Command, model: [Int]) -> Bool {
        if case .pop = command { !model.isEmpty } else { true }
    }

    func run(_ command: Command, model: inout [Int], system: inout BoundedStack) async throws {
        switch command {
        case .push(let x):
            model.append(x)
            system.push(x)
        case .pop:
            #expect(system.pop() == model.popLast())
        }
    }
}

@Test func stackBehavesLikeArray() async {
    await check(StackMachine())
}
```

If `BoundedStack` silently drops pushes past its capacity, the failure report lists the steps:

```
Counterexample:
1. push(0)
2. push(0)
3. push(0)
4. push(1)
5. pop()
```

## Topics

- ``StateMachine``
- ``check(_:steps:settings:sourceLocation:isolation:)``
- ``Scheduler``
