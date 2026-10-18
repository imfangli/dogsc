import Foundation
import RecorderCore
import XCTest
@testable import DogSCApp

final class SubtitleAIBatchingTests: XCTestCase {
    func testSentenceBoundaryNearCapacityKeepsFollowingPhraseTogether() {
        let words = makeWords(["前", "面", "说", "完。", "再", "说", "问", "题", "这", "里"])
        let ranges = batches(words, units: 7)
        XCTAssertEqual(ranges, [0..<4, 4..<10])
        XCTAssertEqual(ranges.flatMap { Array(words[$0]).map(\.id) }, words.map(\.id))
    }

    func testSentenceHasPriorityOverLaterPauseAndClausePunctuation() {
        var words = makeWords(["一", "二", "三", "句末。", "五", "分句，", "七", "八", "九"])
        shift(words: &words, from: 6, by: 0.75)
        XCTAssertEqual(batches(words, units: 8), [0..<4, 4..<9])
    }

    func testMeaningfulPauseHasPriorityOverLaterClausePunctuation() {
        var words = makeWords(["一", "二", "三", "四", "五", "六", "分句，", "八", "九"])
        shift(words: &words, from: 5, by: 0.75)
        XCTAssertEqual(batches(words, units: 8), [0..<5, 5..<9])
    }

    func testClauseBoundaryUsedWhenThereIsNoSentenceOrPause() {
        let words = makeWords(["一", "二", "三", "四", "分句，", "六", "七", "八", "九"])
        XCTAssertEqual(batches(words, units: 8), [0..<5, 5..<9])
    }

    func testEarlyPunctuationDoesNotCreateTinyRequests() {
        let words = makeWords(["句末。", "二", "三", "四", "五", "六", "七", "八", "九"])
        XCTAssertEqual(batches(words, units: 8), [0..<8, 8..<9])
    }

    func testNegativeHugeAndCutCrossingSourceGapsAreNotUsedAsPauses() {
        for gap in [-0.75, 3.0, 12.0] {
            var words = makeWords(Array(repeating: "字", count: 9))
            shift(words: &words, from: 5, by: gap)
            XCTAssertEqual(batches(words, units: 8), [0..<8, 8..<9])
        }
        var cutWords = makeWords(Array(repeating: "字", count: 9))
        cutWords[4].sourceRanges = [.init(start: 4, end: 4.25), .init(start: 4.75, end: 5)]
        shift(words: &cutWords, from: 5, by: 0.75)
        XCTAssertEqual(batches(cutWords, units: 8), [0..<8, 8..<9])
    }

    func testCharacterCapacityStillLimitsEveryMultiUnitBatch() {
        let words = makeWords(["甲甲", "乙乙", "丙丙", "丁丁", "戊戊", "己己", "庚庚"])
        let ranges = batches(words, units: 20, characters: 6)
        XCTAssertEqual(ranges, [0..<3, 3..<6, 6..<7])
        XCTAssertTrue(ranges.allSatisfy { words[$0].reduce(0) { $0 + $1.text.count } <= 6 })
    }

    func testOversizedUnitRemainsCompleteAndMakesProgress() {
        let words = makeWords(["甲", "完整的识别时间单元", "乙"])
        XCTAssertEqual(batches(words, units: 20, characters: 3), [0..<1, 1..<2, 2..<3])
        XCTAssertEqual(batches(words, units: 0, characters: 0), [0..<1, 1..<2, 2..<3])
    }

    func testProtectedGapIsNeverIncludedOrBridged() {
        let words = makeWords(["前。", "半句", "人工修改", "后", "半句", "末尾"])
        let ranges = SubtitleAIBatching.ranges(words: words, protectedWordIDs: [words[2].id],
            unitLimit: 4, characterLimit: 3_000)
        XCTAssertEqual(ranges, [0..<2, 3..<6])
        XCTAssertFalse(ranges.contains { $0.contains(2) })
        XCTAssertTrue(SubtitleAIBatching.ranges(words: words,
            protectedWordIDs: Set(words.map(\.id)), unitLimit: 4, characterLimit: 3_000).isEmpty)
    }

    func testNoNaturalBoundaryFallsBackToHardCapacity() {
        let words = makeWords(Array(repeating: "字", count: 11))
        XCTAssertEqual(batches(words, units: 4), [0..<4, 4..<8, 8..<11])
    }

    func testDottedAcronymSplitAcrossUnitsDoesNotBecomeBatchBoundary() {
        let words = makeWords(["前", "面", " U", ".", "S", ".", "术", "语", "继", "续"])
        XCTAssertEqual(batches(words, units: 8), [0..<8, 8..<10])
    }

    func testSentenceBoundaryRecognizesClosingQuotesAndExcludesAcronyms() {
        for text in ["完整句子。", "完整句子！ ” \n", "“说完了吗？”", "Done.\"  ", "结束…", "."] {
            XCTAssertTrue(SubtitleAIBatching.isSentenceBoundary(text), text)
        }
        for text in ["Show Speaker Notes", "这是分句，", "in the U.S.", "美国U.S.", "U.S.A.\" ", "for Dr.", "value 3.14", ""] {
            XCTAssertFalse(SubtitleAIBatching.isSentenceBoundary(text), text)
        }
    }

    func testChineseRecordingSizedFixtureAvoidsOldFortyEightUnitSeams() {
        var words = makeWords(Array(repeating: "字", count: 580))
        for boundary in [43, 82, 135, 222, 267, 319, 372, 488, 489] {
            words[boundary - 1].text = "。"
        }
        words[383].text = " show"
        words[384].text = " speakernotes"
        words[431].text = "问"
        words[432].text = "题"
        words[527].text = "中"
        words[528].text = "文"
        let original = words
        let ranges = batches(words, units: 256)
        XCTAssertEqual(ranges, [0..<222, 222..<372, 372..<580])
        for phrase in [383..<385, 431..<433, 527..<529] {
            XCTAssertTrue(ranges.contains { $0.lowerBound <= phrase.lowerBound && $0.upperBound >= phrase.upperBound })
        }
        XCTAssertEqual(words, original)
    }

    private func batches(_ words: [SubtitleWord], units: Int, characters: Int = 3_000) -> [Range<Int>] {
        SubtitleAIBatching.ranges(words: words, protectedWordIDs: [],
            unitLimit: units, characterLimit: characters)
    }

    private func makeWords(_ texts: [String]) -> [SubtitleWord] {
        texts.enumerated().map { index, text in
            SubtitleWord(text: text, sourceRanges: [.init(start: Double(index), end: Double(index + 1))])
        }
    }

    private func shift(words: inout [SubtitleWord], from start: Int, by amount: Double) {
        for index in start..<words.count {
            words[index].sourceRanges = words[index].sourceRanges.map {
                .init(start: $0.start + amount, end: $0.end + amount)
            }
        }
    }
}
