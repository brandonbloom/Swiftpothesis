extension Array where Element: Sendable {
    /// Arrays of generated elements, shrinking toward fewer and simpler elements.
    ///
    /// - Parameters:
    ///   - element: The generator for each element.
    ///   - count: The allowed number of elements.
    ///   - averageCount: The number of elements to aim for. Defaults to a short length, since most
    ///     bugs appear in small inputs and large ones slow every test case.
    public static func arbitrary(
        _ element: some Generator<Element>, count: ClosedRange<Int> = 0...100,
        averageCount: Double? = nil
    ) -> some Generator<[Element]> {
        Generators.Arrays(element: element, count: count, averageCount: averageCount)
    }
}

extension Array where Element: Arbitrary {
    /// Arrays of arbitrary elements with a number of elements in `count`.
    public static func arbitrary(count: ClosedRange<Int>) -> some Generator<[Element]> {
        arbitrary(Element.arbitrary, count: count)
    }
}

extension Set where Element: Sendable {
    /// Sets of generated elements, shrinking toward fewer and simpler elements.
    public static func arbitrary(
        _ element: some Generator<Element>, count: ClosedRange<Int> = 0...100
    ) -> some Generator<Set<Element>> {
        // TODO: Draw distinct elements, so duplicates can't leave a set below `count.lowerBound`.
        Generators.Arrays(element: element, count: count, averageCount: nil).map(Set.init)
    }
}

extension Set where Element: Arbitrary {
    /// Sets of arbitrary elements with a number of elements in `count`.
    public static func arbitrary(count: ClosedRange<Int>) -> some Generator<Set<Element>> {
        arbitrary(Element.arbitrary, count: count)
    }
}

extension Dictionary where Key: Sendable, Value: Sendable {
    /// Dictionaries with generated keys and values. Duplicate keys keep their first value.
    public static func arbitrary(
        keys: some Generator<Key>, values: some Generator<Value>,
        count: ClosedRange<Int> = 0...100
    ) -> some Generator<[Key: Value]> {
        Generators.Arrays(element: zip(keys, values), count: count, averageCount: nil).map {
            Dictionary($0, uniquingKeysWith: { first, _ in first })
        }
    }
}

extension Dictionary where Key: Arbitrary, Value: Arbitrary {
    /// Dictionaries of arbitrary keys and values with a number of entries in `count`.
    public static func arbitrary(count: ClosedRange<Int>) -> some Generator<[Key: Value]> {
        arbitrary(keys: Key.arbitrary, values: Value.arbitrary, count: count)
    }
}

extension Optional where Wrapped: Sendable {
    /// Optional generated values, shrinking toward `nil`.
    public static func arbitrary(_ wrapped: some Generator<Wrapped>) -> some Generator<Wrapped?> {
        Generators.Optionals(wrapped: wrapped)
    }
}

extension Generators {
    struct Arrays<Element: Generator>: Generator {
        let element: Element
        let count: ClosedRange<Int>
        let averageCount: Double

        init(element: Element, count: ClosedRange<Int>, averageCount: Double?) {
            self.element = element
            self.count = count
            // By default, aim a few elements past the minimum, but no further than halfway to the
            // maximum, as Hypothesis does.
            self.averageCount =
                averageCount
                ?? Swift.min(
                    Double(Swift.max(count.lowerBound * 2, count.lowerBound + 5)),
                    Double(count.lowerBound + count.upperBound) / 2)
        }

        func generate(from source: inout Source) throws(Rejection) -> [Element.Value] {
            // Each element is preceded by a choice to continue, so the shrinker can delete an
            // element by deleting its span, and shorten the array by zeroing a choice.
            var result: [Element.Value] = []
            while try source.continues(count: result.count, bounds: count, average: averageCount) {
                result.append(
                    try source.span { (source) throws(Rejection) in
                        try element.generate(from: &source)
                    })
            }
            return result
        }
    }

    struct Optionals<Wrapped: Generator>: Generator {
        let wrapped: Wrapped

        func generate(from source: inout Source) throws(Rejection) -> Wrapped.Value? {
            try source.choose(atMost: 3) == 0 ? nil : try wrapped.generate(from: &source)
        }
    }
}
