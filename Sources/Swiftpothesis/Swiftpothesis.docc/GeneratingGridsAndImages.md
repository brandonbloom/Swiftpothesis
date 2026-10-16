# Generating Grids and Images

Generate small two-dimensional data, and pairs of it that differ in a few cells.

## Overview

Swiftpothesis has no grid or image type of its own, because Swift has no standard one: your code has its own bitmap, matrix, or game board. Compose generators for your type from a size and its cells.

## A grid of any size

Draw the dimensions, then exactly enough cells:

```swift
struct Bitmap: Sendable {
    var width: Int
    var height: Int
    var rgba: [UInt8]  // Four bytes per pixel, row by row.
}

static var bitmaps: some Generator<Bitmap> {
    zip(Int.arbitrary(in: 1...8), Int.arbitrary(in: 1...8)).flatMap { width, height in
        let count = width * height * 4
        return [UInt8].arbitrary(UInt8.arbitrary, count: count...count).map {
            Bitmap(width: width, height: height, rgba: $0)
        }
    }
}
```

Keep grids small. A 4×4 bitmap already has 64 bytes to shrink, and most bugs show up in the smallest images: one pixel, one row, one column. Dimensions shrink toward 1×1 and bytes toward zero, so failures end as small black images, which are easy to read.

For raw bytes without structure, use `Data.arbitrary` or `Data.arbitrary(count:)`.

## Pairs that differ in a few cells

Properties of comparison and diffing code need two grids that are mostly the same. Generating them independently gives grids that differ everywhere. Instead, generate one grid and a short list of edits to apply to it:

```swift
struct Edit: Sendable {
    var pixel: Int
    var color: [UInt8]
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
                changed.rgba.replaceSubrange(edit.pixel * 4..<edit.pixel * 4 + 4, with: edit.color)
            }
            return (original, changed)
        }
    }
}
```

Because each edit is one element of an array, shrinking deletes edits whole: a failing pair shrinks toward the fewest changed pixels, often exactly one, at the first position. That makes properties such as these easy to debug when they fail. The property takes one argument per generator, so unpack a generated tuple inside it:

```swift
await forAll(Self.similarPairs) { pair in
    let (original, changed) = pair
    let diff = ImageDiff(original, changed)
    #expect(diff.changedPixels <= 6)
    #expect(diff.changedBounds.contains(allChangedPixels(original, changed)))
}
```
