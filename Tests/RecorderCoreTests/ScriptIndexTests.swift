import Foundation
import XCTest
@testable import RecorderCore

final class ScriptIndexTests: XCTestCase {
    func testSentenceRangesPreserveTextAndSkipWhitespace() {
        let text = "  👨‍👩‍👧第一句。\n\n第二句含 2.50 和 GPU！ 最后一句"
        let index = ScriptIndex(text: text)
        for phrase in ["👨‍👩‍👧第一句。", "第二句含 2.50 和 GPU！", "最后一句"] {
            let range = (text as NSString).range(of: phrase)
            XCTAssertEqual(index.sentenceRange(atUTF16Offset: range.location), range)
            XCTAssertEqual(index.sentenceRange(atUTF16Offset: NSMaxRange(range) - 1), range)
        }
        XCTAssertNil(ScriptIndex(text: " \n ").sentenceRange(atUTF16Offset: 0))
    }

    func testCommonNumbersHaveEquivalentUnitsWithOriginalRanges() {
        let pairs = [("2026", "二零二六"), ("120", "一百二十"), ("2.50", "二点五"),
                     ("3%", "百分之三"), ("６", "六"), ("120000000", "一亿二千万"),
                     ("-3.5", "负三点五"), ("3,000", "三千")]
        for (written, spoken) in pairs {
            let writtenUnits = ScriptNormalizer.units(in: written)
            let spokenUnits = ScriptNormalizer.units(in: spoken)
            XCTAssertEqual(writtenUnits.map(\.value), spokenUnits.map(\.value), "\(written) / \(spoken)")
            XCTAssertEqual(writtenUnits.first?.range, NSRange(location: 0, length: written.utf16.count))
            XCTAssertEqual(spokenUnits.first?.range, NSRange(location: 0, length: spoken.utf16.count))
        }
    }

    func testAllMappedRangesUseGraphemeBoundaries() {
        let text = "👩🏽‍💻使用 Ｓｗｉｆｔ 与 e\u{301}、GPU，以及百分之三。"
        let index = ScriptIndex(text: text)
        for unit in index.units { XCTAssertNotNil(Range(unit.range, in: text)) }
        XCTAssertEqual(index.text, text)
        XCTAssertEqual(ScriptNormalizer.units(in: "SpeechAnalyzer GPU").map(\.value),
            ScriptNormalizer.units(in: "speech analyzer g p u").map(\.value))
    }
}
