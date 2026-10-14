extension Generator {
    /// Arrays of elements, shrinking toward fewer and simpler elements.
    ///
    /// - Parameters:
    ///   - element: The generator for each element.
    ///   - count: The allowed number of elements. Generated arrays are usually short; most bugs
    ///     appear in small inputs, and large ones slow every test case.
    public static func arrays<E: Generator>(
        of element: E, count: ClosedRange<Int> = 0...100
    ) -> Self where Self == Generators.Arrays<E> {
        Generators.Arrays(element: element, count: count)
    }

    /// Sets of elements, shrinking toward fewer and simpler elements.
    public static func sets<E: Generator>(
        of element: E, count: ClosedRange<Int> = 0...100
    ) -> Self where E.Value: Hashable, Self == Generators.Map<Generators.Arrays<E>, Set<E.Value>> {
        // TODO: Draw distinct elements, so duplicates can't leave a set below `count.lowerBound`.
        Generators.Arrays(element: element, count: count).map(Set.init)
    }

    /// Dictionaries with generated keys and values.
    public static func dictionaries<K: Generator, V: Generator>(
        keys: K, values: V, count: ClosedRange<Int> = 0...100
    ) -> Self
    where
        K.Value: Hashable,
        Self == Generators.Map<
            Generators.Arrays<Generators.Zip<K, V>>, [K.Value: V.Value]
        >
    {
        Generators.Arrays(element: zip(keys, values), count: count).map {
            Dictionary($0, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Optional values, shrinking toward `nil`.
    public static func optionals<W: Generator>(of wrapped: W) -> Self
    where Self == Generators.Optionals<W> {
        Generators.Optionals(wrapped: wrapped)
    }
}

extension Generators {
    /// A generator of arrays. See ``Generator/arrays(of:count:)``.
    public struct Arrays<Element: Generator>: Generator {
        let element: Element
        let count: ClosedRange<Int>

        public func generate(from source: inout Source) throws(Rejection) -> [Element.Value] {
            // Each element is preceded by a choice to continue, so the shrinker can delete an
            // element by deleting its span, and shorten the array by zeroing a choice.
            var result: [Element.Value] = []
            while result.count < count.upperBound {
                if result.count >= count.lowerBound, try source.choose(atMost: 7) == 0 { break }
                result.append(
                    try source.span { (source) throws(Rejection) in
                        try element.generate(from: &source)
                    })
            }
            return result
        }
    }

    /// A generator of optionals. See ``Generator/optionals(of:)``.
    public struct Optionals<Wrapped: Generator>: Generator {
        let wrapped: Wrapped

        public func generate(from source: inout Source) throws(Rejection) -> Wrapped.Value? {
            try source.choose(atMost: 3) == 0 ? nil : try wrapped.generate(from: &source)
        }
    }
}
