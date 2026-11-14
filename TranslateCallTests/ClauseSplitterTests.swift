import Testing
@testable import TranslateCall

@Suite("ClauseSplitter (REQ-CS-01…04)")
struct ClauseSplitterTests {
    @Test func splitsAtFirstEligibleComma() {
        let text = "When we get to the station, we will call you from the taxi"
        #expect(ClauseSplitter.split(text) == ["When we get to the station,", "we will call you from the taxi"])
    }

    @Test func elevenWordsWhole() { // "…, we will call you soon": 11 words
        let text = "When we get to the station, we will call you soon"
        #expect(ClauseSplitter.split(text) == [text])
    }

    @Test func tooFewBeforeSkipsToNext() {
        let text = "Yes, I really think so, we can meet tomorrow at the main square"
        #expect(ClauseSplitter.split(text) == ["Yes, I really think so,", "we can meet tomorrow at the main square"])
    }

    @Test func tooFewAfterWhole() { // 3 words after the only eligible mark
        let text = "We can meet tomorrow at the main square near the station; fine by me"
        #expect(ClauseSplitter.split(text) == [text])
    }

    @Test func semicolonAndColon() {
        #expect(
            ClauseSplitter.split("We can meet tomorrow at the main square near the station; it works for me").count == 2
        )
        let colon = "There is one thing I need to tell you now: the meeting is cancelled today"
        #expect(ClauseSplitter.split(colon) == ["There is one thing I need to tell you now:", "the meeting is cancelled today"])
    }

    @Test(arguments: [
        "The price went up from 3,5 euros to more than four euros this week",
        "The meeting starts at 10:30 in the big room on the second floor today",
        "Please open http://example.com/a,b before the call starts and tell me what you see",
    ])
    func innerMarksIgnored(_ text: String) {
        #expect(ClauseSplitter.split(text) == [text])
    }

    @Test func roundTrip() {
        let text = "  When we get to   the station,  we will call you from the taxi "
        let parts = ClauseSplitter.split(text)
        #expect(parts.count == 2)
        #expect(parts.joined(separator: " ") == text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }
}
