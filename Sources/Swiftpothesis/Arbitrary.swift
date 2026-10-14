/// A type that can generate any of its values.
///
/// A conforming type's ``arbitrary`` generator produces any value of the type, and lets properties
/// request values by type alone:
///
/// ```swift
/// await forAll { (name: String, tags: [String]) in
///     #expect(Item(name: name, tags: tags).isValid)
/// }
/// ```
///
/// When "any value" is too broad, a type offers static `arbitrary(…)` methods that narrow it, by
/// convention taking at least one argument:
///
/// ```swift
/// await forAll(Int.arbitrary(in: 0...9), [String].arbitrary(count: 1...3)) { digit, tags in … }
/// ```
///
/// A narrowed generator produces a subset of the values ``arbitrary`` can, though it may produce
/// them with different frequencies. It must construct them directly rather than filtering
/// ``arbitrary``'s values. Conform your own types the same way:
///
/// ```swift
/// extension Person: Arbitrary {
///     static var arbitrary: some Generator<Person> {
///         zip(String.arbitrary, Int.arbitrary(in: 0...120)).map(Person.init)
///     }
///
///     static func arbitrary(adultsOnly: Bool) -> some Generator<Person> {
///         zip(String.arbitrary, Int.arbitrary(in: adultsOnly ? 18...120 : 0...120))
///             .map(Person.init)
///     }
/// }
/// ```
///
/// TODO: An `@Arbitrary` macro that derives conformances for structs and enums from their
/// stored properties and cases, with per-property overrides by key path.
public protocol Arbitrary: Sendable {
    /// The type of the generator of any value.
    associatedtype ArbitraryGenerator: Generator<Self>

    /// A generator of any value of this type.
    static var arbitrary: ArbitraryGenerator { get }
}

// MARK: - Standard library conformances

extension Bool: Arbitrary {
    /// `true` or `false`, shrinking toward `false`.
    public static var arbitrary: some Generator<Bool> { Generators.Booleans() }
}

extension Int: Arbitrary {
    /// Any `Int`, shrinking toward zero.
    public static var arbitrary: some Generator<Int> { arbitrary(in: .min ... .max) }
}

extension Int8: Arbitrary {
    /// Any `Int8`, shrinking toward zero.
    public static var arbitrary: some Generator<Int8> { arbitrary(in: .min ... .max) }
}

extension Int16: Arbitrary {
    /// Any `Int16`, shrinking toward zero.
    public static var arbitrary: some Generator<Int16> { arbitrary(in: .min ... .max) }
}

extension Int32: Arbitrary {
    /// Any `Int32`, shrinking toward zero.
    public static var arbitrary: some Generator<Int32> { arbitrary(in: .min ... .max) }
}

extension Int64: Arbitrary {
    /// Any `Int64`, shrinking toward zero.
    public static var arbitrary: some Generator<Int64> { arbitrary(in: .min ... .max) }
}

extension UInt: Arbitrary {
    /// Any `UInt`, shrinking toward zero.
    public static var arbitrary: some Generator<UInt> { arbitrary(in: .min ... .max) }
}

extension UInt8: Arbitrary {
    /// Any `UInt8`, shrinking toward zero.
    public static var arbitrary: some Generator<UInt8> { arbitrary(in: .min ... .max) }
}

extension UInt16: Arbitrary {
    /// Any `UInt16`, shrinking toward zero.
    public static var arbitrary: some Generator<UInt16> { arbitrary(in: .min ... .max) }
}

extension UInt32: Arbitrary {
    /// Any `UInt32`, shrinking toward zero.
    public static var arbitrary: some Generator<UInt32> { arbitrary(in: .min ... .max) }
}

extension UInt64: Arbitrary {
    /// Any `UInt64`, shrinking toward zero.
    public static var arbitrary: some Generator<UInt64> { arbitrary(in: .min ... .max) }
}

extension Double: Arbitrary {
    /// Any finite `Double`, shrinking toward simple values near zero.
    public static var arbitrary: some Generator<Double> {
        arbitrary(allowNaN: false, allowInfinity: false)
    }
}

extension Unicode.Scalar: Arbitrary {
    /// Any Unicode scalar, favoring printable ASCII and characters that often break text
    /// handling, and shrinking toward `"0"`.
    public static var arbitrary: some Generator<Unicode.Scalar> { Generators.UnicodeScalars() }
}

extension String: Arbitrary {
    /// Strings of up to 50 arbitrary Unicode scalars, shrinking toward shorter, simpler strings.
    public static var arbitrary: some Generator<String> { arbitrary(count: 0...50) }
}

extension Optional: Arbitrary where Wrapped: Arbitrary {
    /// `nil` or an arbitrary wrapped value, shrinking toward `nil`.
    public static var arbitrary: some Generator<Wrapped?> { arbitrary(Wrapped.arbitrary) }
}

extension Array: Arbitrary where Element: Arbitrary {
    /// Arrays of up to 100 arbitrary elements, shrinking toward fewer, simpler elements.
    public static var arbitrary: some Generator<[Element]> { arbitrary(count: 0...100) }
}

extension Set: Arbitrary where Element: Arbitrary {
    /// Sets of up to 100 arbitrary elements, shrinking toward fewer, simpler elements.
    public static var arbitrary: some Generator<Set<Element>> { arbitrary(count: 0...100) }
}

extension Dictionary: Arbitrary where Key: Arbitrary, Value: Arbitrary {
    /// Dictionaries of up to 100 arbitrary entries, shrinking toward fewer, simpler entries.
    public static var arbitrary: some Generator<[Key: Value]> { arbitrary(count: 0...100) }
}
