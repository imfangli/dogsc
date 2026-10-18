import Foundation
import XCTest
@testable import RecorderCore

final class SubtitleTests: XCTestCase {
    private func fixture() -> SubtitleDocument {
        let words = [
            SubtitleWord(text: "第一", sourceRanges: [.init(start: 0, end: 0.8)]),
            SubtitleWord(text: "第二", sourceRanges: [.init(start: 1, end: 1.8)]),
            SubtitleWord(text: "第三", sourceRanges: [.init(start: 2, end: 2.8)]),
        ]
        return SubtitleDocument(enabled: true, words: words, cues: [
            SubtitleCue(wordIDs: words.map(\.id), text: "校正后的完整句子"),
        ])
    }

    func testRecognitionRangesMapFromEditedAudioAcrossCutAndRate() throws {
        let timeline = ProjectTimeline(sourceSequence: .edited([
            RecordingSegment(sourceStart: 4, sourceDuration: 2, playbackRate: 2),
            RecordingSegment(sourceStart: 0, sourceDuration: 2),
        ]))
        let ranges = try SubtitleDocument.sourceRanges(
            for: .init(start: 0.5, end: 1.5), timeline: timeline, sourceDuration: 6
        )
        XCTAssertEqual(ranges, [.init(start: 5, end: 6), .init(start: 0, end: 0.5)])
    }

    func testIntactCorrectedCueFollowsPlaybackRate() throws {
        let document = fixture()
        let timeline = ProjectTimeline(sourceSequence: .edited([
            RecordingSegment(sourceStart: 0, sourceDuration: 3, playbackRate: 2),
        ]))
        let cues = try document.resolvedCues(timeline: timeline, sourceDuration: 3)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].startTime, 0)
        XCTAssertEqual(cues[0].endTime, 1.4, accuracy: 0.000_001)
        XCTAssertEqual(cues[0].text, "校正后的完整句子")
        XCTAssertFalse(cues[0].requiresReview)
        XCTAssertEqual(try document.resolvedCues(timeline: timeline, sourceDuration: 3), cues)
    }

    func testTrimKeepsCompleteCorrectedTextAndAdjustsTime() throws {
        let document = fixture()
        let timeline = ProjectTimeline(sourceSequence: .edited([
            RecordingSegment(sourceStart: 1, sourceDuration: 2),
        ]))
        let cues = try document.resolvedCues(timeline: timeline, sourceDuration: 3)
        XCTAssertEqual(cues.map(\.text), ["校正后的完整句子"])
        XCTAssertEqual(cues[0].startTime, 0)
        XCTAssertEqual(cues[0].endTime, 1.8, accuracy: 0.000_001)
        XCTAssertTrue(cues[0].requiresReview)
    }

    func testCutInsideTimedUnitPreservesCompleteCorrectedText() throws {
        let document = fixture()
        let timeline = ProjectTimeline(sourceSequence: .edited([
            RecordingSegment(sourceStart: 0.4, sourceDuration: 2.6),
        ]))
        let cues = try document.resolvedCues(timeline: timeline, sourceDuration: 3)
        XCTAssertEqual(cues.map(\.text), ["校正后的完整句子"])
        XCTAssertEqual(cues[0].startTime, 0, accuracy: 0.000_001)
        XCTAssertTrue(cues[0].requiresReview)
    }

    func testReorderUsesLongestContinuousRunWithoutRepeatingText() throws {
        let document = fixture()
        let timeline = ProjectTimeline(sourceSequence: .edited([
            RecordingSegment(sourceStart: 2, sourceDuration: 1),
            RecordingSegment(sourceStart: 0, sourceDuration: 2),
        ]))
        let cues = try document.resolvedCues(timeline: timeline, sourceDuration: 3)
        XCTAssertEqual(cues.map(\.text), ["校正后的完整句子"])
        XCTAssertEqual(cues.map(\.startTime), [1])
        XCTAssertEqual(cues[0].endTime, 2.8, accuracy: 0.000_001)
        XCTAssertTrue(cues[0].wasRearranged)
        XCTAssertTrue(cues[0].requiresReview)
    }

    func testDeletedCueRemainsHiddenAfterTrim() throws {
        var document = fixture()
        let originalWords = document.words
        let id = document.cues[0].id
        try document.updateCueText(id: id, text: "")
        let timeline = ProjectTimeline(sourceSequence: .edited([
            RecordingSegment(sourceStart: 1, sourceDuration: 2),
        ]))
        let cues = try document.resolvedCues(timeline: timeline, sourceDuration: 3)
        XCTAssertTrue(cues.isEmpty)
        XCTAssertEqual(SubtitleSRTExporter.export(cues), "")
        XCTAssertEqual(document.words, originalWords)
        XCTAssertEqual(document.cues[0].wordIDs, originalWords.map(\.id))
        XCTAssertTrue(document.cues[0].isManuallyEdited)
        XCTAssertNoThrow(try document.validate())
    }

    func testDeletedCueRemainsHiddenAfterReorder() throws {
        var document = fixture()
        // A text edit that formats to empty has the same deletion semantics.
        try document.updateCueText(id: document.cues[0].id, text: " \n。 ")
        let timeline = ProjectTimeline(sourceSequence: .edited([
            RecordingSegment(sourceStart: 2, sourceDuration: 1),
            RecordingSegment(sourceStart: 0, sourceDuration: 2),
        ]))
        let cues = try document.resolvedCues(timeline: timeline, sourceDuration: 3)
        XCTAssertTrue(cues.isEmpty)
        XCTAssertEqual(SubtitleSRTExporter.export(cues), "")
        XCTAssertEqual(document.cues[0].text, "")
        XCTAssertTrue(document.cues[0].isManuallyEdited)
    }

    func testDeletedManuallyTimedCueRemainsHiddenAfterFurtherEdits() throws {
        var document = fixture()
        let originalWords = document.words
        let id = document.cues[0].id
        try document.updateCueTiming(id: id, outputTimeRange: .init(start: 0.2, end: 2.9),
                                     timeline: ProjectTimeline(), sourceDuration: 3)
        try document.updateCueText(id: id, text: "")
        let timelines = [
            ProjectTimeline(),
            ProjectTimeline(sourceSequence: .edited([
                RecordingSegment(sourceStart: 1, sourceDuration: 2),
            ])),
            ProjectTimeline(sourceSequence: .edited([
                RecordingSegment(sourceStart: 2, sourceDuration: 1),
                RecordingSegment(sourceStart: 0, sourceDuration: 2),
            ])),
        ]
        for timeline in timelines {
            let cues = try document.resolvedCues(timeline: timeline, sourceDuration: 3)
            XCTAssertTrue(cues.isEmpty)
            XCTAssertEqual(SubtitleSRTExporter.export(cues), "")
        }
        XCTAssertEqual(document.words, originalWords)
        XCTAssertEqual(document.cues[0].wordIDs, originalWords.map(\.id))
        XCTAssertEqual(document.cues[0].manualSourceRanges, [.init(start: 0.2, end: 2.9)])
        XCTAssertTrue(document.cues[0].isManuallyEdited)
        XCTAssertNoThrow(try document.validate())
    }

    func testAICorrectionOnlyRegroupsStableUnits() throws {
        var document = fixture()
        let originalWords = document.words
        try document.applyCorrections([
            .init(wordIDs: Array(originalWords[..<2].map(\.id)), text: "使用SpeechAnalyzer，测试。"),
            .init(wordIDs: [originalWords[2].id], text: "第三！"),
        ])
        XCTAssertEqual(document.words, originalWords)
        XCTAssertEqual(document.cues.map(\.text), ["使用 SpeechAnalyzer，测试", "第三"])
        XCTAssertTrue(document.cues.allSatisfy { $0.manualSourceRanges == nil && !$0.isManuallyEdited })
        let resolved = try document.resolvedCues(timeline: ProjectTimeline(), sourceDuration: 3)
        XCTAssertEqual(resolved.map(\.startTime), [0, 2])
        XCTAssertEqual(resolved.map(\.endTime), [1.8, 2.8])
    }

    func testInterleavedReorderDoesNotSpanAnotherCuesSpeech() throws {
        let words = (0..<4).map { i in
            SubtitleWord(text: "\(i)", sourceRanges: [.init(start: Double(i), end: Double(i) + 0.8)])
        }
        let document = SubtitleDocument(words: words, cues: [
            .init(wordIDs: Array(words[..<2].map(\.id)), text: "第一句"),
            .init(wordIDs: Array(words[2...].map(\.id)), text: "第二句"),
        ])
        let timeline = ProjectTimeline(sourceSequence: .edited([0, 2, 1, 3].map {
            RecordingSegment(sourceStart: Double($0), sourceDuration: 1)
        }))
        let cues = try document.resolvedCues(timeline: timeline, sourceDuration: 4)
        XCTAssertEqual(cues.map(\.text), ["第一句", "第二句"])
        XCTAssertEqual(cues.map(\.startTime), [0, 1])
        XCTAssertTrue(cues.allSatisfy(\.wasRearranged))
        XCTAssertTrue(cues.allSatisfy(\.requiresReview))
    }

    func testAIRejectsMissingDuplicateReorderedUnknownIDsAtomically() {
        let initial = fixture()
        let ids = initial.words.map(\.id)
        let invalid: [[UUID]] = [[ids[0], ids[2]], [ids[0], ids[0], ids[2]],
                                 [ids[1], ids[0], ids[2]], [ids[0], ids[1], UUID()]]
        for ids in invalid {
            var document = initial
            XCTAssertThrowsError(try document.applyCorrections([.init(wordIDs: ids, text: "错误")]))
            XCTAssertEqual(document, initial)
        }
        var document = initial
        XCTAssertThrowsError(try document.applyCorrections([.init(wordIDs: ids, text: " \n。")]))
        XCTAssertEqual(document, initial)
    }

    func testCorrectionProtectsManualCuesAndSupportsSeparatedBatches() throws {
        var document = fixture()
        let words = document.words
        document.cues = words.map { SubtitleCue(wordIDs: [$0.id], text: $0.text) }
        let manualID = document.cues[1].id
        try document.updateCueText(id: manualID, text: "手工术语")
        try document.applyCorrections([
            .init(wordIDs: [words[0].id], text: "第一条"),
            .init(wordIDs: [words[2].id], text: "第三条"),
        ])
        XCTAssertEqual(document.cues.first(where: { $0.id == manualID })?.text, "手工术语")
        XCTAssertEqual(document.cues.map(\.text), ["第一条", "手工术语", "第三条"])
        XCTAssertEqual(document.words, words)
        XCTAssertThrowsError(try document.applyCorrections([
            .init(wordIDs: [words[0].id, words[2].id], text: "跨过手工字幕"),
        ]))
    }

    func testManualSplitMergeAndTimingRemainSourceAnchored() throws {
        var document = fixture()
        let id = document.cues[0].id
        try document.splitCue(id: id, atWordIndex: 1, firstText: "第一条", secondText: "其余")
        XCTAssertEqual(document.cues.count, 2)
        XCTAssertTrue(document.cues.allSatisfy(\.isManuallyEdited))
        try document.mergeCues(firstID: id, secondID: document.cues[1].id)
        XCTAssertEqual(document.cues.count, 1)
        try document.updateCueTiming(
            id: id, outputTimeRange: .init(start: 0.2, end: 2.9),
            timeline: ProjectTimeline(), sourceDuration: 3
        )
        XCTAssertEqual(document.cues[0].manualSourceRanges, [.init(start: 0.2, end: 2.9)])
        let timeline = ProjectTimeline(sourceSequence: .edited([
            RecordingSegment(sourceStart: 0, sourceDuration: 3, playbackRate: 2),
        ]))
        let projected = try document.resolvedCues(timeline: timeline, sourceDuration: 3)
        XCTAssertEqual(projected[0].startTime, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(projected[0].endTime, 1.45, accuracy: 0.000_001)
        XCTAssertEqual(projected[0].text, "第一条其余")
    }

    func testManualTimingRejectsOverlapAndOutOfBounds() throws {
        var document = fixture()
        try document.splitCue(id: document.cues[0].id, atWordIndex: 1)
        let id = document.cues[0].id
        let unchanged = document
        for range in [SubtitleTimeRange(start: 0, end: 1.2), .init(start: 2, end: 4), .init(start: 2, end: 1)] {
            XCTAssertThrowsError(try document.updateCueTiming(
                id: id, outputTimeRange: range, timeline: ProjectTimeline(), sourceDuration: 3
            ))
            XCTAssertEqual(document, unchanged)
        }
    }

    func testReviewedTrimFragmentBecomesEditableWithoutRestoringDeletedSpeech() throws {
        var document = fixture()
        let timeline = ProjectTimeline(sourceSequence: .edited([
            RecordingSegment(sourceStart: 1, sourceDuration: 2),
        ]))
        let row = try XCTUnwrap(document.resolvedCues(timeline: timeline, sourceDuration: 3).first)
        let id = try document.materializeResolvedCue(id: row.id, timeline: timeline, sourceDuration: 3)
        try document.updateCueText(id: id, text: "人工修正剩余字幕")
        let visible = try document.resolvedCues(timeline: timeline, sourceDuration: 3)
        XCTAssertEqual(visible.map(\.text), ["人工修正剩余字幕"])
        XCTAssertFalse(visible[0].requiresReview)
        XCTAssertEqual(document.cues[0].wordIDs, document.words.map(\.id), "Removed IDs remain protected from AI.")
        XCTAssertTrue(document.cues[0].isManuallyEdited)
        XCTAssertNoThrow(try document.validate())

        let restored = try document.resolvedCues(timeline: ProjectTimeline(), sourceDuration: 3)
        XCTAssertEqual(restored.map(\.text), ["人工修正剩余字幕"])
        XCTAssertEqual(restored[0].startTime, 1)
        let furtherTrim = ProjectTimeline(sourceSequence: .edited([RecordingSegment(sourceStart: 2, sourceDuration: 1)]))
        let recropped = try document.resolvedCues(timeline: furtherTrim, sourceDuration: 3)
        XCTAssertEqual(recropped.map(\.text), ["人工修正剩余字幕"])
        XCTAssertTrue(recropped[0].requiresReview)
    }

    func testSingleTimedUnitAcrossCutMustKeepPieceOrderAndContinuity() throws {
        let word = SubtitleWord(text: "跨剪切的字", sourceRanges: [.init(start: 0.9, end: 1), .init(start: 2, end: 2.1)])
        let document = SubtitleDocument(words: [word], cues: [.init(wordIDs: [word.id], text: "校正")])
        let originalTimeline = ProjectTimeline(sourceSequence: .edited([
            RecordingSegment(sourceStart: 0, sourceDuration: 1),
            RecordingSegment(sourceStart: 2, sourceDuration: 1),
        ]))
        XCTAssertEqual(try document.resolvedCues(timeline: originalTimeline, sourceDuration: 4).map(\.text), ["校正"])
        let reordered = ProjectTimeline(sourceSequence: .edited([
            RecordingSegment(sourceStart: 2, sourceDuration: 1),
            RecordingSegment(sourceStart: 0, sourceDuration: 1),
        ]))
        let rearranged = try document.resolvedCues(timeline: reordered, sourceDuration: 4)
        XCTAssertEqual(rearranged.map(\.text), ["校正"])
        XCTAssertTrue(rearranged[0].wasRearranged)
        let separated = ProjectTimeline(sourceSequence: .edited([
            RecordingSegment(sourceStart: 0, sourceDuration: 1),
            RecordingSegment(sourceStart: 3, sourceDuration: 1),
            RecordingSegment(sourceStart: 2, sourceDuration: 1),
        ]))
        let separatedRows = try document.resolvedCues(timeline: separated, sourceDuration: 4)
        XCTAssertEqual(separatedRows.map(\.text), ["校正"])
        XCTAssertEqual(separatedRows[0].duration, 0.1, accuracy: 0.000_001)
        XCTAssertTrue(separatedRows[0].wasRearranged)
    }

    func testManualIntervalCannotSpanInterleavedForeignSpeech() throws {
        let words = [
            SubtitleWord(text: "原句", sourceRanges: [.init(start: 0, end: 0.8)]),
            SubtitleWord(text: "插入的其他句", sourceRanges: [.init(start: 2, end: 2.8)]),
        ]
        let document = SubtitleDocument(words: words, cues: [
            .init(wordIDs: [words[0].id], text: "人工修改的句子",
                  manualSourceRanges: [.init(start: 0, end: 2)], isManuallyEdited: true),
            .init(wordIDs: [words[1].id], text: words[1].text),
        ])
        let timeline = ProjectTimeline(sourceSequence: .edited([
            RecordingSegment(sourceStart: 0, sourceDuration: 1),
            RecordingSegment(sourceStart: 2, sourceDuration: 1),
            RecordingSegment(sourceStart: 1, sourceDuration: 1),
        ]))
        let cues = try document.resolvedCues(timeline: timeline, sourceDuration: 3)
        XCTAssertEqual(cues.map(\.text), ["人工修改的句子", "插入的其他句"])
        XCTAssertEqual(cues[0].endTime, 1, accuracy: 0.000_001)
        XCTAssertTrue(cues[0].requiresReview)
        XCTAssertFalse(cues[1].requiresReview)
    }

    func testForeignPartlyCroppedUnitStillPreventsManualSentenceStretch() throws {
        let words = [
            SubtitleWord(text: "原句", sourceRanges: [.init(start: 0, end: 0.8)]),
            SubtitleWord(text: "被截断的其他句", sourceRanges: [.init(start: 2, end: 2.8)]),
        ]
        let document = SubtitleDocument(words: words, cues: [
            .init(wordIDs: [words[0].id], text: "人工修改的句子",
                  manualSourceRanges: [.init(start: 0, end: 2)], isManuallyEdited: true),
            .init(wordIDs: [words[1].id], text: words[1].text),
        ])
        let timeline = ProjectTimeline(sourceSequence: .edited([
            RecordingSegment(sourceStart: 0, sourceDuration: 1),
            RecordingSegment(sourceStart: 2.4, sourceDuration: 0.6),
            RecordingSegment(sourceStart: 1, sourceDuration: 1),
        ]))
        let cues = try document.resolvedCues(timeline: timeline, sourceDuration: 3)
        XCTAssertEqual(cues.map(\.text), ["人工修改的句子", "被截断的其他句"])
        XCTAssertEqual(cues[0].endTime, 1, accuracy: 0.000_001)
        XCTAssertTrue(cues[0].requiresReview)
    }

    func testTwentyMinuteTranscriptWithManyManualCuesProjectsAllIntervals() throws {
        let words = (0..<7_200).map { index in
            let start = Double(index) / 6
            return SubtitleWord(text: "字", sourceRanges: [.init(start: start, end: start + 0.13)])
        }
        let cues = stride(from: 0, to: words.count, by: 24).map { index in
            let group = Array(words[index..<(index + 24)])
            return SubtitleCue(wordIDs: group.map(\.id), text: String(repeating: "字", count: 24),
                manualSourceRanges: [.init(start: group[0].sourceRanges[0].start,
                                          end: group.last!.sourceRanges[0].end)], isManuallyEdited: true)
        }
        let document = SubtitleDocument(words: words, cues: cues)
        let timeline = ProjectTimeline(sourceSequence: .edited((0..<60).map {
            RecordingSegment(sourceStart: Double($0) * 20, sourceDuration: 20)
        }))
        let projected = try document.resolvedCues(timeline: timeline, sourceDuration: 1_200)
        XCTAssertEqual(projected.count, 300)
        XCTAssertTrue(projected.allSatisfy { !$0.requiresReview })
        XCTAssertEqual(Set(projected.map(\.id)).count, 300)
        XCTAssertEqual(projected.last!.endTime, words.last!.sourceRanges[0].end, accuracy: 0.000_001)
    }

    func testEditingReorderedCuePreservesStableIdentityAndAllWordOwnership() throws {
        var document = fixture()
        let authored = document.cues[0]
        let timeline = ProjectTimeline(sourceSequence: .edited([
            RecordingSegment(sourceStart: 2, sourceDuration: 1),
            RecordingSegment(sourceStart: 0, sourceDuration: 2),
        ]))
        let row = try XCTUnwrap(document.resolvedCues(timeline: timeline, sourceDuration: 3).first)
        let id = try document.materializeResolvedCue(id: row.id, timeline: timeline, sourceDuration: 3)
        XCTAssertEqual(id, authored.id)
        XCTAssertEqual(document.cues.count, 1)
        XCTAssertEqual(document.cues[0].text, authored.text)
        XCTAssertEqual(document.cues[0].wordIDs, authored.wordIDs)
        try document.updateCueText(id: id, text: "人工校对全文")
        let projected = try document.resolvedCues(timeline: timeline, sourceDuration: 3)
        XCTAssertEqual(projected.map(\.text), ["人工校对全文"])
        XCTAssertEqual(projected[0].startTime, 1)
        XCTAssertFalse(projected[0].requiresReview)
        XCTAssertNoThrow(try document.validate())
    }

    func testEntirelyRemovedCueRemainsUnassignedAndCanBePlacedInFreeGap() throws {
        var document = fixture()
        let original = document
        let timeline = ProjectTimeline(sourceSequence: .edited([
            RecordingSegment(sourceStart: 3, sourceDuration: 2),
        ]))
        XCTAssertTrue(try document.resolvedCues(timeline: timeline, sourceDuration: 5).isEmpty)
        XCTAssertEqual(try document.unassignedCues(timeline: timeline, sourceDuration: 5), original.cues)
        XCTAssertEqual(document, original, "Projection never mutates or deletes the authored document.")
        try document.placeCue(id: document.cues[0].id, atOutputTime: 1.5, timeline: timeline, sourceDuration: 5)
        let placed = try XCTUnwrap(document.resolvedCues(timeline: timeline, sourceDuration: 5).first)
        XCTAssertEqual(placed.text, original.cues[0].text)
        XCTAssertEqual(placed.startTime, 1.5)
        XCTAssertEqual(placed.endTime, 2, "Suggested duration is clipped to the output end.")
        XCTAssertEqual(document.words, original.words)
        XCTAssertEqual(document.cues[0].wordIDs, original.cues[0].wordIDs)
        XCTAssertTrue(try document.unassignedCues(timeline: timeline, sourceDuration: 5).isEmpty)
        XCTAssertNoThrow(try document.validate())
    }

    func testPlacementNeverOverwritesOtherSubtitlesAndStopsAtNextCue() throws {
        var document = fixture()
        let other = SubtitleCue(wordIDs: [], text: "相邻字幕", manualSourceRanges: [.init(start: 4, end: 4.8)], isManuallyEdited: true)
        document.cues.append(other)
        let timeline = ProjectTimeline(sourceSequence: .edited([RecordingSegment(sourceStart: 3, sourceDuration: 2)]))
        let unchanged = document
        XCTAssertThrowsError(try document.placeCue(id: document.cues[0].id, atOutputTime: 1.2,
            timeline: timeline, sourceDuration: 5)) { error in
            XCTAssertEqual(error as? SubtitleEditingError, .overlappingTiming)
        }
        XCTAssertEqual(document, unchanged)
        try document.placeCue(id: document.cues[0].id, atOutputTime: 0.2, timeline: timeline, sourceDuration: 5)
        let rows = try document.resolvedCues(timeline: timeline, sourceDuration: 5)
        XCTAssertEqual(rows[0].startTime, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(rows[0].endTime, 1)
        XCTAssertEqual(document.cues[1], other)
    }

    func testVeryShortRemainingRangeKeepsTextAndWarnsWithoutExtending() throws {
        let document = fixture()
        let timeline = ProjectTimeline(sourceSequence: .edited([RecordingSegment(sourceStart: 1.2, sourceDuration: 0.2)]))
        let row = try XCTUnwrap(document.resolvedCues(timeline: timeline, sourceDuration: 3).first)
        XCTAssertEqual(row.text, document.cues[0].text)
        XCTAssertEqual(row.duration, 0.2, accuracy: 0.000_001)
        XCTAssertTrue(row.isTooShort)
        XCTAssertFalse(row.wasRearranged)
    }

    func testOrdinarySplitAndSourceRestorationKeepStableCueTextAndIdentity() throws {
        let document = fixture()
        let original = try document.resolvedCues(timeline: ProjectTimeline(), sourceDuration: 3)
        let split = ProjectTimeline(sourceSequence: .edited([
            RecordingSegment(sourceStart: 0, sourceDuration: 0.4),
            RecordingSegment(sourceStart: 0.4, sourceDuration: 2.6),
        ]))
        XCTAssertEqual(try document.resolvedCues(timeline: split, sourceDuration: 3), original)
        let removed = ProjectTimeline(sourceSequence: .edited([RecordingSegment(sourceStart: 3, sourceDuration: 1)]))
        XCTAssertEqual(try document.unassignedCues(timeline: removed, sourceDuration: 4), document.cues)
        XCTAssertEqual(try document.resolvedCues(timeline: ProjectTimeline(), sourceDuration: 3), original)
    }

    func testManualFreeSplitDoesNotInventRecognizedUnitTimes() throws {
        let word = SubtitleWord(text: "一个长识别单位", sourceRanges: [.init(start: 1, end: 3)])
        var document = SubtitleDocument(words: [word], cues: [.init(wordIDs: [word.id], text: word.text)])
        let id = document.cues[0].id
        try document.splitCue(id: id, atOutputTime: 2.2, firstText: "手动上半句", secondText: "手动下半句",
                              timeline: ProjectTimeline(), sourceDuration: 4)
        XCTAssertEqual(document.words, [word])
        XCTAssertEqual(document.cues.map(\.manualSourceRanges), [[.init(start: 1, end: 2.2)], [.init(start: 2.2, end: 3)]])
        XCTAssertTrue(document.cues.allSatisfy(\.isManuallyEdited))
        XCTAssertNoThrow(try document.validate())
        let projected = try document.resolvedCues(timeline: ProjectTimeline(), sourceDuration: 4)
        XCTAssertEqual(projected.map(\.text), ["手动上半句", "手动下半句"])
        XCTAssertEqual(projected.map(\.startTime), [1, 2.2])
        XCTAssertEqual(projected.map(\.endTime), [2.2, 3])
    }

    func testMergeAfterManualTimingDoesNotRepeatSentenceAcrossWordGaps() throws {
        var document = fixture()
        let id = document.cues[0].id
        try document.splitCue(id: id, atWordIndex: 1)
        try document.updateCueTiming(id: id, outputTimeRange: .init(start: 0.1, end: 0.9),
                                     timeline: ProjectTimeline(), sourceDuration: 3)
        try document.mergeCues(firstID: id, secondID: document.cues[1].id)
        let projected = try document.resolvedCues(timeline: ProjectTimeline(), sourceDuration: 3)
        XCTAssertEqual(projected.count, 1)
        XCTAssertEqual(projected[0].text, "第一第二第三")
        XCTAssertEqual(projected[0].startTime, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(projected[0].endTime, 2.8, accuracy: 0.000_001)
    }

    func testFormattingPreservesGraphemesDecimalsAcronymsAndInternalPunctuation() {
        XCTAssertEqual(SubtitleTextFormatter.format("  使用GPU和 café测试 2.50，👩🏽‍💻 e\u{301}。 "),
                       "使用 GPU 和 café 测试 2.50，👩🏽‍💻 e\u{301}")
        XCTAssertEqual(SubtitleTextFormatter.format("来自U.S."), "来自 U.S.")
        XCTAssertEqual(SubtitleTextFormatter.format("你好，\n世界。"), "你好，\n世界")
        XCTAssertEqual(SubtitleTextFormatter.joinUnits(["hello", "world", "中文", "Swift"]), "hello world 中文 Swift")
        XCTAssertEqual(SubtitleTextFormatter.format("使用GPT-4模型和3D打印，耗时2.50秒。"),
                       "使用 GPT-4 模型和 3D 打印，耗时2.50秒")
    }

    func testProjectRoundTripAndOldProjectSubtitleDefaults() throws {
        let document = fixture()
        let project = RecorderProject(subtitles: document)
        let encoder = JSONEncoder()
        let data = try encoder.encode(project)
        XCTAssertEqual(try JSONDecoder().decode(RecorderProject.self, from: data), project)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 27
        object.removeValue(forKey: "subtitles")
        let legacy = try JSONDecoder().decode(RecorderProject.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.version, 28)
        XCTAssertEqual(legacy.subtitles, SubtitleDocument())
        XCTAssertNoThrow(try ProjectValidator.validate(legacy))
    }

    func testInvalidSubtitleReferencesFailProjectValidation() {
        var document = fixture()
        document.cues[0].wordIDs.append(UUID())
        XCTAssertThrowsError(try ProjectValidator.validate(RecorderProject(subtitles: document)))
        document = fixture()
        document.words[0].sourceRanges = [.init(start: 1, end: 0)]
        XCTAssertThrowsError(try document.validate())
    }

    func testSRTUsesEditedProjectedTimesAndMillisecondPrecision() throws {
        let document = fixture()
        let timeline = ProjectTimeline(sourceSequence: .edited([
            RecordingSegment(sourceStart: 1, sourceDuration: 2, playbackRate: 2),
        ]))
        let cues = try document.resolvedCues(timeline: timeline, sourceDuration: 3)
        XCTAssertEqual(SubtitleSRTExporter.export(cues), "1\n00:00:00,000 --> 00:00:00,900\n校正后的完整句子\n")
        let tiny = ResolvedSubtitleCue(id: "tiny", cueID: UUID(), text: "短。", startTime: 3_661.2345, endTime: 3_661.2346)
        XCTAssertEqual(SubtitleSRTExporter.export([tiny]), "1\n01:01:01,235 --> 01:01:01,236\n短\n")
    }
}
