import Foundation
import Swiftpothesis
import Testing

/// `zip` spellings users write, with a plain import and Foundation in scope, as SwiftBook has.
struct ZipSpellingTests {
    struct Bitmap: Sendable {
        var width: Int
        var height: Int
        var rgba: [UInt8]
    }

    static var names: some Generator<String> { String.arbitrary(alphabet: "mM", count: 1...2) }

    @Test func twoArgumentZip() async {
        let sizes = zip(Int.arbitrary(in: 1...6), Int.arbitrary(in: 1...6))
        await forAll(sizes) { size in #expect(size.0 >= 1 && size.1 >= 1) }
    }

    @Test func destructuringInFlatMap() async {
        let bitmaps = zip(Int.arbitrary(in: 1...4), Int.arbitrary(in: 1...4)).flatMap { size in
            let (w, h) = size
            return [UInt8].arbitrary(UInt8.arbitrary, count: (w * h * 4)...(w * h * 4)).map {
                Bitmap(width: w, height: h, rgba: $0)
            }
        }
        await forAll(bitmaps) { bitmap in
            #expect(bitmap.rgba.count == bitmap.width * bitmap.height * 4)
        }
    }

    @Test func separateArgumentsInMapAndFlatMap() async {
        let areas = zip(Int.arbitrary(in: 1...4), Int.arbitrary(in: 1...4)).map { w, h in w * h }
        let lists = zip(Int.arbitrary(in: 0...3), Bool.arbitrary).flatMap { n, flag in
            [Bool].arbitrary(constant(flag), count: n...n)
        }
        await forAll(areas, lists) { area, list in
            #expect(area >= 1)
            #expect(list.count <= 3)
        }
    }

    @Test func sharedStaticGenerators() async {
        await forAll(Self.names, Self.names) { a, b in
            #expect(a.count <= 2 && b.count <= 2)
        }
    }
}
