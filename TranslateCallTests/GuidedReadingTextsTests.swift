import Foundation
import Testing
@testable import TranslateCall

@Suite("GuidedReadingTexts")
struct GuidedReadingTextsTests {
    private static let cjk: Set<String> = ["chinese", "japanese", "korean"]
    private static let keys = QwenCloneConfiguration.supportedLanguageList.map(\.key)

    @Test func everyLanguageHasText() {
        let english = GuidedReadingTexts.text(for: "english")
        for key in Self.keys {
            let text = GuidedReadingTexts.text(for: key)
            #expect(!text.isEmpty, "\(key) is empty")
            if key != "english" { #expect(text != english, "\(key) equals English") }
        }
    }

    @Test func lengthMatchesTarget() {
        let seconds = QwenCloneConfiguration.guidedTargetSeconds
        for key in Self.keys {
            let text = GuidedReadingTexts.text(for: key)
            let isCJK = Self.cjk.contains(key)
            let count = isCJK
                ? text.filter { !$0.isWhitespace }.count
                : text.split(whereSeparator: \.isWhitespace).count
            let expected = seconds * (isCJK ? 5 : 2.5)
            #expect(
                Double(count) >= expected * 0.7 && Double(count) <= expected * 1.3,
                "\(key): \(count) vs \(expected)"
            )
        }
    }

    @Test func noDigits() {
        for key in Self.keys {
            #expect(!GuidedReadingTexts.text(for: key).contains { $0.isASCIIDigit }, "\(key)")
        }
    }

    @Test func unknownLanguageFallsBackToEnglish() {
        #expect(GuidedReadingTexts.text(for: "klingon") == GuidedReadingTexts.text(for: "english"))
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
