extension Generator {
    /// Strings of Unicode scalars, shrinking toward shorter strings of ASCII digits.
    ///
    /// Generated strings favor printable ASCII but regularly include whitespace, quotes,
    /// backslashes, control characters, combining marks, and scalars outside the Basic
    /// Multilingual Plane, where text-handling bugs tend to be.
    public static func strings(
        of scalars: Generators.UnicodeScalars = .unicodeScalars(), count: ClosedRange<Int> = 0...50
    ) -> Self where Self == Generators.Strings {
        Generators.Strings(scalars: Generators.Arrays(element: scalars, count: count))
    }

    /// Unicode scalars, shrinking toward `"0"`.
    public static func unicodeScalars() -> Self where Self == Generators.UnicodeScalars {
        Generators.UnicodeScalars()
    }
}

extension Generators {
    /// A generator of strings. See ``Generator/strings(of:count:)``.
    public struct Strings: Generator {
        let scalars: Arrays<UnicodeScalars>

        public func generate(from source: inout Source) throws(Rejection) -> String {
            var string = String.UnicodeScalarView()
            string.append(contentsOf: try scalars.generate(from: &source))
            return String(string)
        }
    }

    /// A generator of Unicode scalars. See ``Generator/unicodeScalars()``.
    ///
    /// TODO: Accept Unicode general categories and explicit alphabets, as Hypothesis's
    /// `characters()` does.
    public struct UnicodeScalars: Generator {
        // Scalars that commonly break text handling, tried often during generation.
        static let special: [Unicode.Scalar] = [
            " ", "\n", "\r", "\t", "\0", "\"", "'", "\\", "$", "`", "%", "\u{7F}", "\u{A0}",
            "\u{301}", "\u{200B}", "\u{200D}", "\u{FEFF}", "\u{FFFD}", "\u{1F600}",
        ]

        public func generate(from source: inout Source) throws(Rejection) -> Unicode.Scalar {
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
