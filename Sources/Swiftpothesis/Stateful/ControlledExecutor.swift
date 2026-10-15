import Foundation

/// A task executor that runs every job on one thread, choosing which ready job runs next.
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
    private var ready: [(job: UnownedJob, task: Int?)] = []
    // The task whose job is running, and the names tasks reported while running.
    private var runningTask: Int?
    private var taskNames: [Int: String] = [:]
    // The task chosen at each choice point, in order.
    private var chosenTasks: [Int?] = []
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
        let task = Self.taskID(job.description)
        let job = UnownedJob(job)
        // Jobs expose their task's ID but not its name, so learn names from tasks that enqueue
        // work while they run, when `Task.name` is theirs.
        let name = Thread.current === thread ? Task.name : nil
        condition.lock()
        if started, Thread.current !== thread { foreignEnqueues += 1 }
        if let name, let runningTask { taskNames[runningTask] = name }
        ready.append((job, task))
        condition.signal()
        condition.unlock()
    }

    /// The tasks chosen at each choice point, by name where a task reported one, and otherwise
    /// numbered in order of appearance, so labels are stable across replays.
    var interleaving: [String] {
        condition.lock()
        defer { condition.unlock() }
        var numbers: [Int: Int] = [:]
        return chosenTasks.map { task in
            guard let task else { return "job" }
            if let name = taskNames[task] { return name }
            if numbers[task] == nil { numbers[task] = numbers.count + 1 }
            return "task \(numbers[task]!)"
        }
    }

    /// The task ID in an `ExecutorJob` description such as `ExecutorJob(id: 67)`.
    private static func taskID(_ description: String) -> Int? {
        guard let range = description.range(of: "id: ") else { return nil }
        return Int(description[range.upperBound...].prefix { $0.isNumber })
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
            if ready.count > 1 { chosenTasks.append(ready[index].task) }
            let (job, task) = ready.remove(at: index)
            started = true
            runningTask = task
            condition.unlock()
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
    }
}

/// A clock whose time passes only when nothing else can run.
///
/// Every test case has one, ``TestCase/clock``. Pass it to the code under test as
/// `some Clock<Duration>`, the standard library's protocol, so that code needn't know about
/// Swiftpothesis. Sleeping on it takes no real time: when every task is waiting, the clock jumps
/// to the earliest deadline and wakes its sleepers, so timeouts and retries are fast and
/// deterministic. With ``Settings/scheduling`` set to ``Scheduling/system``, nothing waits for
/// the other tasks, so each sleep advances the clock and returns at once.
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
        /// Whether a controlled executor advances the clock. Otherwise sleeps return at once.
        var isDriven = false
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
            if !state.isDriven, deadline > state.now { state.now = deadline }
            if deadline <= state.now {
                state.lock.unlock()
                continuation.resume()
            } else {
                state.waiters.append((deadline, continuation))
                state.lock.unlock()
            }
        }
    }

    /// Sets whether a controlled executor advances the clock.
    func setDriven(_ isDriven: Bool) {
        state.lock.lock()
        state.isDriven = isDriven
        state.lock.unlock()
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
