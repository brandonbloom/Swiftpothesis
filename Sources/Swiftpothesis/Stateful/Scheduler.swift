/// Controls the order in which concurrent operations complete, so that races become generated,
/// shrinkable, and reproducible inputs.
///
/// Wrap the asynchronous boundaries of the code under test, such as network responses or
/// callbacks, with ``schedule(_:_:)``. Each scheduled operation waits until the scheduler releases
/// it, and the scheduler releases waiting operations in an order drawn from the test case. A
/// failing interleaving shrinks like any other value, toward releasing operations in the order
/// they were scheduled.
///
/// ```swift
/// await forAll(.scheduler()) { scheduler in
///     let pool = SimulatorPool(boot: { id in await scheduler.schedule("boot \(id)") { … } })
///     async let results = pool.run(jobs)
///     await scheduler.releaseAll()
///     #expect(Set(await results) == Set(jobs))
/// }
/// ```
///
/// This API follows fast-check's `fc.scheduler()`.
///
/// TODO: Design and implement. JavaScript's scheduler knows when every task has reached a
/// scheduling point because it can drain the microtask queue; Swift concurrency has no equivalent,
/// so ``releaseAll()`` needs another way to detect quiescence, such as a custom task executor.
public final class Scheduler: Sendable {
    init() {}

    /// Runs `operation` once the scheduler releases it, and returns its result.
    public func schedule<T: Sendable>(
        _ label: String, _ operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        fatalError("Scheduler is not implemented yet")
    }

    /// Releases scheduled operations, in a generated order, until none are waiting.
    public func releaseAll() async {
        fatalError("Scheduler is not implemented yet")
    }

    /// The labels of released operations, in release order, for failure reports.
    public var history: [String] {
        fatalError("Scheduler is not implemented yet")
    }
}

extension Generator {
    /// A ``Scheduler`` that orders concurrent operations by drawing from the test case.
    public static func scheduler() -> Self where Self == Generators.Schedulers {
        Generators.Schedulers()
    }
}

extension Generators {
    /// A generator of schedulers. See ``Generator/scheduler()``.
    public struct Schedulers: Generator {
        public func generate(from source: inout Source) throws(Rejection) -> Scheduler {
            Scheduler()
        }
    }
}
