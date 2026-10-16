import Testing

@testable import Swiftpothesis

@Suite(.propertyOverrides { $0.database = nil })
struct ExplainTests {
    @Test func reportsArgumentsTheFailureDoesntDependOn() async {
        let issues = await failures {
            await forAll(Int.arbitrary(in: 0...100), String.arbitrary, Bool.arbitrary) { x, _, _ in
                #expect(x < 10)
            }
        }
        #expect(issues.last?.contains("doesn't depend on arguments 2 and 3") == true)
    }

    @Test func staysQuietWhenEveryArgumentMatters() async {
        let issues = await failures {
            await forAll(Int.arbitrary(in: 0...100), Int.arbitrary(in: 0...100)) { x, y in
                #expect(x + y < 50 || x < 20 || y < 20)
            }
        }
        #expect(issues.last?.contains("Explanation") == false)
    }

    @Test func doesntExplainInsideASingleArgument() async {
        // One argument whose elements are zips, such as a list of records.
        let stories = [String].arbitrary(
            zip(String.arbitrary(count: 0...2), Int.arbitrary(in: 0...9)).map { "\($0)\($1)" },
            count: 0...5)
        let issues = await failures {
            await forAll(stories) { list in #expect(list.count < 3) }
        }
        #expect(issues.last?.contains("Explanation") == false)
    }

    @Test func explainsOnlyMultipleArguments() async {
        let issues = await failures {
            await forAll(Int.arbitrary(in: 0...100)) { x in #expect(x < 10) }
        }
        #expect(issues.last?.contains("Explanation") == false)
    }
}
