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
/// A linearizable machine also runs sequentially, through ``sequential``.
///
/// TODO: Implement ``checkLinearizability(_:steps:averageSteps:branches:id:settings:sourceLocation:isolation:)``.
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
/// Each test case runs a sequential prefix of commands, then `branches` sequences concurrently.
/// Failing cases shrink toward fewer, simpler commands.
///
/// - Note: Not implemented yet.
@discardableResult
public func checkLinearizability<M: LinearizableMachine>(
    _ machine: M,
    steps: ClosedRange<Int> = 1...20,
    averageSteps: Double = 8,
    branches: Int = 2,
    id: String? = nil,
    settings: Settings = .current,
    sourceLocation: SourceLocation = #_sourceLocation,
    isolation: isolated (any Actor)? = #isolation
) async -> PropertyResult {
    fatalError("checkLinearizability is not implemented yet")
}
