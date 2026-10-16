# Testing That Distinct Inputs Stay Distinct

Find the rare inputs that collide, such as two names that map to the same file.

## Overview

Many properties say that a function keeps different inputs apart: distinct identifiers give distinct paths, distinct records give distinct keys, a cache never confuses two requests. In other words, the function is *injective*. These properties are easy to state and hard to falsify with random inputs, because two independently generated values almost never collide or nearly match. Most test cases compare `"q7Lz"` with `"x"`, and the bug, `"Card"` against `"card"`, is never tried.

The fix is to generate inputs that are related on purpose. Three techniques help, in increasing order of effort.

## Make collisions likely with small alphabets

Collisions in text usually come from a handful of characters: case, punctuation, separators, trailing dots and spaces. Generate strings from just those, and keep them short:

```swift
static var names: some Generator<String> {
    String.arbitrary(alphabet: "aA.:?_ ", count: 1...4)
}
```

With seven characters and at most four of them, even independent pairs collide often, and every failure shrinks to a couple of characters.

## Duplicate earlier values

``Generator/withDuplicates(probability:)`` makes a generator sometimes produce a copy of a value it already produced in the same test case, or a near copy that differs in one choice, such as one character. Use the same generator for every argument that should share values:

```swift
@Test func distinctNamesGetDistinctFileNames() async {
    let names = Self.names.withDuplicates()
    await forAll(names, names) { a, b in
        try assume(a != b)
        #expect(fileName(for: a) != fileName(for: b))
    }
}
```

Exact copies are discarded by the `assume`, so they cost little: discarded test cases don't count toward ``Settings/maxExamples``. Near copies are what find the bug. When an alphabet lists case variants next to each other, as `"aAbB"` does, a near copy is often the same name with one letter's case changed.

## Generate one value from the other

When you know which variations matter, build the second value from the first:

```swift
enum Variation: CaseIterable { case uppercased, trailingDot, trailingSpace, colonToQuestionMark }

let pairs = zip(Self.names, element(of: Variation.allCases)).map { name, variation in
    (name, apply(variation, to: name))
}
```

This tests exactly the variations you list, and nothing else, so combine it with the techniques above.

## Steer the search

When distinctness depends on a measurable closeness, such as a hash function's output bits, ``target(_:label:)`` can climb toward collisions. Score how close two outputs come, such as the number of leading bits they share, and the target phase mutates the best pairs it finds.
