extension FixedWidthInteger where Self: Sendable {
    /// Integers in a range, shrinking toward zero, or toward the bound nearest zero when the range
    /// excludes it.
    public static func arbitrary(in range: ClosedRange<Self>) -> some Generator<Self> {
        Generators.Integers(range: range)
    }
}

extension Double {
    /// Values in a range, shrinking toward simple values near zero.
    public static func arbitrary(in range: ClosedRange<Double>) -> some Generator<Double> {
        Generators.Doubles(range: range, allowNaN: false, allowInfinity: false)
    }

    /// Any `Double`, optionally including NaN and the infinities.
    public static func arbitrary(allowNaN: Bool, allowInfinity: Bool) -> some Generator<Double> {
        Generators.Doubles(
            range: -.greatestFiniteMagnitude ... .greatestFiniteMagnitude, allowNaN: allowNaN,
            allowInfinity: allowInfinity)
    }
}

extension Generators {
    struct Integers<I: FixedWidthInteger & Sendable>: Generator {
        let range: ClosedRange<I>

        func generate(from source: inout Source) throws(Rejection) -> I {
            // Draw a distance from the shrink target, and which side of it to go, so that smaller
            // choices give values nearer zero.
            let target: I =
                range.contains(0) ? 0 : (range.lowerBound > 0 ? range.lowerBound : range.upperBound)
            let above = UInt64(truncatingIfNeeded: range.upperBound.magnitudeDistance(from: target))
            let below = UInt64(truncatingIfNeeded: target.magnitudeDistance(from: range.lowerBound))
            let negative =
                below > 0 ? (above == 0 ? true : try source.choose(atMost: 1) == 1) : false
            let distance = try source.choose(atMost: negative ? below : above)
            // Wrapping arithmetic is exact here: the distance fits in the range, but not
            // necessarily in `I`, as with `Int8.min`'s distance from zero.
            return negative
                ? target &- I(truncatingIfNeeded: distance)
                : target &+ I(truncatingIfNeeded: distance)
        }
    }

    struct Booleans: Generator {
        func generate(from source: inout Source) throws(Rejection) -> Bool {
            try source.choose(atMost: 1) == 1
        }
    }

    struct Doubles: Generator {
        let range: ClosedRange<Double>
        let allowNaN: Bool
        let allowInfinity: Bool

        func generate(from source: inout Source) throws(Rejection) -> Double {
            // TODO: Adopt Hypothesis's lexicographic float encoding, so that shrinking prefers
            // integral values, then simple fractions, then everything else.
            switch try source.choose(atMost: 3) {
            case 3 where allowNaN: return .nan
            case 2 where allowInfinity:
                return try source.choose(atMost: 1) == 0 ? .infinity : -.infinity
            case 1:
                let bits = try source.choose(atMost: .max)
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
