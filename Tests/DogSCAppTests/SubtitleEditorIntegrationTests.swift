import AppKit
import Foundation
import RecorderCore
import XCTest
@testable import DogSCApp

/// Exercises the real editor command boundary without opening a window,
/// recording audio, requesting permissions or contacting an AI provider.
@MainActor
final class SubtitleEditorIntegrationTests: XCTestCase {
    private func projectFixture(audioSource: SubtitleAudioSource = .microphone) -> RecorderProject {
        let words = [
            SubtitleWord(text: "使用", sourceRanges: [.init(start: 0.2, end: 0.6)]),
            SubtitleWord(text: "Swift", sourceRanges: [.init(start: 0.6, end: 1.1)]),
            SubtitleWord(text: "开发", sourceRanges: [.init(start: 1.1, end: 1.6)]),
        ]
        return RecorderProject(
            title: "字幕项目",
            media: ProjectMediaManifest(
                screen: .init(relativePath: "media/screen.mov"),
                camera: .init(relativePath: "media/camera.mov", startOffset: 0.2),
                microphone: .init(relativePath: "media/microphone.m4a", startOffset: 0.1,
                                  sourceStartTime: 0.05, sourceTimeScale: 1.0001, sourceEndTime: 4),
                pointerEvents: .init(relativePath: "media/pointer.json")
            ),
            subtitles: SubtitleDocument(enabled: true, audioSource: audioSource,
                script: "使用 Swift 开发", theme: "编程", words: words,
                cues: [.init(wordIDs: words.map(\.id), text: "使用Swift开发。")])
        )
    }

    func testSubtitleCorrectionIsOneUndoablePersistedEditorCommand() throws {
        let original = projectFixture()
        let document = ProjectDocument(project: original)
        let undo = UndoManager()
        undo.groupsByEvent = false
        var persisted: [RecorderProject] = []
        let store = EditorStore(document: document, undoManager: undo, projectSink: { persisted.append($0) })
        store.selection = .screen
        var replacement = original
        try replacement.subtitles.applyCorrections([
            .init(wordIDs: replacement.subtitles.words.map(\.id), text: "使用Swift，进行开发。"),
        ])

        undo.beginUndoGrouping()
        try store.replaceProject(with: replacement, actionName: "AI 校对字幕")
        undo.endUndoGrouping()
        XCTAssertEqual(store.project, replacement)
        XCTAssertEqual(document.project, replacement)
        XCTAssertEqual(store.selection, .screen)
        XCTAssertEqual(store.revision, 1)
        XCTAssertEqual(persisted, [replacement])
        XCTAssertTrue(undo.canUndo)
        XCTAssertEqual(undo.undoActionName, "AI 校对字幕")
        XCTAssertEqual(try JSONDecoder().decode(RecorderProject.self, from: JSONEncoder().encode(persisted[0])), replacement)

        undo.undo()
        XCTAssertEqual(store.project, original)
        XCTAssertEqual(document.project, original)
        XCTAssertEqual(persisted.last, original)
        XCTAssertEqual(store.selection, .screen)
        XCTAssertFalse(undo.canUndo, "A whole AI correction should create one undo step.")
        XCTAssertTrue(undo.canRedo)

        undo.redo()
        XCTAssertEqual(store.project, replacement)
        XCTAssertEqual(document.project, replacement)
        XCTAssertEqual(persisted.last, replacement)
        XCTAssertEqual(persisted.count, 3)
    }

    func testLateResultApplicationPreservesUnrelatedRenameAndUndo() throws {
        let input = projectFixture()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let store = EditorStore(project: input, undoManager: undo)
        var renamed = input
        renamed.title = "录制后重命名"
        undo.beginUndoGrouping()
        try store.replaceProject(with: renamed, actionName: "重命名项目")
        undo.endUndoGrouping()
        XCTAssertTrue(EditorSubtitleController.inputIsUnchanged(input, current: store.project))

        // The controller applies to the current project after checking its
        // relevant input, so unrelated edits never get replaced by the snapshot.
        var corrected = store.project
        try corrected.subtitles.applyCorrections([
            .init(wordIDs: input.subtitles.words.map(\.id), text: "使用 Swift 开发"),
        ])
        undo.beginUndoGrouping()
        try store.replaceProject(with: corrected, actionName: "AI 校对字幕")
        undo.endUndoGrouping()
        XCTAssertEqual(store.project.title, renamed.title)
        undo.undo()
        XCTAssertEqual(store.project, renamed)
        undo.undo()
        XCTAssertEqual(store.project, input)
    }

    func testInvalidSubtitleReplacementDoesNotPublishPersistOrRegisterUndo() throws {
        let original = projectFixture()
        let document = ProjectDocument(project: original)
        let undo = UndoManager()
        undo.groupsByEvent = false
        var persisted: [RecorderProject] = []
        let store = EditorStore(document: document, undoManager: undo, projectSink: { persisted.append($0) })
        var invalid = original
        invalid.subtitles.cues[0].wordIDs.append(UUID())
        XCTAssertThrowsError(try store.replaceProject(with: invalid, actionName: "无效字幕"))
        XCTAssertEqual(store.project, original)
        XCTAssertEqual(document.project, original)
        XCTAssertEqual(store.revision, 0)
        XCTAssertTrue(persisted.isEmpty)
        XCTAssertFalse(undo.canUndo)
        XCTAssertNoThrow(try store.replaceProject(with: original, actionName: "不变"))
        XCTAssertTrue(persisted.isEmpty)
    }

    func testManualSubtitleTextTimingAndStyleSharePersistenceAndUndo() throws {
        let original = projectFixture()
        let undo = UndoManager()
        undo.groupsByEvent = false
        var persisted: [RecorderProject] = []
        let store = EditorStore(project: original, undoManager: undo, projectSink: { persisted.append($0) })
        var edited = original
        try edited.subtitles.updateCueText(id: edited.subtitles.cues[0].id, text: "👩🏽‍💻 使用Swift和 café开发。")
        try edited.subtitles.updateCueTiming(id: edited.subtitles.cues[0].id,
            outputTimeRange: .init(start: 0.1, end: 1.8), timeline: edited.timeline, sourceDuration: 4)
        edited.subtitles.style.textColor = HexColor(rgb24: 0xF5_F0_E5)
        edited.subtitles.style.backgroundOpacity = 0.7
        undo.beginUndoGrouping()
        try store.replaceProject(with: edited, actionName: "编辑字幕")
        undo.endUndoGrouping()
        XCTAssertTrue(store.project.subtitles.cues[0].isManuallyEdited)
        XCTAssertEqual(store.project.subtitles.cues[0].text, "👩🏽‍💻 使用 Swift 和 café 开发")
        XCTAssertEqual(store.project.subtitles.words, original.subtitles.words)
        XCTAssertEqual(persisted, [edited])
        undo.undo()
        XCTAssertEqual(store.project, original)
        undo.redo()
        XCTAssertEqual(store.project, edited)
    }

    func testRelevantChangesRejectPendingGenerationOrCorrection() {
        let original = projectFixture()
        var changed = original
        changed.subtitles.script = "新稿件"
        XCTAssertFalse(EditorSubtitleController.inputIsUnchanged(original, current: changed))
        changed = original
        changed.subtitles.theme = "新主题"
        XCTAssertFalse(EditorSubtitleController.inputIsUnchanged(original, current: changed))
        changed = original
        changed.subtitles.cues[0].text = "人工修正"
        XCTAssertFalse(EditorSubtitleController.inputIsUnchanged(original, current: changed))
        changed = original
        changed.subtitles.audioSource = .system
        XCTAssertFalse(EditorSubtitleController.inputIsUnchanged(original, current: changed))
        changed = original
        changed.timeline.sourceSequence = .edited([RecordingSegment(sourceStart: 0.5, sourceDuration: 2)])
        XCTAssertFalse(EditorSubtitleController.inputIsUnchanged(original, current: changed))
        changed = original
        changed.audio.isMicrophoneMuted = true
        XCTAssertFalse(EditorSubtitleController.inputIsUnchanged(original, current: changed))
        changed = original
        changed.media?.microphone?.startOffset += 0.1
        XCTAssertFalse(EditorSubtitleController.inputIsUnchanged(original, current: changed))
    }

    func testReviewedFragmentEditAndUndoPreserveTrimmedTimeline() throws {
        var original = projectFixture()
        original.timeline.sourceSequence = .edited([RecordingSegment(sourceStart: 0.6, sourceDuration: 2)])
        let row = try XCTUnwrap(original.subtitles.resolvedCues(timeline: original.timeline, sourceDuration: 4).first)
        XCTAssertTrue(row.requiresReview)
        let undo = UndoManager()
        undo.groupsByEvent = false
        var persisted: [RecorderProject] = []
        let store = EditorStore(project: original, undoManager: undo, projectSink: { persisted.append($0) })
        var edited = original
        let id = try edited.subtitles.materializeResolvedCue(id: row.id, timeline: edited.timeline, sourceDuration: 4)
        try edited.subtitles.updateCueText(id: id, text: "Swift 正确术语")
        undo.beginUndoGrouping()
        try store.replaceProject(with: edited, actionName: "编辑剩余字幕")
        undo.endUndoGrouping()
        XCTAssertEqual(store.project.timeline, original.timeline)
        XCTAssertEqual(try store.project.subtitles.resolvedCues(timeline: original.timeline, sourceDuration: 4).map(\.text), ["Swift 正确术语"])
        XCTAssertEqual(persisted, [edited])
        undo.undo()
        XCTAssertEqual(store.project, original)
        XCTAssertEqual(store.project.timeline, original.timeline)
        XCTAssertEqual(persisted.last, original)
    }

    func testUnrelatedTitleAndVisualStyleDoNotRejectPendingResult() {
        let original = projectFixture()
        var current = original
        current.title = "修改标题"
        current.canvas.cornerRadius += 1
        current.camera.size = 0.25
        XCTAssertTrue(EditorSubtitleController.inputIsUnchanged(original, current: current))
        XCTAssertTrue(EditorSubtitleController.inputIsUnchanged(original, current: original))
    }

    func testAudioSignatureIgnoresVisualMediaAndSubtitlePresentation() {
        let original = projectFixture()
        var changed = original
        changed.title = "重命名"
        changed.subtitles.script = "修改参考稿"
        changed.subtitles.theme = "修改主题"
        changed.subtitles.style.fontSize = 60
        changed.subtitles.cues[0].text = "手工字幕"
        changed.subtitles.enabled = false
        changed.canvas.padding += 2
        changed.media?.camera = .init(relativePath: "media/new-camera.mov", startOffset: 1)
        changed.media?.pointerEvents = .init(relativePath: "media/new-pointer.json")
        XCTAssertEqual(EditorSubtitleController.audioSignature(for: original), EditorSubtitleController.audioSignature(for: changed))
    }

    func testAudioSignatureSurvivesCutsReorderAndRetime() {
        let original = projectFixture()
        var changed = original
        changed.timeline.sourceSequence = .edited([
            RecordingSegment(sourceStart: 2, sourceDuration: 1, playbackRate: 2),
            RecordingSegment(sourceStart: 0.2, sourceDuration: 1),
        ])
        XCTAssertEqual(EditorSubtitleController.audioSignature(for: original), EditorSubtitleController.audioSignature(for: changed))
    }

    func testAudioSignatureDetectsSelectedAudioAlignmentAndContentChanges() {
        let original = projectFixture()
        let signature = EditorSubtitleController.audioSignature(for: original)
        var changed = original
        changed.media?.microphone?.relativePath = "media/new-microphone.m4a"
        XCTAssertNotEqual(signature, EditorSubtitleController.audioSignature(for: changed))
        changed = original
        changed.media?.microphone?.sourceStartTime += 0.1
        XCTAssertNotEqual(signature, EditorSubtitleController.audioSignature(for: changed))
        changed = original
        changed.media?.microphone?.startOffset += 0.1
        XCTAssertNotEqual(signature, EditorSubtitleController.audioSignature(for: changed))
        changed = original
        changed.media?.microphone?.sourceTimeScale = 1.02
        XCTAssertNotEqual(signature, EditorSubtitleController.audioSignature(for: changed))
        changed = original
        changed.media?.screen.relativePath = "media/new-screen.mov"
        XCTAssertNotEqual(signature, EditorSubtitleController.audioSignature(for: changed))
        changed = original
        changed.subtitles.audioSource = .finalMix
        XCTAssertNotEqual(signature, EditorSubtitleController.audioSignature(for: changed))
    }

    func testAudioSignatureMixSettingsOnlyAffectFinalMixRecognition() {
        for source in SubtitleAudioSource.allCases {
            let original = projectFixture(audioSource: source)
            var changed = original
            changed.audio.microphoneVolume = 0.4
            changed.audio.systemVolume = 0.6
            changed.audio.isMicrophoneMuted = true
            changed.audio.isSystemMuted = true
            if source == .finalMix {
                XCTAssertNotEqual(EditorSubtitleController.audioSignature(for: original), EditorSubtitleController.audioSignature(for: changed))
            } else {
                XCTAssertEqual(EditorSubtitleController.audioSignature(for: original), EditorSubtitleController.audioSignature(for: changed))
            }
        }
    }

    func testSystemSignatureIgnoresUnselectedMicrophoneChanges() {
        let original = projectFixture(audioSource: .system)
        var changed = original
        changed.media?.microphone = .init(relativePath: "media/different-microphone.m4a", startOffset: 1)
        XCTAssertEqual(EditorSubtitleController.audioSignature(for: original), EditorSubtitleController.audioSignature(for: changed))
    }

    func testFinalMixSignatureTracksClipOverridesWithStableDictionaryOrder() {
        let a = UUID(), b = UUID()
        var original = projectFixture(audioSource: .finalMix)
        original.timeline.primarySegmentAudioOverrides[a] = .init(microphoneVolume: 0.4)
        original.timeline.primarySegmentAudioOverrides[b] = .init(isSystemMuted: true)
        var reordered = original
        reordered.timeline.primarySegmentAudioOverrides = [b: .init(isSystemMuted: true), a: .init(microphoneVolume: 0.4)]
        XCTAssertEqual(EditorSubtitleController.audioSignature(for: original), EditorSubtitleController.audioSignature(for: reordered))
        reordered.timeline.primarySegmentAudioOverrides[b] = .init(isSystemMuted: false)
        XCTAssertNotEqual(EditorSubtitleController.audioSignature(for: original), EditorSubtitleController.audioSignature(for: reordered))
        original.subtitles.audioSource = .microphone
        reordered.subtitles.audioSource = .microphone
        XCTAssertEqual(EditorSubtitleController.audioSignature(for: original), EditorSubtitleController.audioSignature(for: reordered))
    }

    func testSubtitleInspectorStaysSelectedForCanvasAndPrimaryClip() {
        for selection: EditorSelection? in [nil, .canvas, .primarySegment(UUID())] {
            XCTAssertEqual(EditorInspectorRouting.explicitTabAfterSelectionChange(selection, current: .subtitles), .subtitles)
        }
        for selection: EditorSelection in [.screen, .crop, .camera, .cursor, .zoomTrack, .audio(.microphone)] {
            XCTAssertNil(EditorInspectorRouting.explicitTabAfterSelectionChange(selection, current: .subtitles))
        }
    }

    func testOtherInspectorRoutingKeepsExistingSelectionBehavior() {
        XCTAssertEqual(EditorInspectorRouting.explicitTabAfterSelectionChange(.canvas, current: .opening), .opening)
        XCTAssertEqual(EditorInspectorRouting.explicitTabAfterSelectionChange(.canvas, current: .frame), .frame)
        XCTAssertNil(EditorInspectorRouting.explicitTabAfterSelectionChange(.canvas, current: .audio))
        XCTAssertEqual(EditorInspectorRouting.explicitTabAfterSelectionChange(.camera, current: .camera), .camera)
        XCTAssertNil(EditorInspectorRouting.explicitTabAfterSelectionChange(.camera, current: .zoom))
        for tab: InspectorTab? in [nil, .frame, .camera, .zoom, .cursor, .opening, .audio] {
            XCTAssertEqual(EditorInspectorRouting.explicitTabAfterSelectionChange(.primarySegment(UUID()), current: tab), .audio)
        }
        XCTAssertEqual(EditorInspectorRouting.tab(for: .canvas), .frame)
        XCTAssertEqual(EditorInspectorRouting.tab(for: .primarySegment(UUID())), .audio)
        XCTAssertEqual(EditorInspectorRouting.tab(for: .zoomTrack), .zoom)
        XCTAssertEqual(EditorInspectorRouting.tab(for: .audio(.microphone)), .audio)
    }
}
