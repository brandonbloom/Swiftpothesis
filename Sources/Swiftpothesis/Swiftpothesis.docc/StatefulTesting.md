# Stateful Testing

Test a system under generated sequences of commands.

## Overview

Some bugs need a particular sequence of operations, not a particular value. A state machine describes the commands a system supports. Swiftpothesis generates sequences of them, runs them, and shrinks any failing sequence to the fewest, simplest commands.

You may not need a state machine. If the operations don't depend on each other's results, a property over an array of commands is simpler.

Swiftpothesis offers two kinds of state machine. They aren't a hierarchy: each allows something the other doesn't.

| | ``SequentialMachine`` | ``LinearizableMachine`` |
| --- | --- | --- |
| State | One value: the system, plus any model or replicas | A separate model and system |
| Commands generated from | The whole state, including the real system | The model |
| Each command | Performed and checked in one step, with `#expect` | Applied, predicted, and judged in separate steps |
| Checks concurrent runs | No | Yes |
| Runs sequentially | ``check(_:examples:steps:averageSteps:id:settings:sourceLocation:isolation:)`` | Through ``LinearizableMachine/sequential`` |

## Sequential machines

A sequential machine keeps everything in one state value, generates commands from it, and checks each command as it runs:

```swift
struct StackMachine: SequentialMachine {
    enum Command: CustomStringConvertible, Sendable {
        case push(Int), pop
        var description: String { … }
    }

    func makeState() -> (model: [Int], stack: BoundedStack) {
        ([], BoundedStack(capacity: 3))
    }

    func commands(for state: (model: [Int], stack: BoundedStack)) -> some Generator<Command> {
        oneOf(Int.arbitrary(in: 0...9).map(Command.push), constant(.pop))
    }

    func run(_ command: Command, state: inout (model: [Int], stack: BoundedStack)) async throws {
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
(finish)
```

The state needn't include a model. To test replicas against each other, keep them all in the state, generate commands that edit, sync, or crash them, and check in ``SequentialMachine/finish(state:)`` that they converged.

Some bugs need long histories. Raise `averageSteps` to find them, at the cost of slower test cases.

Keep a shrunk failure as a regression test by passing its commands as a named example, which runs before anything is generated:

```swift
await check(StackMachine(), examples: [
    "overflow": [.push(0), .push(0), .push(0), .push(1), .pop],
])
```

## Linearizable machines

A linearizable machine separates performing a command from predicting and judging it, so the engine can run commands concurrently and then search for a sequential order that explains every response. Postconditions are pure functions rather than `#expect`, because that search evaluates them for many candidate orders.

This machine models a counter with an integer. The actor's `increment` suspends between reading and writing its value, so two concurrent increments can both return 1:

```swift
actor Counter {
    var value = 0
    func increment() async -> Int {
        let read = value
        await Task.yield()  // Stands in for async work; another increment can run here.
        value = read + 1
        return value
    }
    func read() -> Int { value }
}

struct CounterMachine: LinearizableMachine {
    enum Command: CustomStringConvertible, Sendable {
        case increment, read
        var description: String { self == .increment ? "increment()" : "read()" }
    }

    func makeModel() -> Int { 0 }
    func makeSystem() -> Counter { Counter() }

    func commands(for model: Int) -> some Generator<Command> {
        element(of: [Command.increment, .read])
    }

    func apply(_ command: Command, to counter: Counter) async -> Int {
        switch command {
        case .increment: await counter.increment()
        case .read: await counter.read()
        }
    }

    func next(_ model: Int, after command: Command, response: Int) -> Int {
        command == .increment ? model + 1 : model
    }

    func postcondition(_ model: Int, command: Command, response: Int) -> Bool {
        command == .increment ? response == model + 1 : response == model
    }
}

@Test func counterIsLinearizable() async {
    await checkLinearizability(CounterMachine())
}
```

``checkLinearizability(_:steps:averageSteps:branches:branchSteps:id:settings:sourceLocation:isolation:)`` runs a short prefix of commands, then increments and reads in two concurrent branches. It finds responses that no order of them explains, and shrinks to the smallest race:

```
Not linearizable: no sequential order of the concurrent commands explains their responses.
Property falsified after 1 examples.
  Counterexample:
  Branch 1: increment() → 1
  Branch 2: increment() → 1
  Interleaving: branch 1 → branch 2 → …
```

Under ``Scheduling/deterministic`` scheduling, the interleaving is drawn from the test case like the commands, so it shrinks and replays too. Keep branches short: checking considers every interleaving of them.

A linearizable machine also runs one command at a time, checking each postcondition as it goes:

```swift
await check(CounterMachine().sequential)
```

## Topics

- ``SequentialMachine``
- ``check(_:examples:steps:averageSteps:id:settings:sourceLocation:isolation:)``
- ``LinearizableMachine``
- ``SequentialAdapter``
- ``checkLinearizability(_:steps:averageSteps:branches:branchSteps:id:settings:sourceLocation:isolation:)``
