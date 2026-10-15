import Foundation

/// SPIKE: a task executor that runs every job on one thread, choosing which ready job runs next.
///
/// Code run with this executor as its task executor preference queues its jobs here: nonisolated
/// async functions, child tasks, and, per SE-0417, default actors. Jobs run one at a time on the
/// executor's own thread, so everything they enqueue arrives deterministically. When more than
/// one job is ready, `choose` picks which runs next, which makes interleavings a generated,
/// shrinkable input. When no job is ready, the system is quiescent, unless work escaped to
/// another thread; `idle` gets a chance to make progress then, such as by advancing a virtual
/// clock.
final class ControlledExecutor: TaskExecutor, @unchecked Sendable {
    private let condition = NSCondition()
    // Guarded by `condition`.
    private var ready: [UnownedJob] = []
    private var stopped = false
    private var started = false
    private var thread: Thread?

    /// Picks the index of the next job to run, given how many are ready (at least two).
    private let choose: @Sendable (Int) -> Int
    /// Called when no job is ready. Returns whether it made a job ready.
    private let idle: @Sendable () -> Bool

    /// How many jobs arrived from other threads after the first job ran. Nonzero means work
    /// escaped the executor, so runs may not be deterministic.
    private(set) var foreignEnqueues = 0
    /// How many times a job was chosen among several ready ones.
    private(set) var choicePoints = 0

    init(choose: @escaping @Sendable (Int) -> Int, idle: @escaping @Sendable () -> Bool) {
        self.choose = choose
        self.idle = idle
    }

    func start() {
        let thread = Thread { [self] in loop() }
        thread.name = Self.threadName
        self.thread = thread
        thread.start()
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.signal()
        condition.unlock()
    }

    static let threadName = "Swiftpothesis.ControlledExecutor"

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        condition.lock()
        if started, Thread.current !== thread { foreignEnqueues += 1 }
        ready.append(job)
        condition.signal()
        condition.unlock()
    }

    private func loop() {
        while true {
            condition.lock()
            while ready.isEmpty, !stopped {
                condition.unlock()
                let progressed = idle()
                condition.lock()
                if !progressed, ready.isEmpty, !stopped { condition.wait() }
            }
            if stopped, ready.isEmpty {
                condition.unlock()
                return
            }
            var index = 0
            if ready.count > 1 {
                choicePoints += 1
                index = min(choose(ready.count), ready.count - 1)
            }
            let job = ready.remove(at: index)
            started = true
            condition.unlock()
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
    }
}

/// SPIKE: a clock whose time passes only when the controlled executor is otherwise idle.
///
/// Code under test takes `some Clock<Duration>`, the standard library's protocol, so it needn't
/// know about Swiftpothesis.
public struct VirtualClock: Clock, Sendable {
    public struct Instant: InstantProtocol, Sendable {
        public var offset: Duration
        public func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }
        public func duration(to other: Instant) -> Duration { other.offset - offset }
        public static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    final class State: @unchecked Sendable {
        let lock = NSLock()
        var now = Instant(offset: .zero)
        var waiters: [(deadline: Instant, continuation: CheckedContinuation<Void, any Error>)] = []
    }

    let state = State()

    public init() {}

    public var now: Instant {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.now
    }

    public var minimumResolution: Duration { .zero }

    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        // TODO: Cancellation.
        try await withCheckedThrowingContinuation { continuation in
            state.lock.lock()
            if deadline <= state.now {
                state.lock.unlock()
                continuation.resume()
            } else {
                state.waiters.append((deadline, continuation))
                state.lock.unlock()
            }
        }
    }

    /// Advances to the earliest pending deadline and wakes its sleepers. Returns whether any woke.
    func advance() -> Bool {
        state.lock.lock()
        guard let next = state.waiters.map(\.deadline).min() else {
            state.lock.unlock()
            return false
        }
        state.now = next
        // Wake sleepers in the order they slept, for determinism.
        let due = state.waiters.filter { $0.deadline <= next }
        state.waiters.removeAll { $0.deadline <= next }
        state.lock.unlock()
        for waiter in due { waiter.continuation.resume() }
        return true
    }
}
