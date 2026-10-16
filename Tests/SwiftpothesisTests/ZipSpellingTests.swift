import Foundation
import Swiftpothesis
import Testing

/// `zip` spellings users write, with a plain import and Foundation in scope, as most test files have.
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

    // From the "Generating Grids and Images" article.
    struct Edit: Sendable {
        var pixel: Int
        var color: [UInt8]
    }

    static var bitmaps: some Generator<Bitmap> {
        zip(Int.arbitrary(in: 1...8), Int.arbitrary(in: 1...8)).flatMap { width, height in
            let count = width * height * 4
            return [UInt8].arbitrary(UInt8.arbitrary, count: count...count).map {
                Bitmap(width: width, height: height, rgba: $0)
            }
        }
    }

    static var similarPairs: some Generator<(Bitmap, Bitmap)> {
        bitmaps.flatMap { original in
            let pixels = original.width * original.height
            let edit = zip(
                Int.arbitrary(in: 0...(pixels - 1)),
                [UInt8].arbitrary(UInt8.arbitrary, count: 4...4)
            ).map(Edit.init)
            return [Edit].arbitrary(edit, count: 0...6).map { edits in
                var changed = original
                for edit in edits {
                    changed.rgba.replaceSubrange(
                        edit.pixel * 4..<edit.pixel * 4 + 4, with: edit.color)
                }
                return (original, changed)
            }
        }
    }

    @Test func gridRecipe() async {
        await forAll(Self.similarPairs) { pair in
            let (original, changed) = pair
            let differing = (0..<(original.width * original.height)).filter {
                original.rgba[$0 * 4..<$0 * 4 + 4] != changed.rgba[$0 * 4..<$0 * 4 + 4]
            }
            #expect(differing.count <= 6)
        }
    }

    // From the "Testing That Distinct Inputs Stay Distinct" article.
    @Test func distinctnessRecipe() async {
        let names = String.arbitrary(alphabet: "aA.:?_ ", count: 1...4).withDuplicates()
        await forAll(names, names) { a, b in
            try assume(a != b)
            #expect(a != b)
        }
    }

    @Test func sharedStaticGenerators() async {
        await forAll(Self.names, Self.names) { a, b in
            #expect(a.count <= 2 && b.count <= 2)
        }
    }
}
