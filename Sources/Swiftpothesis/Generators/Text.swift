extension String {
    /// Strings of generated Unicode scalars, shrinking toward shorter, simpler strings.
    public static func arbitrary(
        _ scalars: some Generator<Unicode.Scalar>, count: ClosedRange<Int> = 0...50
    ) -> some Generator<String> {
        Generators.Strings(
            scalars: Generators.Arrays(element: scalars, count: count, averageCount: nil))
    }

    /// Arbitrary strings with a number of Unicode scalars in `count`.
    public static func arbitrary(count: ClosedRange<Int>) -> some Generator<String> {
        arbitrary(Unicode.Scalar.arbitrary, count: count)
    }

    /// Strings of scalars from `alphabet`, shrinking toward shorter strings of its first scalar.
    ///
    /// Small alphabets make collisions and edge cases likely, such as testing that file names
    /// stay distinct:
    ///
    /// ```swift
    /// String.arbitrary(alphabet: "aA.:? ", count: 1...3)
    /// ```
    public static func arbitrary(alphabet: String, count: ClosedRange<Int> = 0...50)
        -> some Generator<String>
    {
        arbitrary(Unicode.Scalar.arbitrary(from: alphabet), count: count)
    }
}

extension Unicode.Scalar {
    /// Scalars from `alphabet`, shrinking toward its first.
    public static func arbitrary(from alphabet: String) -> some Generator<Unicode.Scalar> {
        precondition(
            !alphabet.isEmpty, "Unicode.Scalar.arbitrary(from:) requires a nonempty alphabet")
        return element(of: Array(alphabet.unicodeScalars))
    }

    /// Scalars in a range, shrinking toward its lower bound. Surrogate code points, which aren't
    /// scalars, are skipped.
    public static func arbitrary(in range: ClosedRange<Unicode.Scalar>)
        -> some Generator<Unicode.Scalar>
    {
        let lower = range.lowerBound.value
        let upper = range.upperBound.value
        // The surrogates within the range, which can't be scalars.
        let gapStart = Swift.max(lower, 0xD800)
        let gap = Swift.max(0, Int(Swift.min(upper, 0xDFFF)) - Int(gapStart) + 1)
        let count = Int(upper - lower) + 1 - gap
        return Int.arbitrary(in: 0...(count - 1)).map { offset in
            let value = lower + UInt32(offset)
            // Offsets at or past the surrogates skip over them.
            return Unicode.Scalar(gap > 0 && value >= gapStart ? value + UInt32(gap) : value)!
        }
    }

    /// Scalars in any of the Unicode general `categories`, within `range`, shrinking toward the
    /// lowest.
    ///
    /// ```swift
    /// Unicode.Scalar.arbitrary(categories: [.uppercaseLetter, .otherPunctuation])
    /// ```
    ///
    /// The matching scalars are found once, when the generator is created.
    public static func arbitrary(
        categories: Set<Unicode.GeneralCategory>,
        in range: ClosedRange<Unicode.Scalar> = "\u{0}"..."\u{10FFFF}"
    ) -> some Generator<Unicode.Scalar> {
        let matching = (range.lowerBound.value...range.upperBound.value).compactMap { value in
            Unicode.Scalar(value).flatMap {
                categories.contains($0.properties.generalCategory) ? $0 : nil
            }
        }
        precondition(!matching.isEmpty, "No scalars in \(range) are in the given categories")
        return element(of: matching)
    }
}

extension Generators {
    struct Strings<Scalars: Generator<Unicode.Scalar>>: Generator {
        let scalars: Arrays<Scalars>

        func generate(from source: inout Source) throws(Rejection) -> String {
            var string = String.UnicodeScalarView()
            string.append(contentsOf: try scalars.generate(from: &source))
            return String(string)
        }
    }

    /// Unicode scalars, shrinking toward `"0"`. For other scalars, see
    /// `Unicode.Scalar.arbitrary(from:)`, `arbitrary(in:)`, and `arbitrary(categories:in:)`.
    struct UnicodeScalars: Generator {
        // Scalars that commonly break text handling, tried often during generation.
        static let special: [Unicode.Scalar] = [
            " ", "\n", "\r", "\t", "\0", "\"", "'", "\\", "$", "`", "%", "\u{7F}", "\u{A0}",
            "\u{301}", "\u{200B}", "\u{200D}", "\u{FEFF}", "\u{FFFD}", "\u{1F600}",
        ]

        func generate(from source: inout Source) throws(Rejection) -> Unicode.Scalar {
            switch try source.choose(atMost: 3) {
            case 0:
                // Printable ASCII, ordered so that the simplest choice is "0".
                let offset = try source.choose(atMost: 94)
                return Unicode.Scalar(UInt8(offset < 0x4F ? 0x30 + offset : offset - 0x2F))
            case 1:
                return Self.special[Int(try source.choose(atMost: UInt64(Self.special.count - 1)))]
            default:
                let value = try source.choose(atMost: 0x10FFFF)
                // Surrogates aren't scalars; map them into the private use area instead.
                return Unicode.Scalar(UInt32(value)) ?? Unicode.Scalar(
                    0xE000 + UInt32(value & 0x7FF))!
            }
        }
    }
}
