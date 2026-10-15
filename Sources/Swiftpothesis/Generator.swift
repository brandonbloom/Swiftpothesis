/// A description of how to produce values of some type from a ``Source`` of choices.
///
/// "Generator" here has its property-based-testing meaning, as in QuickCheck and Hypothesis: a
/// recipe that produces one value each time it runs. It isn't an iterator, as generators are in
/// Python and JavaScript and as `GeneratorType` was before Swift 3. To produce values one after
/// another while a property runs, use a ``TestCase``.
///
/// A generator is a pure function of the choices it draws. The engine produces new test cases by
/// drawing choices at random, and it shrinks a failing test case by simplifying the recorded
/// choices and running the generator again. So every generator shrinks, including ones built with
/// ``map(_:)``, ``filter(maxAttempts:_:)``, and ``flatMap(_:)``, and a shrunk value always satisfies the
/// generator's own constraints.
///
/// Generators for a type's values come from the type: ``Arbitrary/arbitrary`` for any value, and
/// static `arbitrary(…)` methods for narrower ones. Generators that combine others are free
/// functions, such as ``oneOf(_:_:)``, ``weighted(_:_:)``, ``constant(_:)``, and ``zip(_:)``:
///
/// ```swift
/// let digits = Int.arbitrary(in: 0...9)
/// let pairs = zip(digits, String.arbitrary)
/// let sentinel = oneOf(digits, constant(-1))
/// ```
///
/// To write a generator that the combinators can't express, conform a type to this protocol and
/// draw from the source in ``generate(from:)``, either primitive choices or values of other
/// generators.
public protocol Generator<Value>: Sendable {
    /// The type of value this generator produces.
    ///
    /// Generated values should be pure values. To test a type that isn't `Sendable`, such as a
    /// view or a mutable class, generate a `Sendable` description of it and construct the
    /// instance inside the property.
    associatedtype Value: Sendable

    /// Produces a value by drawing choices from a source.
    ///
    /// The result must depend only on the choices drawn, so that replaying the same choices
    /// produces an equal value.
    ///
    /// - Throws: ``Rejection`` when the choices don't describe a valid value, such as when a filter
    ///   rejects too many candidates. The engine discards the test case and tries another.
    func generate(from source: inout Source) throws(Rejection) -> Value
}

/// The reason a test case was discarded rather than run to completion.
///
/// Discarded test cases are neither passes nor failures. If too many test cases in a run are
/// discarded, the run fails with a health-check issue, because the property is mostly untested.
public struct Rejection: Error, Sendable, CustomStringConvertible {
    /// Why a test case was discarded.
    public enum Reason: Sendable {
        /// A ``Generator/filter(maxAttempts:_:)`` predicate rejected every candidate it tried.
        case filtered
        /// The property called ``assume(_:_:)`` with a false condition.
        case assumption
        /// The test case drew more choices than the engine allows, such as when an unbounded
        /// recursive generator never terminates.
        case overrun
    }

    /// Why the test case was discarded.
    public var reason: Reason

    /// Optional detail for diagnostics.
    public var comment: String?

    public init(_ reason: Reason, comment: String? = nil) {
        self.reason = reason
        self.comment = comment
    }

    public var description: String {
        comment.map { "\(reason): \($0)" } ?? "\(reason)"
    }
}
