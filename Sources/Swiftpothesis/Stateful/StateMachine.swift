import Testing

/// A model of a system, for testing that the system behaves like the model under any sequence of
/// commands.
///
/// A state machine generates commands from the model's state, runs each against the real system
/// and the model, and checks that they agree. When a sequence fails, Swiftpothesis shrinks it to
/// the fewest, simplest commands that still fail, and reports them in order.
///
/// ```swift
/// struct QueueMachine: StateMachine {
///     enum Command: CustomStringConvertible {
///         case push(Int), pop
///         var description: String { … }
///     }
///
///     var initialModel: [Int] { [] }
///     func makeSystem() -> Queue<Int> { Queue() }
///
///     func commands(for model: [Int]) -> some Generator<Command> {
///         .oneOf(.integers(in: 0...9).map(Command.push), .just(.pop))
///     }
///
///     func precondition(_ command: Command, model: [Int]) -> Bool {
///         if case .pop = command { !model.isEmpty } else { true }
///     }
///
///     func run(_ command: Command, model: inout [Int], system: inout Queue<Int>) async throws {
///         switch command {
///         case .push(let x):
///             model.append(x)
///             system.push(x)
///         case .pop:
///             #expect(system.pop() == model.removeFirst())
///         }
///     }
/// }
///
/// @Test func queueBehavesLikeArray() async {
///     await check(QueueMachine())
/// }
/// ```
///
/// TODO: Parallel runs checked for linearizability, as in PropEr's and Hedgehog's parallel state
/// machines, to find races in actors and other concurrent systems.
public protocol StateMachine {
    /// The abstract state that predicts the system's behavior.
    associatedtype Model

    /// The system under test.
    associatedtype System

    /// An operation on the system.
    associatedtype Command: CustomStringConvertible

    /// The type of generator for commands.
    associatedtype Commands: Generator<Command>

    /// The model's state before any commands run.
    var initialModel: Model { get }

    /// Creates a fresh system for one test case.
    func makeSystem() async throws -> System

    /// The commands that may run next, given the model's state.
    func commands(for model: Model) -> Commands

    /// Whether a command may run in the model's state.
    ///
    /// Shrinking can remove earlier commands, so a command that ``commands(for:)`` produced may
    /// later be replayed in a different state. Commands whose preconditions fail are skipped.
    /// Defaults to `true`.
    func precondition(_ command: Command, model: Model) -> Bool

    /// Runs a command against the system and the model, checking that they agree.
    ///
    /// Check postconditions with `#expect` or `#require`, or by throwing.
    func run(_ command: Command, model: inout Model, system: inout System) async throws

    /// Checks properties that hold in every state. Runs after every command.
    func checkInvariants(model: Model, system: System) async throws

    /// Releases the system's resources after a test case. Defaults to doing nothing.
    func tearDown(_ system: System) async
}

extension StateMachine {
    public func precondition(_ command: Command, model: Model) -> Bool { true }
    public func checkInvariants(model: Model, system: System) async throws {}
    public func tearDown(_ system: System) async {}
}

/// Tests that a system behaves like its model under generated sequences of commands.
///
/// - Parameters:
///   - machine: The model and system to test.
///   - steps: The allowed number of commands per test case.
///   - settings: Options for this test. Defaults to the settings of the running test.
///   - sourceLocation: Where to attribute the summary issue.
///   - isolation: The actor the commands run on. Defaults to the caller's.
public func check<M: StateMachine>(
    _ machine: M,
    steps: ClosedRange<Int> = 1...50,
    settings: Settings = .current,
    sourceLocation: SourceLocation = #_sourceLocation,
    isolation: isolated (any Actor)? = #isolation
) async {
    await Engine(settings: settings, sourceLocation: sourceLocation).run(isolation: isolation) {
        source, context in
        var model = machine.initialModel
        var system = try await machine.makeSystem()
        var log: [String] = []
        do {
            var count = 0
            while count < steps.upperBound {
                if count >= steps.lowerBound, try source.draw(atMost: 7) == 0 { break }
                let command = try source.span { (source) throws(Rejection) in
                    try machine.commands(for: model).generate(from: &source)
                }
                guard machine.precondition(command, model: model) else { continue }
                count += 1
                log.append("\(count). \(command)")
                context.description = "\n" + log.joined(separator: "\n")
                try await machine.run(command, model: &model, system: &system)
                try await machine.checkInvariants(model: model, system: system)
            }
        } catch {
            await machine.tearDown(system)
            throw error
        }
        await machine.tearDown(system)
    }
}
