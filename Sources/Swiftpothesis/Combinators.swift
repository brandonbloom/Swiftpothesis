// MARK: - Transforming

extension Generator {
    /// Transforms each generated value.
    ///
    /// The result shrinks as this generator does, because shrinking happens to the underlying
    /// choices rather than to values.
    public func map<T>(_ transform: @escaping @Sendable (Value) -> T) -> Generators.Map<Self, T> {
        Generators.Map(base: self, transform: transform)
    }

    /// Uses each generated value to choose a generator for the final value.
    ///
    /// Unlike integrated shrinking, internal shrinking simplifies values on both sides of a
    /// `flatMap`.
    public func flatMap<Next: Generator>(
        _ transform: @escaping @Sendable (Value) -> Next
    ) -> Generators.FlatMap<Self, Next> {
        Generators.FlatMap(base: self, transform: transform)
    }

    /// Produces only values that satisfy a predicate.
    ///
    /// Each draw retries up to `maxAttempts` times before rejecting the test case. Prefer
    /// constructing valid values directly: a sparse filter wastes test cases and fails the
    /// too-much-filtering health check.
    public func filter(
        maxAttempts: Int = 3, _ isIncluded: @escaping @Sendable (Value) -> Bool
    ) -> Generators.Filter<Self> {
        Generators.Filter(base: self, maxAttempts: maxAttempts, isIncluded: isIncluded)
    }

    /// Hides this generator's concrete type.
    public func eraseToAnyGenerator() -> AnyGenerator<Value> {
        AnyGenerator(self)
    }
}

// MARK: - Constants and choices

extension Generator {
    /// A generator that always produces `value`.
    public static func just<T: Sendable>(_ value: T) -> Self where Self == Generators.Just<T> {
        Generators.Just(value: value)
    }

    /// Chooses one of `elements`, shrinking toward the first.
    public static func element<C: Collection & Sendable>(
        of elements: C
    ) -> Self where Self == Generators.Element<C> {
        precondition(!elements.isEmpty, "element(of:) requires a non-empty collection")
        return Generators.Element(elements: elements)
    }

    // Parameter packs can't yet require their elements' values to be equal ("same-element
    // requirements are not yet supported"), so each arity is spelled out.
    /// Draws from one of `generators`, shrinking toward the first.
    public static func oneOf<V>(_ generators: [AnyGenerator<V>]) -> Self
    where Self == Generators.OneOf<V> {
        precondition(!generators.isEmpty, "oneOf requires at least one generator")
        return Generators.OneOf(choices: generators.map { (1, $0) })
    }

    /// Draws from one of the generators, shrinking toward the first.
    public static func oneOf<A: Generator, B: Generator>(_ a: A, _ b: B) -> Self
    where Self == Generators.OneOf<A.Value>, B.Value == A.Value {
        .oneOf([AnyGenerator(a), AnyGenerator(b)])
    }

    /// Draws from one of the generators, shrinking toward the first.
    public static func oneOf<A: Generator, B: Generator, C: Generator>(_ a: A, _ b: B, _ c: C)
        -> Self
    where Self == Generators.OneOf<A.Value>, B.Value == A.Value, C.Value == A.Value {
        .oneOf([AnyGenerator(a), AnyGenerator(b), AnyGenerator(c)])
    }

    /// Draws from one of the generators, shrinking toward the first.
    public static func oneOf<A: Generator, B: Generator, C: Generator, D: Generator>(
        _ a: A, _ b: B, _ c: C, _ d: D
    ) -> Self
    where
        Self == Generators.OneOf<A.Value>, B.Value == A.Value, C.Value == A.Value,
        D.Value == A.Value
    {
        .oneOf([AnyGenerator(a), AnyGenerator(b), AnyGenerator(c), AnyGenerator(d)])
    }

    /// Draws from one of the generators, shrinking toward the first.
    public static func oneOf<A: Generator, B: Generator, C: Generator, D: Generator, E: Generator>(
        _ a: A, _ b: B, _ c: C, _ d: D, _ e: E
    ) -> Self
    where
        Self == Generators.OneOf<A.Value>, B.Value == A.Value, C.Value == A.Value,
        D.Value == A.Value, E.Value == A.Value
    {
        .oneOf([
            AnyGenerator(a), AnyGenerator(b), AnyGenerator(c), AnyGenerator(d), AnyGenerator(e),
        ])
    }

    /// Draws from one of `generators`, chosen in proportion to their weights.
    public static func frequency<V>(_ choices: (weight: Int, generator: AnyGenerator<V>)...)
        -> Self where Self == Generators.OneOf<V>
    {
        Generators.OneOf(choices: choices.map { ($0.weight, $0.generator) })
    }
}

/// Combines generators into one that produces tuples of their values.
///
/// ```swift
/// zip(.integers(in: 0...9), .strings(), .booleans())
/// ```
public func zip<each G: Generator>(_ generators: repeat each G) -> Generators.Zip<repeat each G> {
    Generators.Zip(generators: (repeat each generators))
}

extension Generators.Zip {
    /// Transforms each tuple of generated values, passing its elements as separate arguments.
    ///
    /// ```swift
    /// zip(.integers(in: 0...9), .strings()).map(Item.init(count:name:))
    /// ```
    public func map<T>(
        _ transform: @escaping @Sendable (repeat (each G).Value) -> T
    ) -> Generators.Map<Self, T> {
        Generators.Map(base: self) { (values: (repeat (each G).Value)) in
            transform(repeat each values)
        }
    }
}

// MARK: - Recursion

extension Generator {
    /// A generator for recursive structures, such as trees or expressions.
    ///
    /// `extend` receives a generator for smaller instances and returns a generator for a larger
    /// one. Each level of recursion is entered with decreasing probability, and never below
    /// `maxDepth`, so generated values are finite and shrink toward `base`.
    ///
    /// ```swift
    /// indirect enum Tree { case leaf(Int), node(Tree, Tree) }
    /// let trees: AnyGenerator<Tree> = .recursive(base: .integers(in: 0...9).map(Tree.leaf)) {
    ///     subtree in zip(subtree, subtree).map(Tree.node)
    /// }
    /// ```
    public static func recursive<V>(
        base: some Generator<V>,
        maxDepth: Int = 5,
        _ extend: @escaping @Sendable (AnyGenerator<V>) -> some Generator<V>
    ) -> Self where Self == AnyGenerator<V> {
        let base = AnyGenerator(base)
        func level(_ depth: Int) -> AnyGenerator<V> {
            guard depth > 0 else { return base }
            let deeper = AnyGenerator(extend(level(depth - 1)))
            return AnyGenerator(Generators.OneOf(choices: [(1, base), (1, deeper)]))
        }
        return level(maxDepth)
    }
}

// MARK: - Generator types

/// A namespace for the concrete types that generator combinators return.
///
/// Use these types' names only when you need to spell a generator's type. Otherwise, write
/// `some Generator<Value>`.
public enum Generators {
    /// A generator that transforms another's values. See ``Generator/map(_:)``.
    public struct Map<Base: Generator, Value>: Generator {
        let base: Base
        let transform: @Sendable (Base.Value) -> Value

        public func generate(from source: inout Source) throws(Rejection) -> Value {
            transform(try base.generate(from: &source))
        }
    }

    /// A generator that chooses its next generator from another's value. See
    /// ``Generator/flatMap(_:)``.
    public struct FlatMap<Base: Generator, Next: Generator>: Generator {
        let base: Base
        let transform: @Sendable (Base.Value) -> Next

        public func generate(from source: inout Source) throws(Rejection) -> Next.Value {
            let value = try base.generate(from: &source)
            return try transform(value).generate(from: &source)
        }
    }

    /// A generator that produces only values satisfying a predicate. See ``Generator/filter(maxAttempts:_:)``.
    public struct Filter<Base: Generator>: Generator {
        let base: Base
        let maxAttempts: Int
        let isIncluded: @Sendable (Base.Value) -> Bool

        public func generate(from source: inout Source) throws(Rejection) -> Base.Value {
            for _ in 0..<maxAttempts {
                let value = try source.span { (source) throws(Rejection) in
                    try base.generate(from: &source)
                }
                if isIncluded(value) { return value }
            }
            throw Rejection(.filtered)
        }
    }

    /// A generator that always produces the same value. See ``Generator/just(_:)``.
    public struct Just<Value: Sendable>: Generator {
        let value: Value

        public func generate(from source: inout Source) throws(Rejection) -> Value { value }
    }

    /// A generator that chooses an element of a collection. See ``Generator/element(of:)``.
    public struct Element<Elements: Collection & Sendable>: Generator {
        let elements: Elements

        public func generate(from source: inout Source) throws(Rejection) -> Elements.Element {
            let offset = try source.choose(atMost: UInt64(elements.count - 1))
            return elements[elements.index(elements.startIndex, offsetBy: Int(offset))]
        }
    }

    /// A generator that draws from one of several generators. See ``Generator/oneOf(_:)``.
    public struct OneOf<Value>: Generator {
        let choices: [(weight: Int, generator: AnyGenerator<Value>)]

        public func generate(from source: inout Source) throws(Rejection) -> Value {
            let total = choices.reduce(0) { $0 + $1.weight }
            var pick = Int(try source.choose(atMost: UInt64(total - 1)))
            for choice in choices {
                if pick < choice.weight { return try choice.generator.generate(from: &source) }
                pick -= choice.weight
            }
            preconditionFailure("unreachable: pick exceeded total weight")
        }
    }

    /// A generator that combines several generators' values into a tuple. See ``zip(_:)``.
    public struct Zip<each G: Generator>: Generator {
        let generators: (repeat each G)

        public func generate(from source: inout Source) throws(Rejection) -> (repeat (each G).Value)
        {
            (repeat try source.draw(each generators))
        }
    }
}

/// A type-erased generator.
public struct AnyGenerator<Value>: Generator {
    private let body: @Sendable (inout Source) throws(Rejection) -> Value

    /// Wraps a generator, hiding its type.
    public init<G: Generator>(_ generator: G) where G.Value == Value {
        if let erased = generator as? AnyGenerator<Value> {
            self = erased
        } else {
            body = { (source) throws(Rejection) in try generator.generate(from: &source) }
        }
    }

    public func generate(from source: inout Source) throws(Rejection) -> Value {
        try body(&source)
    }
}
