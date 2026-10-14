/// A type with a default generator.
///
/// Conforming a type to `Arbitrary` lets properties request its values by type alone:
///
/// ```swift
/// await forAll { (name: String, tags: [String]) in
///     #expect(Item(name: name, tags: tags).isValid)
/// }
/// ```
///
/// A conformance chooses the generator that best represents "any value" of the type. Tests that
/// need narrower values pass an explicit generator instead.
///
/// TODO: An `@Arbitrary` macro that derives conformances for structs and enums from their
/// stored properties and cases.
public protocol Arbitrary {
    /// The type of the default generator.
    associatedtype ArbitraryGenerator: Generator<Self>

    /// The default generator for this type.
    static var arbitrary: ArbitraryGenerator { get }
}

extension Generator {
    /// The default generator of an ``Arbitrary`` type.
    public static func arbitrary<T: Arbitrary>(_ type: T.Type = T.self) -> Self
    where Self == T.ArbitraryGenerator {
        T.arbitrary
    }
}

// MARK: - Standard library conformances

extension Bool: Arbitrary {
    public static var arbitrary: Generators.Booleans { .booleans() }
}

extension Int: Arbitrary {
    public static var arbitrary: Generators.Integers<Int> { .integers() }
}

extension Int8: Arbitrary {
    public static var arbitrary: Generators.Integers<Int8> { .integers() }
}

extension Int16: Arbitrary {
    public static var arbitrary: Generators.Integers<Int16> { .integers() }
}

extension Int32: Arbitrary {
    public static var arbitrary: Generators.Integers<Int32> { .integers() }
}

extension Int64: Arbitrary {
    public static var arbitrary: Generators.Integers<Int64> { .integers() }
}

extension UInt: Arbitrary {
    public static var arbitrary: Generators.Integers<UInt> { .integers() }
}

extension UInt8: Arbitrary {
    public static var arbitrary: Generators.Integers<UInt8> { .integers() }
}

extension UInt16: Arbitrary {
    public static var arbitrary: Generators.Integers<UInt16> { .integers() }
}

extension UInt32: Arbitrary {
    public static var arbitrary: Generators.Integers<UInt32> { .integers() }
}

extension UInt64: Arbitrary {
    public static var arbitrary: Generators.Integers<UInt64> { .integers() }
}

extension Double: Arbitrary {
    public static var arbitrary: Generators.Doubles { .doubles() }
}

extension Unicode.Scalar: Arbitrary {
    public static var arbitrary: Generators.UnicodeScalars { .unicodeScalars() }
}

extension String: Arbitrary {
    public static var arbitrary: Generators.Strings { .strings() }
}

extension Optional: Arbitrary where Wrapped: Arbitrary {
    public static var arbitrary: Generators.Optionals<Wrapped.ArbitraryGenerator> {
        .optionals(of: Wrapped.arbitrary)
    }
}

extension Array: Arbitrary where Element: Arbitrary {
    public static var arbitrary: Generators.Arrays<Element.ArbitraryGenerator> {
        .arrays(of: Element.arbitrary)
    }
}

extension Set: Arbitrary where Element: Arbitrary {
    public static var arbitrary: Generators.Map<Generators.Arrays<Element.ArbitraryGenerator>, Set>
    {
        .sets(of: Element.arbitrary)
    }
}

extension Dictionary: Arbitrary where Key: Arbitrary, Value: Arbitrary {
    public static var arbitrary:
        Generators.Map<
            Generators.Arrays<Generators.Zip<Key.ArbitraryGenerator, Value.ArbitraryGenerator>>,
            Dictionary
        >
    {
        .dictionaries(keys: Key.arbitrary, values: Value.arbitrary)
    }
}
