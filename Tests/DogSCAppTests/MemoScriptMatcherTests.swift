import Foundation
import RecorderCore
import XCTest
@testable import DogSCApp

final class MemoScriptMatcherTests: XCTestCase, @unchecked Sendable {
    private let passage = "最后检查录制画面和麦克风声音，确认已经做好准备工作。"

    func testSubTickPartialBurstRetainsEvidenceAndProcessesItsTail() async throws {
        let script = "先把内容粘贴到备忘录里，然后打开语音跟读开关。接下来可以从文稿中间开始朗读，软件会自动找到对应的句子。" + passage
        let input = AsyncThrowingStream<MemoSpeechText, any Error>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let matcher = MemoScriptMatcher(text: script, anchor: nil)
        let output = await matcher.matches(from: input.stream)
        // All revisions arrive well within one 125 ms matching tick.
        for (revision, length) in [12, 16, 20, passage.count].enumerated() {
            input.continuation.yield(MemoSpeechText(text: String(passage.prefix(length)), isFinal: false,
                revision: UInt64(revision + 1), timestamp: ProcessInfo.processInfo.systemUptime))
            try await Task.sleep(for: .milliseconds(5))
        }
        input.continuation.finish()
        var reliable: [ScriptMatch] = []
        for try await match in output where match.isTracking { reliable.append(match) }
        XCTAssertFalse(reliable.isEmpty)
        let range = try XCTUnwrap(reliable.last?.sentenceRange)
        XCTAssertEqual((script as NSString).substring(with: range), passage)
    }

    func testRetryingOnePartialDoesNotInventConfirmation() async throws {
        let input = AsyncThrowingStream<MemoSpeechText, any Error>.makeStream()
        let matcher = MemoScriptMatcher(text: passage, anchor: nil)
        let output = await matcher.matches(from: input.stream)
        input.continuation.yield(MemoSpeechText(text: passage, isFinal: false, revision: 1, timestamp: 0))
        input.continuation.finish()
        for try await match in output { XCTAssertFalse(match.isTracking) }
    }
}
