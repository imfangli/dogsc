import AppKit
import AVFoundation
import RecorderCore
import SwiftUI
import XCTest
@testable import DogSCApp

@MainActor
final class SubtitleInspectorUITests: XCTestCase {
    func testInlineEditorFollowsExplicitNavigationWithoutPlaybackDiscardingDraft() async throws {
        _ = NSApplication.shared
        let words = (0..<40).map { index in
            SubtitleWord(text: "第\(index + 1)条字幕，在当前位置编辑完整文字。",
                         sourceRanges: [.init(start: Double(index * 3), end: Double(index * 3 + 2))])
        }
        let project = RecorderProject(subtitles: .init(enabled: true, words: words,
            cues: words.map { .init(wordIDs: [$0.id], text: $0.text) }))
        let media = try await makeMedia(project: project)
        let store = EditorStore(project: project)
        let playback = EditorPlaybackController()
        let navigation = EditorSubtitleNavigation()
        let editing = EditorSubtitleEditingSession()
        let controller = EditorSubtitleController()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 640),
            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: AppKeyboardFocusScrollView {
            EditorSubtitleInspector(editorStore: store, mediaSession: media,
                playbackController: playback, controller: controller, navigation: navigation, editing: editing)
                .padding(16)
        }.background(EditorTheme.panelSurface).preferredColorScheme(.dark))
        panel.contentView = host
        defer { panel.contentView = nil; panel.close() }
        await settle(panel)
        let scroll = try XCTUnwrap(descendants(of: NSScrollView.self, in: host).first)
        let rows = try project.subtitles.resolvedCues(timeline: project.timeline, sourceDuration: 120)
        let chosen = 22
        navigation.suspendFollowing()
        XCTAssertTrue(editing.select(project.subtitles.cues[chosen], row: rows[chosen], store: store, sourceDuration: 120))
        navigation.reveal(rows[chosen].cueID)
        await settle(panel)
        let editor = try XCTUnwrap(descendants(of: NSTextView.self, in: host).first { $0.string == rows[chosen].text })
        let editorFrame = editor.convert(editor.bounds, to: scroll.contentView)
        XCTAssertTrue(scroll.contentView.bounds.intersects(editorFrame), "The selected row's editor must be visible in place.")
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 300, "Editing a late cue must not return to the top controls.")
        editing.draft?.text = "输入中的完整字幕，普通播放不能打断"
        let editingOffset = scroll.contentView.bounds.minY
        playback.updateNavigationTime(105, origin: nil)
        await settle(panel)
        XCTAssertEqual(editing.draft?.cueID, rows[chosen].cueID)
        XCTAssertEqual(editing.draft?.text, "输入中的完整字幕，普通播放不能打断")
        XCTAssertEqual(scroll.contentView.bounds.minY, editingOffset, accuracy: 2)

        if let directory = ProcessInfo.processInfo.environment["DOGSC_SUBTITLE_UI_SNAPSHOT_DIR"] {
            panel.orderFront(nil)
            await settle(panel)
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("subtitle-inline.png"))
            }
        }

        playback.seek(to: 105, navigationOrigin: .timeline)
        await settle(panel)
        XCTAssertEqual(store.project.subtitles.cues[chosen].text, "输入中的完整字幕，普通播放不能打断")
        XCTAssertNil(editing.draft)
        XCTAssertEqual(navigation.activeCueID, rows[35].cueID)
        XCTAssertTrue(navigation.isFollowing)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, editingOffset)

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        XCTAssertFalse(navigation.isFollowing, "A real user scroll suspends follow; programmatic reveals do not.")
        navigation.resumeRequests.send()
        await settle(panel)
        XCTAssertTrue(navigation.isFollowing)
    }

    func testPausedSubtitleSeekRevealsOffscreenTimelinePlayhead() async throws {
        let media = try await makeMedia(project: RecorderProject())
        let playback = EditorPlaybackController(transportFactory: { item, _ in
            ImmediateTransport(item: item)
        }, initialFrameProvider: { _, _, _ in nil })
        await playback.install(media.prepared, audio: .init(), primarySegmentAudioOverrides: [:], frameRate: 30)
        defer { playback.invalidate() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 2400, height: 80))
        let coordinator = TimelineScrollViewBridge.Coordinator()
        coordinator.resolve(scroll)
        coordinator.configure(playbackController: playback)
        defer { coordinator.invalidate() }
        XCTAssertEqual(scroll.contentView.bounds.minX, 0)
        playback.seek(to: 105, loadsPausedFrame: false, navigationOrigin: .subtitle)
        for _ in 0..<3 { await Task.yield() }
        XCTAssertFalse(playback.isPlaying)
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, 1000, "A paused subtitle click must reveal an offscreen playhead.")
        let offset = scroll.contentView.bounds.minX
        playback.updateNavigationTime(0, origin: nil)
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(scroll.contentView.bounds.minX, offset, "Ordinary clock ticks must not move the timeline viewport.")
    }

    private final class ImmediateTransport: EditorPlaybackTransport {
        let item: AVPlayerItem?
        var currentTimeSeconds = 0.0
        var playbackRate: Float = 0
        var playbackClockIsAdvancing: Bool { playbackRate != 0 }
        init(item: AVPlayerItem) { self.item = item }
        func playTransport() { playbackRate = 1 }
        func playTransportImmediately(atRate rate: Float) { playbackRate = rate }
        func playTransport(at itemTime: CMTime, hostTime: CMTime, rate: Float) {
            currentTimeSeconds = itemTime.seconds; playbackRate = rate
        }
        func pauseTransport() { playbackRate = 0 }
        func cancelPendingSeeks() {}
        func seekTransport(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime) async -> Bool {
            currentTimeSeconds = time.seconds
            return true
        }
    }

    private func makeMedia(project: RecorderProject) async throws -> EditorMediaSession {
        let range = try XCTUnwrap(MediaTimeRange(start: 0, duration: 120))
        let plan = try ProjectTimelineMediaPlan(project: project, primaryVideoRange: range)
        let composition = AVMutableComposition()
        let video = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let bundle = TimelineCompositionBundle(plan: plan, primaryComposition: composition,
            primaryVideoTrack: video, primaryVideoTracks: [video], primaryVideoComposition: nil,
            systemAudioTrack: nil, microphoneAudioTrack: nil, cameraComposition: nil, cameraVideoTrack: nil)
        let payload = EditorPreparedMediaPayload(composition: bundle, inventories: .empty,
            sourceDisplaySize: CGSize(width: 1920, height: 1080), cameraDisplaySize: nil,
            cameraContentCrop: nil, cameraSource: nil)
        let media = EditorMediaSession(preparation: { _ in payload })
        await media.prepare(EditorMediaRequest(editorSessionID: EditorSessionID(), sourceURL: nil,
            cameraURL: nil, microphoneURL: nil, sourceSequence: project.timeline.sourceSequence,
            mediaManifest: project.media, pointerEvents: []))
        return media
    }

    private func settle(_ panel: NSPanel) async {
        for _ in 0..<8 {
            panel.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(40))
        }
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(of: type, in: $0) }
    }
}
