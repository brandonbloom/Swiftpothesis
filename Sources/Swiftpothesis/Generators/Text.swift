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

    /// Unicode scalars, shrinking toward `"0"`.
    ///
    /// TODO: Accept Unicode general categories and explicit alphabets, as Hypothesis's
    /// `characters()` does.
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
