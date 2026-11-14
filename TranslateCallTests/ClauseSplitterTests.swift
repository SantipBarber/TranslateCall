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

    /// REQ-CS-03: two eligible marks: one cut only, at the first; the second stays inside part 1.
    @Test func twoEligibleMarksCutOnceAtTheFirst() {
        let text = "When we get to the station, we will call you from the taxi, and then we can talk"
        #expect(ClauseSplitter.split(text)
            == ["When we get to the station,", "we will call you from the taxi, and then we can talk"])
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

    // MARK: - A later part's translation continues the sentence (lowercase start)

    @Test func continuingLowercasesWhenTheSourceStartsLowercase() {
        #expect(ClauseSplitter.continuing("Los estilos en Occidente", source: "styles in the West")
            == "los estilos en Occidente")
        #expect(ClauseSplitter.continuing("Él irá mañana", source: "he will go tomorrow") == "él irá mañana")
    }

    @Test func continuingKeepsAProperNounOfTheSource() {
        #expect(ClauseSplitter.continuing("Berlín no está cerca", source: "Berlin is nowhere near")
            == "Berlín no está cerca")
        #expect(ClauseSplitter.continuing("I will call", source: "I will call") == "I will call")
    }

    /// "the West" → "Occidente": an article before a capitalised word is likely a name the translation leads with.
    @Test func continuingKeepsANameAfterASourceArticle() {
        #expect(ClauseSplitter.continuing("Occidente se encontró", source: "the West found itself")
            == "Occidente se encontró")
    }

    @Test func continuingKeepsAnAcronymAndEdgeCases() {
        #expect(ClauseSplitter.continuing("EE. UU. dijo", source: "the us said") == "EE. UU. dijo")
        #expect(ClauseSplitter.continuing("OTAN dijo", source: "nato said") == "OTAN dijo")
        #expect(ClauseSplitter.continuing("", source: "styles") == "")
        #expect(ClauseSplitter.continuing("ya está", source: "it is done") == "ya está")
    }
}
