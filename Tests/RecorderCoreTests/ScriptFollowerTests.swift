import Foundation
import XCTest
@testable import RecorderCore

final class ScriptFollowerTests: XCTestCase {
    private let first = "今天我们先介绍录屏工具如何帮助大家完成演示。"
    private let middle = "语音识别可以根据正在朗读的内容自动定位稿件位置。"
    private let last = "最后我们讨论英文术语和数字混排时的高亮效果。"
    private var separator: String { String(repeating: "甲乙丙丁戊己庚辛", count: 20) + "。" }

    func testStartsInMiddleAndJumpsBothDirectionsWithoutChangingScript() {
        let text = first + separator + middle + separator + last
        let index = ScriptIndex(text: text)
        var follower = ScriptFollower(index: index)
        let initial = follower.update(text: middle, isFinal: true, revision: 1, timestamp: 0)
        XCTAssertTrue(initial.isTracking)
        XCTAssertEqual(sentence(initial, in: text), middle)
        let forward = follower.update(text: last, isFinal: true, revision: 2, timestamp: 1)
        XCTAssertTrue(forward.isTracking)
        XCTAssertEqual(sentence(forward, in: text), last)
        let backward = follower.update(text: first, isFinal: true, revision: 3, timestamp: 2)
        XCTAssertTrue(backward.isTracking)
        XCTAssertEqual(sentence(backward, in: text), first)
        XCTAssertEqual(index.text, text)
    }

    func testPartialNeedsAdditionalMatchingTextAndFinalConfirmsWhenSearchIsDue() {
        var follower = ScriptFollower(index: ScriptIndex(text: middle))
        let initial = follower.update(text: String(middle.prefix(14)), isFinal: false, revision: 1, timestamp: 0)
        XCTAssertFalse(initial.isTracking)
        XCTAssertNil(initial.matchedRange)
        let repeated = follower.update(text: String(middle.prefix(14)), isFinal: false, revision: 2, timestamp: 0.6)
        XCTAssertFalse(repeated.isTracking)
        let extended = follower.update(text: String(middle.prefix(18)), isFinal: false, revision: 3, timestamp: 1.2)
        XCTAssertTrue(extended.isTracking)
        XCTAssertEqual(matched(extended, in: middle), String(middle.prefix(18)))

        follower.reset()
        _ = follower.update(text: String(middle.prefix(14)), isFinal: false, revision: 1, timestamp: 0)
        let earlyFinal = follower.update(text: String(middle.prefix(14)), isFinal: true, revision: 2, timestamp: 0.01)
        XCTAssertFalse(earlyFinal.isTracking)
        let final = follower.update(text: String(middle.prefix(14)), isFinal: true, revision: 2, timestamp: 0.5)
        XCTAssertTrue(final.isTracking)
    }

    func testRemotePartialAlsoNeedsNewEvidence() {
        let text = first + separator + middle
        var follower = ScriptFollower(index: ScriptIndex(text: text))
        _ = follower.update(text: first, isFinal: true, revision: 1, timestamp: 0)
        let pending = follower.update(text: String(middle.prefix(14)), isFinal: false, revision: 2, timestamp: 1)
        XCTAssertFalse(pending.isTracking)
        XCTAssertEqual(sentence(pending, in: text), first)
        let confirmed = follower.update(text: String(middle.prefix(18)), isFinal: false, revision: 3, timestamp: 1.6)
        XCTAssertTrue(confirmed.isTracking)
        XCTAssertEqual(sentence(confirmed, in: text), middle)
    }

    func testOneUnitPartialExtensionsAccumulateInitialLockEvidence() {
        var follower = ScriptFollower(index: ScriptIndex(text: middle))
        for length in 12...16 {
            let result = follower.update(text: String(middle.prefix(length)), isFinal: false,
                revision: UInt64(length), timestamp: Double(length - 12) * 0.6)
            XCTAssertEqual(result.isTracking, length == 16, "partial length \(length)")
            if length == 16 { XCTAssertEqual(matched(result, in: middle), String(middle.prefix(length))) }
            else { XCTAssertNil(result.matchedRange) }
        }
    }

    func testOneUnitPartialExtensionsAccumulateRemoteJumpEvidence() {
        let text = first + separator + middle
        var follower = ScriptFollower(index: ScriptIndex(text: text))
        _ = follower.update(text: first, isFinal: true, revision: 1, timestamp: 0)
        for length in 12...16 {
            let result = follower.update(text: String(middle.prefix(length)), isFinal: false,
                revision: UInt64(length), timestamp: 1 + Double(length - 12) * 0.6)
            XCTAssertEqual(result.isTracking, length == 16, "partial length \(length)")
            XCTAssertEqual(sentence(result, in: text), length == 16 ? middle : first)
        }
    }

    func testPartialRetractionReplacesInitialEvidenceBaseline() {
        var follower = ScriptFollower(index: ScriptIndex(text: middle))
        let lengths = [14, 15, 12, 13, 14, 15, 16]
        for (revision, length) in lengths.enumerated() {
            let result = follower.update(text: String(middle.prefix(length)), isFinal: false,
                revision: UInt64(revision), timestamp: Double(revision) * 0.6)
            XCTAssertEqual(result.isTracking, revision == lengths.count - 1)
        }
    }

    func testDuplicateSentencesWaitForContextAndManualAnchorResolvesThem() {
        let repeated = "我们通过语音识别自动定位正在朗读的稿件内容。"
        let unique = "接下来讨论不同权限下麦克风设备的使用方法。"
        let text = repeated + separator + repeated + unique
        var follower = ScriptFollower(index: ScriptIndex(text: text))
        let ambiguous = follower.update(text: repeated, isFinal: true, revision: 1, timestamp: 0)
        XCTAssertFalse(ambiguous.isTracking)
        XCTAssertNil(ambiguous.matchedRange)
        let located = follower.update(text: repeated + unique, isFinal: true, revision: 2, timestamp: 1)
        XCTAssertTrue(located.isTracking)
        XCTAssertEqual(sentence(located, in: text), unique)

        follower.reset()
        let secondOffset = (repeated + separator as NSString).length
        follower.anchor(atUTF16Offset: secondOffset)
        let anchored = follower.update(text: repeated, isFinal: true, revision: 1, timestamp: 0)
        XCTAssertTrue(anchored.isTracking)
        XCTAssertGreaterThanOrEqual(anchored.matchedRange?.location ?? 0, secondOffset)
    }

    func testOffScriptSpeechAndShortWordsRetainLastStablePosition() {
        var follower = ScriptFollower(index: ScriptIndex(text: middle))
        let stable = follower.update(text: middle, isFinal: true, revision: 1, timestamp: 0)
        let offScript = follower.update(text: "冰箱里的水果应该明天下午去超市买一些回来", isFinal: true, revision: 2, timestamp: 1)
        XCTAssertFalse(offScript.isTracking)
        XCTAssertEqual(offScript.matchedRange, stable.matchedRange)
        let short = follower.update(text: "好的我们", isFinal: true, revision: 3, timestamp: 2)
        XCTAssertFalse(short.isTracking)
        XCTAssertEqual(short.matchedRange, stable.matchedRange)
        let resumed = follower.update(text: middle, isFinal: true, revision: 4, timestamp: 3)
        XCTAssertTrue(resumed.isTracking)
    }

    func testPartialCorrectionIsReplacementAndOldRevisionIsIgnored() {
        let text = first + separator + middle
        var follower = ScriptFollower(index: ScriptIndex(text: text))
        let stable = follower.update(text: first, isFinal: true, revision: 10, timestamp: 0)
        let stale = follower.update(text: middle, isFinal: true, revision: 9, timestamp: 1)
        XCTAssertEqual(stale.matchedRange, stable.matchedRange)
        _ = follower.update(text: String(middle.prefix(14)), isFinal: false, revision: 11, timestamp: 2)
        let corrected = follower.update(text: "现在我要说一些跟原稿没有关系的水果蔬菜", isFinal: true, revision: 12, timestamp: 2.1)
        XCTAssertFalse(corrected.isTracking)
        XCTAssertEqual(corrected.matchedRange, stable.matchedRange)
        let actual = follower.update(text: middle, isFinal: true, revision: 13, timestamp: 3)
        XCTAssertTrue(actual.isTracking)
        XCTAssertEqual(sentence(actual, in: text), middle)
    }

    func testChineseEnglishNumbersAndUTF16Mapping() {
        let text = "👩🏽‍💻第一句包含组合字符 e\u{301}。\n使用 SpeechAnalyzer 和 GPU 处理 Swift 6，每秒 12 帧，成功率 3%，小数 2.50。"
        let speech = "使用speech analyzer和g p u处理swift六每秒十二帧成功率百分之三小数二点五"
        var follower = ScriptFollower(index: ScriptIndex(text: text))
        let result = follower.update(text: speech, isFinal: true, revision: 1, timestamp: 0)
        XCTAssertTrue(result.isTracking)
        XCTAssertTrue(sentence(result, in: text)?.hasPrefix("使用 SpeechAnalyzer") == true)
        XCTAssertTrue(matched(result, in: text)?.hasSuffix("2.50") == true)
        if let range = result.matchedRange {
            XCTAssertNotNil(Range(range, in: text))
            XCTAssertEqual(NSMaxRange(range), (text as NSString).length - 1)
        }
    }

    func testSmallASRErrorsAndInsertionsStillLocateFullPassage() {
        var follower = ScriptFollower(index: ScriptIndex(text: middle))
        let result = follower.update(text: "语音识别可以根据正在朗读的内容嗯自动定位稿件位子", isFinal: true, revision: 1, timestamp: 0)
        XCTAssertTrue(result.isTracking)
        XCTAssertEqual(sentence(result, in: middle), middle)
    }

    func testLocalProgressRereadingAndDeferredFinal() {
        var follower = ScriptFollower(index: ScriptIndex(text: middle))
        _ = follower.update(text: String(middle.prefix(14)), isFinal: true, revision: 1, timestamp: 0)
        let partial = follower.update(text: String(middle.prefix(18)), isFinal: false, revision: 2, timestamp: 0.2)
        XCTAssertTrue(partial.isTracking)
        let throttled = follower.update(text: middle, isFinal: false, revision: 3, timestamp: 0.21)
        XCTAssertEqual(throttled.matchedRange, partial.matchedRange)
        let earlyFinal = follower.update(text: middle, isFinal: true, revision: 4, timestamp: 0.22)
        XCTAssertEqual(earlyFinal.matchedRange, partial.matchedRange)
        let flushed = follower.update(text: middle, isFinal: true, revision: 4, timestamp: 0.33)
        XCTAssertTrue(flushed.isTracking)
        XCTAssertGreaterThan(NSMaxRange(flushed.matchedRange!), NSMaxRange(partial.matchedRange!))
        let reread = follower.update(text: String(middle.prefix(14)), isFinal: true, revision: 5, timestamp: 1)
        XCTAssertTrue(reread.isTracking)
        XCTAssertLessThan(NSMaxRange(reread.matchedRange!), NSMaxRange(flushed.matchedRange!))
    }

    func testLatestBatchSnapshotCanBeRetriedAfterBothThrottles() {
        let text = "先把需要介绍的内容粘贴到备忘录里面，然后打开语音跟读开关。接下来可以从文稿中间开始朗读，软件会自动找到对应的句子。最后检查录制画面和麦克风声音，确认已经做好准备工作。"
        var follower = ScriptFollower(index: ScriptIndex(text: text))
        for length in 1...50 {
            let result = follower.update(text: String(text.prefix(length)), isFinal: false,
                revision: UInt64(length), timestamp: Double(length - 1) * 0.0033)
            XCTAssertFalse(result.isTracking)
        }
        let latest = String(text.prefix(50))
        let stillThrottled = follower.update(text: latest, isFinal: false, revision: 50, timestamp: 0.25)
        XCTAssertFalse(stillThrottled.isTracking)
        let settled = follower.update(text: latest, isFinal: false, revision: 50, timestamp: 0.7)
        XCTAssertTrue(settled.isTracking)
        XCTAssertEqual(matched(settled, in: text), latest)
        let older = follower.update(text: String(text.prefix(49)), isFinal: false, revision: 49, timestamp: 1.3)
        XCTAssertEqual(older.matchedRange, settled.matchedRange)
        let conflicting = follower.update(text: first, isFinal: false, revision: 50, timestamp: 1.4)
        XCTAssertEqual(conflicting.matchedRange, settled.matchedRange)
    }

    func testRetryingSamePartialDoesNotCountAsAdditionalEvidence() {
        var follower = ScriptFollower(index: ScriptIndex(text: middle))
        let partial = String(middle.prefix(12))
        for attempt in 0...4 {
            let result = follower.update(text: partial, isFinal: false, revision: 1, timestamp: Double(attempt) * 0.6)
            XCTAssertFalse(result.isTracking)
            XCTAssertNil(result.matchedRange)
        }
        let extended = follower.update(text: String(middle.prefix(16)), isFinal: false, revision: 2, timestamp: 3)
        XCTAssertTrue(extended.isTracking)
    }

    func testShortPartialDoesNotConsumeGlobalSearchInterval() {
        var follower = ScriptFollower(index: ScriptIndex(text: middle))
        _ = follower.update(text: String(middle.prefix(8)), isFinal: false, revision: 1, timestamp: 0)
        _ = follower.update(text: String(middle.prefix(12)), isFinal: false, revision: 2, timestamp: 0.13)
        let extended = follower.update(text: String(middle.prefix(16)), isFinal: false, revision: 3, timestamp: 0.64)
        XCTAssertTrue(extended.isTracking)
    }

    func testLatestRevisionCanRetryLocalTrackingWithoutChangingRevision() {
        var follower = ScriptFollower(index: ScriptIndex(text: middle))
        let stable = follower.update(text: String(middle.prefix(14)), isFinal: true, revision: 1, timestamp: 0)
        let partial = String(middle.prefix(18))
        let throttled = follower.update(text: partial, isFinal: false, revision: 2, timestamp: 0.02)
        XCTAssertEqual(throttled.matchedRange, stable.matchedRange)
        let retried = follower.update(text: partial, isFinal: false, revision: 2, timestamp: 0.13)
        XCTAssertTrue(retried.isTracking)
        XCTAssertEqual(matched(retried, in: middle), partial)
    }

    func testFinalBurstSharesLocalCadenceAndLatestFinalExecutesLater() {
        var follower = ScriptFollower(index: ScriptIndex(text: middle))
        let stable = follower.update(text: String(middle.prefix(14)), isFinal: true, revision: 1, timestamp: 0)
        for length in 15...20 {
            let result = follower.update(text: String(middle.prefix(length)), isFinal: true,
                revision: UInt64(length), timestamp: Double(length - 14) * 0.01)
            XCTAssertEqual(result.matchedRange, stable.matchedRange)
        }
        let latest = String(middle.prefix(20))
        let earlyRetry = follower.update(text: latest, isFinal: true, revision: 20, timestamp: 0.124)
        XCTAssertEqual(earlyRetry.matchedRange, stable.matchedRange)
        let due = follower.update(text: latest, isFinal: true, revision: 20, timestamp: 0.125)
        XCTAssertTrue(due.isTracking)
        XCTAssertEqual(matched(due, in: middle), latest)
    }

    func testFinalBurstSharesGlobalCadenceAndOnlyLatestJumpExecutes() {
        let text = first + separator + middle + separator + last
        var follower = ScriptFollower(index: ScriptIndex(text: text))
        let stable = follower.update(text: first, isFinal: true, revision: 1, timestamp: 0)
        let middleEarly = follower.update(text: middle, isFinal: true, revision: 2, timestamp: 0.01)
        XCTAssertEqual(middleEarly.matchedRange, stable.matchedRange)
        let middleRetry = follower.update(text: middle, isFinal: true, revision: 2, timestamp: 0.125)
        XCTAssertFalse(middleRetry.isTracking)
        XCTAssertEqual(middleRetry.matchedRange, stable.matchedRange)
        _ = follower.update(text: last, isFinal: true, revision: 3, timestamp: 0.13)
        let lastRetry = follower.update(text: last, isFinal: true, revision: 3, timestamp: 0.25)
        XCTAssertFalse(lastRetry.isTracking)
        XCTAssertEqual(lastRetry.matchedRange, stable.matchedRange)
        let stale = follower.update(text: middle, isFinal: true, revision: 2, timestamp: 0.5)
        XCTAssertEqual(stale.matchedRange, stable.matchedRange)
        let due = follower.update(text: last, isFinal: true, revision: 3, timestamp: 0.5)
        XCTAssertTrue(due.isTracking)
        XCTAssertEqual(sentence(due, in: text), last)
    }

    func testEmptyScriptsAndSilenceHaveNoRange() {
        var follower = ScriptFollower(index: ScriptIndex(text: "  \n👩🏽‍💻"))
        XCTAssertNil(follower.update(text: "", isFinal: false, revision: 1, timestamp: 0).matchedRange)
        follower.anchor(atUTF16Offset: 200)
        XCTAssertNil(follower.update(text: middle, isFinal: true, revision: 2, timestamp: 1).matchedRange)
    }

    func testTwentyThousandCharacterSearchBudget() {
        let sentences = (0..<700).map { "第\($0)段我们介绍不同录制场景中的设备配置与窗口选择方法。" }
        let text = sentences.joined()
        XCTAssertGreaterThan(text.count, 20_000)
        let index = ScriptIndex(text: text)
        var durations: [Double] = []
        for position in stride(from: 37, to: 700, by: 47) {
            var follower = ScriptFollower(index: index)
            let start = ContinuousClock.now
            let result = follower.update(text: sentences[position], isFinal: true, revision: 1, timestamp: 0)
            durations.append(Double(start.duration(to: .now).components.attoseconds) / 1e18)
            XCTAssertTrue(result.isTracking)
            XCTAssertEqual(sentence(result, in: text), sentences[position])
        }
        durations.sort()
        let p95 = durations[min(durations.count - 1, Int(Double(durations.count) * 0.95))]
        print("ScriptFollower 20k search p95: \(String(format: "%.2f", p95 * 1_000)) ms")
        XCTAssertLessThan(p95, 0.05)
    }

    func testHundredThousandUnitsDoNotExpandCandidateWork() {
        let sentences = (0..<4_000).map { "第\($0)段我们介绍不同录制场景中的设备配置与窗口选择方法。" }
        let text = sentences.joined()
        let index = ScriptIndex(text: text)
        XCTAssertGreaterThan(index.units.count, 100_000)
        var follower = ScriptFollower(index: index)
        let start = ContinuousClock.now
        let result = follower.update(text: sentences[3_217], isFinal: true, revision: 1, timestamp: 0)
        let elapsed = start.duration(to: .now)
        XCTAssertTrue(result.isTracking)
        XCTAssertEqual(sentence(result, in: text), sentences[3_217])
        XCTAssertLessThan(elapsed, .milliseconds(50))
    }

    private func sentence(_ match: ScriptMatch, in text: String) -> String? {
        match.sentenceRange.map { (text as NSString).substring(with: $0) }
    }
    private func matched(_ match: ScriptMatch, in text: String) -> String? {
        match.matchedRange.map { (text as NSString).substring(with: $0) }
    }
}
