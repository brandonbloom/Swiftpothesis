import Foundation

extension Data: Arbitrary {
    /// Up to 100 arbitrary bytes, shrinking toward fewer, smaller bytes.
    public static var arbitrary: some Generator<Data> { arbitrary(count: 0...100) }

    /// Arbitrary bytes, with a number of bytes in `count`.
    public static func arbitrary(count: ClosedRange<Int>) -> some Generator<Data> {
        [UInt8].arbitrary(UInt8.arbitrary, count: count).map { Data($0) }
    }
}
