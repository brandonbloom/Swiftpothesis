# Testing Concurrent Code

Find races in tasks and actors, and reproduce them exactly.

## Overview

Swiftpothesis runs every test case on one thread, under its own executor. Whenever more than one task or actor job is ready to run, which one runs next is a choice drawn from the test case, like any generated value. So interleavings are inputs: a property is tested under many of them, a failing one shrinks toward the simplest order, and the failure replays exactly.

```swift
@Test func incrementsAreNeverLost() async {
    await forAll { (_: Bool) in
        let counter = Counter()  // An actor whose increment() reads, awaits, then writes.
        await withTaskGroup(of: Void.self) { group in
            group.addTask(name: "a") { await counter.increment() }
            group.addTask(name: "b") { await counter.increment() }
        }
        #expect(await counter.value == 2)
    }
}
```

The failure report lists which task ran at each choice, by name where tasks have one:

```
Interleaving: a → b → a → b
```

Nothing needs wrapping or annotating. Nonisolated async code, child tasks, and default actors all run under Swiftpothesis's executor.

## Time

Every test case has a virtual clock, ``TestCase/clock``, which conforms to the standard library's `Clock` protocol. Pass it to code that sleeps, takes timeouts, or retries, as `some Clock<Duration>`:

```swift
await forAll { test in
    let client = Client(clock: test.clock)  // Client is generic over Clock.
    …
}
```

Sleeping on it takes no real time: when every task is waiting, the clock jumps to the earliest deadline. So an hour of retries runs instantly, in a reproducible order.

## What escapes control

Some code runs outside Swiftpothesis's executor: `@MainActor` code, actors with custom executors, Dispatch queues, real clocks such as `ContinuousClock`, and completions from I/O. It still runs correctly, but its timing isn't reproducible. When a failure involved escaped work, its report says so.

## Opting out

Because everything runs on one thread, code that blocks a thread waiting for another task, such as with `DispatchSemaphore`, deadlocks. Tests of thread safety that need real parallelism, or Thread Sanitizer, and CPU-heavy parallel properties also need real threads. For these, use Swift's own executors:

```swift
@Test(.propertyOverrides { $0.scheduling = .system })
func lockFreeQueueIsThreadSafe() async { … }
```

## Topics

- ``Scheduling``
- ``Settings/scheduling``
- ``TestCase/clock``
- ``VirtualClock``
