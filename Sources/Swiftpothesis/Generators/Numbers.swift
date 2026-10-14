extension Generator {
    /// Integers in a range, shrinking toward zero, or toward the bound nearest zero when the range
    /// excludes it.
    public static func integers<I: FixedWidthInteger & Sendable>(
        in range: ClosedRange<I> = I.min...I.max
    ) -> Self where Self == Generators.Integers<I> {
        Generators.Integers(range: range)
    }

    /// `true` or `false`, shrinking toward `false`.
    public static func booleans() -> Self where Self == Generators.Booleans {
        Generators.Booleans()
    }

    /// Floating-point numbers in a range, shrinking toward simple values near zero.
    ///
    /// - Parameters:
    ///   - range: The values to produce. Defaults to all finite values.
    ///   - allowNaN: Whether to produce NaN.
    ///   - allowInfinity: Whether to produce the infinities.
    public static func doubles(
        in range: ClosedRange<Double> = -Double
            .greatestFiniteMagnitude...Double
            .greatestFiniteMagnitude,
        allowNaN: Bool = false,
        allowInfinity: Bool = false
    ) -> Self where Self == Generators.Doubles {
        Generators.Doubles(range: range, allowNaN: allowNaN, allowInfinity: allowInfinity)
    }
}

extension Generators {
    /// A generator of integers in a range. See ``Generator/integers(in:)``.
    public struct Integers<I: FixedWidthInteger & Sendable>: Generator {
        let range: ClosedRange<I>

        public func generate(from source: inout Source) throws(Rejection) -> I {
            // Draw a distance from the shrink target, and which side of it to go, so that smaller
            // choices give values nearer zero.
            let target: I =
                range.contains(0) ? 0 : (range.lowerBound > 0 ? range.lowerBound : range.upperBound)
            let above = UInt64(truncatingIfNeeded: range.upperBound.magnitudeDistance(from: target))
            let below = UInt64(truncatingIfNeeded: target.magnitudeDistance(from: range.lowerBound))
            let negative = below > 0 ? (above == 0 ? true : try source.draw(atMost: 1) == 1) : false
            let distance = try source.draw(atMost: negative ? below : above)
            // Wrapping arithmetic is exact here: the distance fits in the range, but not
            // necessarily in `I`, as with `Int8.min`'s distance from zero.
            return negative
                ? target &- I(truncatingIfNeeded: distance)
                : target &+ I(truncatingIfNeeded: distance)
        }
    }

    /// A generator of Booleans. See ``Generator/booleans()``.
    public struct Booleans: Generator {
        public func generate(from source: inout Source) throws(Rejection) -> Bool {
            try source.draw(atMost: 1) == 1
        }
    }

    /// A generator of `Double` values. See ``Generator/doubles(in:allowNaN:allowInfinity:)``.
    public struct Doubles: Generator {
        let range: ClosedRange<Double>
        let allowNaN: Bool
        let allowInfinity: Bool

        public func generate(from source: inout Source) throws(Rejection) -> Double {
            // TODO: Adopt Hypothesis's lexicographic float encoding, so that shrinking prefers
            // integral values, then simple fractions, then everything else.
            switch try source.draw(atMost: 3) {
            case 3 where allowNaN: return .nan
            case 2 where allowInfinity:
                return try source.draw(atMost: 1) == 0 ? .infinity : -.infinity
            case 1:
                let bits = try source.draw(atMost: .max)
                let value = Double(bitPattern: bits)
                if value.isFinite, range.contains(value) { return value }
                fallthrough
            default:
                // Integral values within ±2^53, where every integer is representable.
                let limit = 9_007_199_254_740_992.0
                let lower = Swift.max(range.lowerBound, -limit).rounded(.up)
                let upper = Swift.min(range.upperBound, limit).rounded(.down)
                guard lower <= upper else { return range.lowerBound }
                return Double(
                    try Integers(range: Int64(lower)...Int64(upper)).generate(from: &source))
            }
        }
    }
}

extension FixedWidthInteger {
    // |self - other| as a magnitude, without overflow, for self >= other.
    fileprivate func magnitudeDistance(from other: Self) -> Magnitude {
        if Self.isSigned, (self >= 0) != (other >= 0) {
            return self.magnitude + other.magnitude
        }
        return (self - other).magnitude
    }
}
