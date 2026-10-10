import XCTest
@testable import RecorderCore

final class SpeechTranscriptWindowTests: XCTestCase {
    func testPartialIsReplacedAndFinalDoesNotDuplicateIt() {
        var window = SpeechTranscriptWindow()
        window.update(text: "苹果语音", start: 0, end: 1, isFinal: false)
        window.update(text: "苹果语音识别", start: 0, end: 2, isFinal: false)
        window.update(text: "苹果语音识别模型", start: 0, end: 3, isFinal: true)
        XCTAssertEqual(window.text, "苹果语音识别模型")
        XCTAssertTrue(window.isFinal)
        XCTAssertFalse(window.update(text: "旧结果", start: 0, end: 2, isFinal: false))
        XCTAssertEqual(window.text, "苹果语音识别模型")
    }

    func testFinalizationOfOlderAudioPreservesNewerPartial() {
        var window = SpeechTranscriptWindow()
        window.update(text: "第一句话", start: 0, end: 2, isFinal: false)
        window.update(text: "第二句话", start: 2, end: 4, isFinal: false)
        window.update(text: "第一句完成", start: 0, end: 2, isFinal: true)
        XCTAssertEqual(window.text, "第一句完成 第二句话")
        XCTAssertFalse(window.isFinal)
    }

    func testOldResultsOutsideWindowAndInvalidTimesAreIgnored() {
        var window = SpeechTranscriptWindow(duration: 8)
        window.update(text: "旧句子", start: 0, end: 1, isFinal: true)
        window.update(text: "现在的句子", start: 10, end: 12, isFinal: false)
        XCTAssertEqual(window.text, "现在的句子")
        XCTAssertFalse(window.update(text: "迟到的旧句", start: 0, end: 1, isFinal: true))
        XCTAssertFalse(window.update(text: "坏时间", start: .nan, end: 4, isFinal: true))
        XCTAssertEqual(window.text, "现在的句子")
    }
}
