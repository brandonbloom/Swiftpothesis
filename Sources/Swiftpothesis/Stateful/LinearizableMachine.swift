import Testing

/// A model of a system precise enough to check concurrent runs for linearizability.
///
/// Unlike a ``SequentialMachine``, which performs and checks each command in one step, a
/// linearizable machine separates performing a command on the system (``apply(_:to:)``) from
/// predicting it with a model (``next(_:after:response:)``) and judging the result
/// (``postcondition(_:command:response:)``). That separation lets the engine run commands
/// concurrently, then search for a sequential order of them that the model explains, which finds
/// races in actors and other concurrent systems. The approach follows Quviq QuickCheck, PropEr,
/// and Hedgehog's parallel state machines.
///
/// This machine models a counter with an integer. The actor's `increment` suspends between
/// reading and writing its value, so two concurrent increments can both return 1:
///
/// ```swift
/// actor Counter {
///     var value = 0
///     func increment() async -> Int {
///         let read = value
///         await Task.yield()  // Stands in for async work; another increment can run here.
///         value = read + 1
///         return value
///     }
///     func read() -> Int { value }
/// }
///
/// struct CounterMachine: LinearizableMachine {
///     enum Command: CustomStringConvertible, Sendable {
///         case increment, read
///         var description: String { self == .increment ? "increment()" : "read()" }
///     }
///
///     func makeModel() -> Int { 0 }
///     func makeSystem() -> Counter { Counter() }
///
///     func commands(for model: Int) -> some Generator<Command> {
///         element(of: [Command.increment, .read])
///     }
///
///     func apply(_ command: Command, to counter: Counter) async -> Int {
///         switch command {
///         case .increment: await counter.increment()
///         case .read: await counter.read()
///         }
///     }
///
///     func next(_ model: Int, after command: Command, response: Int) -> Int {
///         command == .increment ? model + 1 : model
///     }
///
///     func postcondition(_ model: Int, command: Command, response: Int) -> Bool {
///         command == .increment ? response == model + 1 : response == model
///     }
/// }
///
/// @Test func counterIsLinearizable() async {
///     await checkLinearizability(CounterMachine())
/// }
/// ```
///
/// The check runs increments and reads in two concurrent branches, finds responses that no order
/// of them explains, and shrinks to the smallest race:
///
/// ```
/// Not linearizable: no sequential order of the concurrent commands explains their responses.
/// Property falsified after 1 examples.
///   Counterexample:
///   Branch 1: increment() → 1
///   Branch 2: increment() → 1
///   Interleaving: branch 1 → branch 2 → …
/// ```
///
/// Check concurrent runs with
/// ``checkLinearizability(_:steps:averageSteps:branches:branchSteps:id:settings:sourceLocation:isolation:)``.
/// A linearizable machine also runs sequentially, through ``sequential``.
public protocol LinearizableMachine: Sendable {
    /// The abstract state that predicts the system's behavior.
    associatedtype Model: Sendable

    /// The system under test, shared by concurrently running commands.
    associatedtype System: Sendable

    /// An operation on the system.
    associatedtype Command: CustomStringConvertible & Sendable

    /// What performing a command on the system returns.
    associatedtype Response: Sendable

    /// The type of generator for commands.
    associatedtype Commands: Generator<Command>

    /// The model's state before any commands run.
    func makeModel() async throws -> Model

    /// Creates a fresh system for one test case.
    func makeSystem() async throws -> System

    /// The commands that may run next, given the model's state.
    func commands(for model: Model) -> Commands

    /// Whether a command may run in the model's state. Defaults to `true`.
    ///
    /// Shrinking and reordering can move a command to a state where it doesn't apply; commands
    /// whose precondition fails are skipped.
    func precondition(_ command: Command, model: Model) -> Bool

    /// Performs a command on the system, returning its response. It mustn't check anything.
    func apply(_ command: Command, to system: System) async throws -> Response

    /// The model's state after a command produced a response.
    func next(_ model: Model, after command: Command, response: Response) -> Model

    /// Whether a response is correct for a command in the model's state.
    ///
    /// This must be a pure function rather than use `#expect`: checking linearizability evaluates
    /// it for many candidate orders, most of which are expected not to fit.
    func postcondition(_ model: Model, command: Command, response: Response) -> Bool

    /// Releases the system's resources after a test case. Defaults to doing nothing.
    func tearDown(_ system: System) async
}

extension LinearizableMachine {
    public func precondition(_ command: Command, model: Model) -> Bool { true }
    public func tearDown(_ system: System) async {}

    /// This machine, run one command at a time.
    ///
    /// ```swift
    /// await check(QueueMachine().sequential)
    /// ```
    public var sequential: SequentialAdapter<Self> { SequentialAdapter(machine: self) }
}

/// A ``LinearizableMachine`` run one command at a time. See
/// ``LinearizableMachine/sequential``.
public struct SequentialAdapter<Machine: LinearizableMachine>: SequentialMachine {
    let machine: Machine

    public func makeState() async throws -> (model: Machine.Model, system: Machine.System) {
        (try await machine.makeModel(), try await machine.makeSystem())
    }

    public func commands(for state: (model: Machine.Model, system: Machine.System))
        -> Machine.Commands
    {
        machine.commands(for: state.model)
    }

    public func run(
        _ command: Machine.Command, state: inout (model: Machine.Model, system: Machine.System)
    ) async throws {
        guard machine.precondition(command, model: state.model) else { try skip("precondition") }
        let response = try await machine.apply(command, to: state.system)
        #expect(
            machine.postcondition(state.model, command: command, response: response),
            "\(command) returned \(String(reflecting: response))")
        state.model = machine.next(state.model, after: command, response: response)
    }

    public func tearDown(_ state: (model: Machine.Model, system: Machine.System)) async {
        await machine.tearDown(state.system)
    }
}

/// Tests a system by running generated commands concurrently and checking that some sequential
/// order of them explains every response.
///
/// Each test case runs a prefix of commands one at a time, then `branches` sequences of commands
/// concurrently, each in its own task. It then searches for an order of the concurrent commands,
/// keeping each branch's own order, in which every command's precondition holds and every
/// response satisfies its postcondition, advancing the model as it goes. If there's none, the
/// system isn't linearizable: some interleaving produced responses no sequential execution
/// could, which is the signature of a race.
///
/// Under ``Scheduling/deterministic`` scheduling, the interleaving of the branches is itself
/// drawn from the test case, so a failing interleaving shrinks and replays like the commands do.
///
/// ```swift
/// @Test func registerIsLinearizable() async {
///     await checkLinearizability(RegisterMachine())
/// }
/// ```
///
/// Branches are generated from the model's state after the prefix, so a branch's commands must
/// make sense in any order relative to the other branches'. Commands whose preconditions fail
/// there are dropped.
///
/// - Parameters:
///   - machine: The model and system to test.
///   - steps: The allowed number of commands in the sequential prefix.
///   - averageSteps: The number of prefix commands to aim for.
///   - branches: The number of concurrent branches.
///   - branchSteps: The allowed number of commands in each branch. Checking considers every
///     interleaving of the branches, so keep them short.
///   - id: Identifies this check within its test, so its saved failures replay.
///   - settings: Options for this test. Defaults to the settings of the running test.
///   - sourceLocation: Where to attribute the summary issue.
///   - isolation: The actor the test runs on. Branches run concurrently in child tasks.
@discardableResult
public func checkLinearizability<M: LinearizableMachine>(
    _ machine: M,
    steps: ClosedRange<Int> = 0...10,
    averageSteps: Double = 3,
    branches: Int = 2,
    branchSteps: ClosedRange<Int> = 1...4,
    id: String? = nil,
    settings: Settings = .current,
    sourceLocation: SourceLocation = #_sourceLocation,
    isolation: isolated (any Actor)? = #isolation
) async -> PropertyResult {
    precondition(branches >= 1, "checkLinearizability needs at least one branch")
    let branchAverage = Double(branchSteps.lowerBound + branchSteps.upperBound) / 2
    return await Engine(id: id, settings: settings, sourceLocation: sourceLocation).run(
        isolation: isolation
    ) {
        testCase, context in
        var model = try await machine.makeModel()
        let system = try await machine.makeSystem()
        var log: [String] = []
        func show() { context.description = "\n" + log.joined(separator: "\n") }
        do {
            // The sequential prefix, run as it's generated.
            var count = 0
            while let command = try testCase.drawElement(
                machine.commands(for: model), count: count, bounds: steps, average: averageSteps)
            {
                count += 1
                guard machine.precondition(command, model: model) else { continue }
                let response = try await machine.apply(command, to: system)
                log.append("\(log.count + 1). \(command) → \(String(reflecting: response))")
                show()
                guard machine.postcondition(model, command: command, response: response) else {
                    Issue.record(
                        "Postcondition failed: \(command) returned \(String(reflecting: response))."
                    )
                    throw LinearizabilityFailure()
                }
                model = machine.next(model, after: command, response: response)
            }

            // The branches, generated from the model after the prefix.
            var plan: [[M.Command]] = []
            for _ in 0..<branches {
                var commands: [M.Command] = []
                var drawn = 0
                while let command = try testCase.drawElement(
                    machine.commands(for: model), count: drawn, bounds: branchSteps,
                    average: branchAverage)
                {
                    drawn += 1
                    if machine.precondition(command, model: model) { commands.append(command) }
                }
                plan.append(commands)
            }

            // Run the branches concurrently, recording each command's response.
            let results = try await withThrowingTaskGroup(
                of: (Int, [(command: M.Command, response: M.Response)]).self
            ) { group in
                for (index, commands) in plan.enumerated() {
                    group.addTask(name: "branch \(index + 1)") {
                        var results: [(command: M.Command, response: M.Response)] = []
                        for command in commands {
                            results.append((command, try await machine.apply(command, to: system)))
                        }
                        return (index, results)
                    }
                }
                var results = Array(
                    repeating: [(command: M.Command, response: M.Response)](), count: plan.count)
                for try await (index, branch) in group { results[index] = branch }
                return results
            }
            for (index, branch) in results.enumerated() {
                let steps = branch.map { "\($0.command) → \(String(reflecting: $0.response))" }
                log.append(
                    "Branch \(index + 1): "
                        + (steps.isEmpty ? "(nothing)" : steps.joined(separator: "; ")))
            }
            show()

            guard linearizes(machine, model: model, branches: results) else {
                Issue.record(
                    "Not linearizable: no sequential order of the concurrent commands explains their responses."
                )
                throw LinearizabilityFailure()
            }
        } catch {
            await machine.tearDown(system)
            // The failure was recorded as an issue; the error only ends the test case.
            if error is LinearizabilityFailure { return }
            throw error
        }
        await machine.tearDown(system)
    }
}

/// Ends a linearizability test case whose failure was already recorded.
private struct LinearizabilityFailure: Error {}

/// Whether some interleaving of `branches`, keeping each branch's order, is explained by the
/// model starting from `model`.
private func linearizes<M: LinearizableMachine>(
    _ machine: M, model: M.Model, branches: [[(command: M.Command, response: M.Response)]]
) -> Bool {
    var positions = Array(repeating: 0, count: branches.count)
    func search(_ model: M.Model) -> Bool {
        var done = true
        for b in branches.indices where positions[b] < branches[b].count {
            done = false
            let (command, response) = branches[b][positions[b]]
            guard machine.precondition(command, model: model),
                machine.postcondition(model, command: command, response: response)
            else { continue }
            positions[b] += 1
            defer { positions[b] -= 1 }
            if search(machine.next(model, after: command, response: response)) { return true }
        }
        return done
    }
    return search(model)
}
