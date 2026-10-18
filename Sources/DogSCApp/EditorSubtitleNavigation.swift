import Combine
import Foundation
import RecorderCore

/// Samples the editor's existing clock, publishing only cue/follow changes.
/// No extra timer or per-frame SwiftUI publication is needed.
@MainActor
final class EditorSubtitleNavigation: ObservableObject, EditorPlaybackTimelineObserver {
    @Published private(set) var activeCueID: UUID?
    @Published private(set) var isFollowing = true
    @Published private(set) var revealRequest: AppScrollRevealRequest?
    let timelineNavigations = PassthroughSubject<TimeInterval, Never>()
    let resumeRequests = PassthroughSubject<Void, Never>()
    let unassignedRequests = PassthroughSubject<Void, Never>()
    let unassignedSectionID = UUID()
    @Published private(set) var unassignedCount = 0
    private var rows: [ResolvedSubtitleCue] = []
    private var currentTime = 0.0
    private var previousRevision: UInt64?
    private var lastRevealedID: UUID?
    private weak var playback: EditorPlaybackController?

    func connect(to playback: EditorPlaybackController) {
        guard self.playback !== playback else { return }
        disconnect()
        self.playback = playback
        playback.addNativeTimelineObserver(self)
    }

    func disconnect() {
        playback?.removeNativeTimelineObserver(self)
        playback = nil
        previousRevision = nil
    }

    func update(rows: [ResolvedSubtitleCue], unassignedCount: Int = 0) {
        if self.unassignedCount != unassignedCount { self.unassignedCount = unassignedCount }
        self.rows = rows
        updateActiveCue()
    }

    func editorPlaybackTimelineDidUpdate(_ snapshot: EditorPlaybackTimelineSnapshot) {
        let navigated = previousRevision.map { $0 != snapshot.navigationRevision } ?? false
        previousRevision = snapshot.navigationRevision
        currentTime = snapshot.outputTime
        updateActiveCue()
        if navigated, snapshot.navigationOrigin == .timeline {
            timelineNavigations.send(snapshot.outputTime)
        }
    }

    func suspendFollowing() {
        if isFollowing { isFollowing = false }
    }

    func resumeFollowing() {
        if !isFollowing {
            isFollowing = true
            lastRevealedID = nil
        }
        revealActiveCue()
    }

    func reveal(_ id: UUID) {
        lastRevealedID = id
        revealRequest = AppScrollRevealRequest(id: id)
    }

    private func updateActiveCue() {
        // Rows are sorted. Binary search avoids scanning an entire transcript
        // for each display-link tick and uses end-exclusive subtitle intervals.
        var lower = 0, upper = rows.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if rows[middle].startTime <= currentTime { lower = middle + 1 } else { upper = middle }
        }
        let row = lower > 0 ? rows[lower - 1] : nil
        let active = row.flatMap { currentTime < $0.endTime ? $0.cueID : nil }
        if activeCueID != active { activeCueID = active }
        revealActiveCue()
    }

    private func revealActiveCue() {
        guard isFollowing, let id = activeCueID, lastRevealedID != id else { return }
        reveal(id)
    }
}
