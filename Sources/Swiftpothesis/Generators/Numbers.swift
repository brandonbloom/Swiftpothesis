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
            // Draw a distance from the shrink target, then which side of it to go when both
            // sides allow that distance, so that smaller choices give values nearer zero. The
            // distance comes first, so raising the choice after a value's kind raises its size.
            let target: I =
                range.contains(0) ? 0 : (range.lowerBound > 0 ? range.lowerBound : range.upperBound)
            let above = UInt64(truncatingIfNeeded: range.upperBound.magnitudeDistance(from: target))
            let below = UInt64(truncatingIfNeeded: target.magnitudeDistance(from: range.lowerBound))
            let distance = try source.choose(atMost: Swift.max(above, below))
            let negative: Bool
            if distance > above {
                negative = true
            } else if distance > 0, distance <= below {
                negative = try source.choose(atMost: 1) == 1
            } else {
                negative = false
            }
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

        // Kinds of value, from simplest to most complex, so shrinking prefers integers, then
        // halves and quarters, then arbitrary values, then the edges of the range. Shrinking
        // prefers fewer choices first, so every kind but integers draws at least three, as many
        // as an integer with a sign: otherwise a short encoding of a complex value, such as an
        // edge, would count as simpler than an integer.
        //
        // TODO: Hypothesis's lexicographic float encoding, which shrinks within each kind toward
        // simpler values as well.
        func generate(from source: inout Source) throws(Rejection) -> Double {
            switch try source.choose(atMost: 5) {
            case 0: return try integral(from: &source) ?? range.lowerBound
            case 1: return try fraction(from: &source) ?? range.lowerBound
            case 2, 3: return try uniform(from: &source)
            case 4: return try edge(from: &source)
            default:
                var specials: [Double] = []
                if allowNaN { specials.append(.nan) }
                if allowInfinity { specials += [.infinity, -.infinity] }
                guard !specials.isEmpty else { return try edge(from: &source) }
                // Which special, then its sign for infinities.
                let special = specials[Int(try source.choose(atMost: UInt64(specials.count - 1)))]
                let negative = try source.choose(atMost: 1) == 1
                return special.isInfinite && negative ? -special : special
            }
        }

        /// An integer in the range, shrinking toward zero, or nil if the range holds none.
        private func integral(from source: inout Source) throws(Rejection) -> Double? {
            // Every integer within ±2^53 is representable.
            let limit = 9_007_199_254_740_992.0
            let lower = Swift.max(range.lowerBound, -limit).rounded(.up)
            let upper = Swift.min(range.upperBound, limit).rounded(.down)
            guard lower <= upper else { return nil }
            return Double(try Integers(range: Int64(lower)...Int64(upper)).generate(from: &source))
        }

        /// A multiple of a power of two from 1/2 to 1/1024, or nil if the range holds none.
        private func fraction(from source: inout Source) throws(Rejection) -> Double? {
            let scale = Double(1 << (1 + Int(try source.choose(atMost: 9))))
            let limit = 9_007_199_254_740_992.0
            let lower = Swift.max(range.lowerBound * scale, -limit).rounded(.up)
            let upper = Swift.min(range.upperBound * scale, limit).rounded(.down)
            guard lower.isFinite, upper.isFinite, lower <= upper else { return nil }
            let numerator = try Integers(range: Int64(lower)...Int64(upper)).generate(from: &source)
            return Double(numerator) / scale
        }

        /// A value spread uniformly across the range.
        private func uniform(from source: inout Source) throws(Rejection) -> Double {
            // 53 random bits, drawn as high and low halves.
            let high = try source.choose(atMost: (1 << 26) - 1)
            let low = try source.choose(atMost: (1 << 27) - 1)
            let fraction = Double(high << 27 | low) / Double(1 << 53)
            // Interpolating this way can't overflow, even across the whole finite range.
            let value = range.lowerBound * (1 - fraction) + range.upperBound * fraction
            return Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
        }

        /// A boundary value: zero or the smallest magnitudes, or the range's ends and their
        /// neighbors. Draws which group, then which value in it.
        private func edge(from source: inout Source) throws(Rejection) -> Double {
            let nearZero = [0.0, -0.0, .leastNonzeroMagnitude, -.leastNonzeroMagnitude].filter {
                range.contains($0)
            }
            var ends = [range.lowerBound, range.upperBound]
            if range.lowerBound.nextUp <= range.upperBound { ends.append(range.lowerBound.nextUp) }
            if range.upperBound.nextDown >= range.lowerBound {
                ends.append(range.upperBound.nextDown)
            }
            // Always draw the group, so edges take as many choices as other kinds.
            let wantsEnds = try source.choose(atMost: 1) == 1
            let group = wantsEnds || nearZero.isEmpty ? ends : nearZero
            return group[Int(try source.choose(atMost: UInt64(group.count - 1)))]
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
