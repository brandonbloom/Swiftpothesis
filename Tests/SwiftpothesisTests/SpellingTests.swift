import Testing

@testable import Swiftpothesis

/// Spellings that documentation shows, kept compiling.
struct SpellingTests {
    indirect enum Tree {
        case leaf(Int)
        case node(Tree, Tree)
    }

    @Test func spellings() async {
        let pairs = zip(.integers(in: 0...9), .strings())
        let nonEmpty: some Generator<[Bool]> = .arrays(of: .booleans()).filter { !$0.isEmpty }
        let trees: AnyGenerator<Tree> = .recursive(base: .integers(in: 0...9).map(Tree.leaf)) {
            subtree in zip(subtree, subtree).map(Tree.node)
        }
        let sums = zip(.integers(in: 0...9), .integers(in: 0...9)).map { a, b in a + b }
        await forAll(pairs, nonEmpty, trees, sums) { _, array, _, _ in
            #expect(!array.isEmpty)
        }
    }
}
