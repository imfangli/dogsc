import AppKit
import Combine
import RecorderCore
import XCTest
@testable import DogSCApp

@MainActor
final class SubtitleInteractionTests: XCTestCase {
    private func project() -> RecorderProject {
        let words = [SubtitleWord(text: "第一", sourceRanges: [.init(start: 0.2, end: 1)]),
                     SubtitleWord(text: "第二", sourceRanges: [.init(start: 2, end: 3)])]
        return RecorderProject(subtitles: SubtitleDocument(enabled: true, words: words,
            cues: words.map { SubtitleCue(wordIDs: [$0.id], text: $0.text) }))
    }

    private func rows(_ project: RecorderProject) throws -> [ResolvedSubtitleCue] {
        try project.subtitles.resolvedCues(timeline: project.timeline, sourceDuration: 5)
    }

    func testSwitchingRowsSavesOneDraftAsOneUndoableCommand() throws {
        let original = project()
        let undo = UndoManager()
        undo.groupsByEvent = false
        var persisted: [RecorderProject] = []
        let store = EditorStore(project: original, undoManager: undo, projectSink: { persisted.append($0) })
        let session = EditorSubtitleEditingSession()
        let resolved = try rows(original)
        XCTAssertTrue(session.select(original.subtitles.cues[0], row: resolved[0], store: store, sourceDuration: 5))
        session.draft?.text = "人工修正第一句"
        session.draft?.start = "0.100"
        session.draft?.end = "1.300"
        undo.beginUndoGrouping()
        XCTAssertTrue(session.select(original.subtitles.cues[1], row: resolved[1], store: store, sourceDuration: 5))
        undo.endUndoGrouping()
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(session.draft?.cueID, original.subtitles.cues[1].id)
        XCTAssertEqual(store.project.subtitles.cues[0].text, "人工修正第一句")
        XCTAssertEqual(try rows(store.project)[0].startTime, 0.1)
        undo.undo()
        XCTAssertEqual(store.project, original)
        undo.redo()
        XCTAssertEqual(store.project.subtitles.cues[0].text, "人工修正第一句")
    }

    func testInvalidTimeKeepsDraftAndPreventsSwitchingOrPartialSaving() throws {
        let original = project()
        let store = EditorStore(project: original)
        let session = EditorSubtitleEditingSession()
        let resolved = try rows(original)
        session.select(original.subtitles.cues[0], row: resolved[0], store: store, sourceDuration: 5)
        session.draft?.text = "尚未保存的文字"
        session.draft?.end = "not-a-time"
        XCTAssertFalse(session.select(original.subtitles.cues[1], row: resolved[1], store: store, sourceDuration: 5))
        XCTAssertEqual(session.draft?.cueID, original.subtitles.cues[0].id)
        XCTAssertEqual(session.draft?.text, "尚未保存的文字")
        XCTAssertEqual(session.draft?.end, "not-a-time")
        XCTAssertNotNil(session.errorMessage)
        XCTAssertEqual(store.project, original)
        session.cancel()
        XCTAssertNil(session.draft)
        XCTAssertEqual(store.project, original)
    }

    func testTextDraftSurvivesCutAndRetimesWithoutRawASRReplacement() throws {
        let original = project()
        let store = EditorStore(project: original)
        let session = EditorSubtitleEditingSession()
        session.select(original.subtitles.cues[0], row: try rows(original)[0], store: store, sourceDuration: 5)
        session.draft?.text = "保留输入中的完整句子"
        var cut = original
        cut.timeline.sourceSequence = .edited([RecordingSegment(sourceStart: 0.6, sourceDuration: 4.4)])
        try store.replaceProject(with: cut)
        session.reconcile(project: cut, sourceDuration: 5)
        XCTAssertEqual(session.draft?.text, "保留输入中的完整句子")
        XCTAssertEqual(session.draft?.start, "0.000")
        XCTAssertEqual(session.draft?.end, "0.400")
        XCTAssertTrue(session.commit(store: store, sourceDuration: 5))
        XCTAssertEqual(try rows(store.project)[0].text, "保留输入中的完整句子")
        XCTAssertEqual(store.project.subtitles.words, original.subtitles.words)
    }

    func testExternalCueEditAndTimelineChangesNeverSilentlyOverwriteDraft() throws {
        let original = project()
        let store = EditorStore(project: original)
        let session = EditorSubtitleEditingSession()
        session.select(original.subtitles.cues[0], row: try rows(original)[0], store: store, sourceDuration: 5)
        session.draft?.text = "我的草稿"
        var external = original
        try external.subtitles.updateCueText(id: original.subtitles.cues[0].id, text: "外部修改")
        try store.replaceProject(with: external)
        session.reconcile(project: external, sourceDuration: 5)
        XCTAssertFalse(session.commit(store: store, sourceDuration: 5))
        XCTAssertEqual(store.project, external)
        XCTAssertEqual(session.draft?.text, "我的草稿")

        session.cancel()
        session.select(external.subtitles.cues[0], row: try rows(external)[0], store: store, sourceDuration: 5)
        session.draft?.end = "1.500"
        external.timeline.sourceSequence = .edited([RecordingSegment(sourceStart: 0.6, sourceDuration: 4.4)])
        try store.replaceProject(with: external)
        session.reconcile(project: external, sourceDuration: 5)
        XCTAssertFalse(session.commit(store: store, sourceDuration: 5))
        XCTAssertEqual(store.project, external)
        XCTAssertEqual(session.draft?.end, "1.500")
    }

    func testUnassignedTextEditsDoNotInventTimesAndExplicitDeletionStaysDeleted() throws {
        var original = project()
        original.timeline.sourceSequence = .edited([RecordingSegment(sourceStart: 3, sourceDuration: 2)])
        let store = EditorStore(project: original)
        let session = EditorSubtitleEditingSession()
        session.select(original.subtitles.cues[0], row: nil, store: store, sourceDuration: 5)
        session.draft?.text = "未分配的新文案"
        XCTAssertTrue(session.commit(store: store, sourceDuration: 5))
        XCTAssertTrue(try rows(store.project).isEmpty)
        XCTAssertEqual(store.project.subtitles.cues[0].text, "未分配的新文案")
        session.draft?.text = ""
        XCTAssertTrue(session.commit(store: store, sourceDuration: 5))
        XCTAssertNil(session.draft)
        let unassigned = try store.project.subtitles.unassignedCues(timeline: original.timeline, sourceDuration: 5)
        XCTAssertFalse(unassigned.contains { $0.id == original.subtitles.cues[0].id })
    }

    func testPlaybackFollowsCueBoundariesButManualBrowsingStaysPutUntilResume() throws {
        let document = project()
        let navigation = EditorSubtitleNavigation()
        let resolved = try rows(document)
        navigation.update(rows: resolved)
        navigation.editorPlaybackTimelineDidUpdate(.init(outputTime: 0.2, duration: 5, isPlaying: true))
        XCTAssertEqual(navigation.activeCueID, resolved[0].cueID)
        let firstRequest = navigation.revealRequest
        for time in [0.3, 0.5, 0.9] {
            navigation.editorPlaybackTimelineDidUpdate(.init(outputTime: time, duration: 5, isPlaying: true))
            XCTAssertEqual(navigation.revealRequest, firstRequest, "Clock ticks inside one cue must not re-scroll the list.")
        }
        navigation.suspendFollowing()
        navigation.editorPlaybackTimelineDidUpdate(.init(outputTime: 2.5, duration: 5, isPlaying: true))
        XCTAssertEqual(navigation.activeCueID, resolved[1].cueID)
        XCTAssertEqual(navigation.revealRequest, firstRequest)
        navigation.resumeFollowing()
        XCTAssertEqual(navigation.revealRequest?.id, resolved[1].cueID)
        navigation.editorPlaybackTimelineDidUpdate(.init(outputTime: 3, duration: 5, isPlaying: true))
        XCTAssertNil(navigation.activeCueID, "End-exclusive intervals leave gaps unhighlighted.")
    }

    func testExplicitNavigationIsDistinctFromPlaybackAndSubtitleClicks() throws {
        let navigation = EditorSubtitleNavigation()
        navigation.update(rows: try rows(project()))
        var requests: [Double] = []
        let subscription = navigation.timelineNavigations.sink { requests.append($0) }
        defer { subscription.cancel() }
        navigation.editorPlaybackTimelineDidUpdate(.init(outputTime: 0.2, duration: 5, isPlaying: false))
        navigation.editorPlaybackTimelineDidUpdate(.init(outputTime: 0.5, duration: 5, isPlaying: true))
        navigation.editorPlaybackTimelineDidUpdate(.init(outputTime: 2, duration: 5, isPlaying: false,
            navigationRevision: 1, navigationOrigin: .subtitle))
        XCTAssertTrue(requests.isEmpty)
        let explicit = EditorPlaybackTimelineSnapshot(outputTime: 0.4, duration: 5, isPlaying: false,
            navigationRevision: 2, navigationOrigin: .timeline)
        navigation.editorPlaybackTimelineDidUpdate(explicit)
        navigation.editorPlaybackTimelineDidUpdate(explicit)
        XCTAssertEqual(requests, [0.4], "Repeated decode/completion snapshots must not recommit a draft.")
    }
}
