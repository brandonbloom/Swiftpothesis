import Swiftpothesis
import Testing

/// Spellings that documentation shows, kept compiling. Uses a plain import, as users do.
struct SpellingTests {
    indirect enum Tree {
        case leaf(Int)
        case node(Tree, Tree)
    }

    struct Person: Arbitrary {
        var name: String
        var age: Int

        static var arbitrary: some Generator<Person> {
            zip(String.arbitrary, Int.arbitrary(in: 0...120)).map(Person.init)
        }

        static func arbitrary(adultsOnly: Bool) -> some Generator<Person> {
            zip(String.arbitrary, Int.arbitrary(in: adultsOnly ? 18...120 : 0...120))
                .map(Person.init)
        }
    }

    @Test func combinators() async {
        let pairs = zip(Int.arbitrary(in: 0...9), String.arbitrary)
        let nonEmpty = [Bool].arbitrary(count: 0...10).filter { !$0.isEmpty }
        let trees = recursive(base: Int.arbitrary(in: 0...9).map(Tree.leaf)) {
            subtree in zip(subtree, subtree).map(Tree.node)
        }
        let sums = zip(Int.arbitrary(in: 0...9), Int.arbitrary(in: 0...9)).map { a, b in a + b }
        let sentinel = oneOf(Int.arbitrary(in: 0...9), constant(-1))
        await forAll(pairs, nonEmpty, trees, sums, sentinel) { _, array, _, _, _ in
            #expect(!array.isEmpty)
        }
    }

    @Test func typeOwnedGenerators() async {
        await forAll(
            [Int].arbitrary(Int.arbitrary(in: 0...9), count: 1...5),
            Set<String>.arbitrary(String.arbitrary(count: 1...4)),
            [String: Int].arbitrary(keys: String.arbitrary(count: 1...4), values: Int.arbitrary),
            Int?.arbitrary(Int.arbitrary(in: 0...9)),
            Double.arbitrary(in: 0...1)
        ) { digits, _, _, _, fraction in
            #expect(digits.allSatisfy { (0...9).contains($0) })
            #expect((0...1).contains(fraction))
        }
    }

    @Test func customTypes() async {
        await forAll(Person.arbitrary(adultsOnly: true)) { adult in
            #expect(adult.age >= 18)
        }
        await forAll { (people: [Person]) in
            #expect(people.allSatisfy { $0.age <= 120 })
        }
    }
}
