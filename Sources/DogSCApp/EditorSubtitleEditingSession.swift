import Foundation
import RecorderCore

struct EditorSubtitleDraft: Equatable {
    let cueID: UUID
    var text: String
    var start: String
    var end: String
    fileprivate var originalCue: SubtitleCue
    fileprivate var originalSequence: SourceSequence
    fileprivate var initialText: String
    fileprivate var initialStart: String
    fileprivate var initialEnd: String

    init(cue: SubtitleCue, row: ResolvedSubtitleCue?, sequence: SourceSequence) {
        cueID = cue.id
        text = row?.text ?? cue.text
        start = row.map { String(format: "%.3f", $0.startTime) } ?? ""
        end = row.map { String(format: "%.3f", $0.endTime) } ?? ""
        originalCue = cue
        originalSequence = sequence
        initialText = text
        initialStart = start
        initialEnd = end
    }

    var isDirty: Bool { text != initialText || timingIsDirty }
    var timingIsDirty: Bool { start != initialStart || end != initialEnd }
}

/// Drafts survive focus, playback and inspector routing changes. One successful
/// commit crosses the editor command boundary once, so one undo restores it.
@MainActor
final class EditorSubtitleEditingSession: ObservableObject {
    @Published var draft: EditorSubtitleDraft?
    @Published private(set) var errorMessage: String?

    @discardableResult
    func select(_ cue: SubtitleCue, row: ResolvedSubtitleCue?, store: EditorStore, sourceDuration: Double) -> Bool {
        if draft?.cueID == cue.id { return true }
        guard commit(store: store, sourceDuration: sourceDuration) else { return false }
        draft = EditorSubtitleDraft(cue: cue, row: row, sequence: store.project.timeline.sourceSequence)
        errorMessage = nil
        return true
    }

    @discardableResult
    func commit(store: EditorStore, sourceDuration: Double) -> Bool {
        guard let draft, draft.isDirty else { return true }
        do {
            var project = store.project
            guard let cue = project.subtitles.cues.first(where: { $0.id == draft.cueID }) else {
                throw SubtitleEditingError.cueNotFound
            }
            guard cue == draft.originalCue else {
                errorMessage = appLocalized("这条字幕已在其他操作中改变，草稿已保留。请取消本轮修改后重新编辑。")
                return false
            }
            if draft.timingIsDirty {
                guard draft.originalSequence == project.timeline.sourceSequence else {
                    errorMessage = appLocalized("时间线已改变，草稿已保留。请取消本轮时间修改后重新编辑。")
                    return false
                }
                guard let start = Double(draft.start), let end = Double(draft.end),
                      start.isFinite, end.isFinite else {
                    throw SubtitleEditingError.invalidTimeRange
                }
                try project.subtitles.updateCueTiming(id: draft.cueID,
                    outputTimeRange: .init(start: start, end: end),
                    timeline: project.timeline, sourceDuration: sourceDuration)
            }
            if draft.text != draft.initialText {
                try project.subtitles.updateCueText(id: draft.cueID, text: draft.text)
            }
            try store.replaceProject(with: project, actionName: "编辑字幕")
            self.draft = nil
            reconcile(project: store.project, sourceDuration: sourceDuration, selectedID: draft.cueID)
            errorMessage = nil
            return true
        } catch {
            errorMessage = appErrorDescription(error)
            return false
        }
    }

    func cancel() {
        if draft != nil { draft = nil }
        if errorMessage != nil { errorMessage = nil }
    }

    func reconcile(project: RecorderProject, sourceDuration: Double, selectedID: UUID? = nil) {
        guard let id = selectedID ?? draft?.cueID else { return }
        guard let cue = project.subtitles.cues.first(where: { $0.id == id }), !cue.text.isEmpty else {
            // External deletion is authoritative; never resurrect it on blur.
            cancel()
            return
        }
        let row = (try? project.subtitles.resolvedCues(timeline: project.timeline, sourceDuration: sourceDuration))?
            .first { $0.cueID == id }
        let fresh = EditorSubtitleDraft(cue: cue, row: row, sequence: project.timeline.sourceSequence)
        if var existing = draft, existing.isDirty {
            // A text draft follows new timing without losing its text or focus.
            // A draft with authored time fields must be reviewed after a cut.
            if cue == existing.originalCue, !existing.timingIsDirty {
                existing.start = fresh.start
                existing.end = fresh.end
                existing.initialStart = fresh.initialStart
                existing.initialEnd = fresh.initialEnd
                existing.originalSequence = fresh.originalSequence
                draft = existing
            }
        } else {
            draft = fresh
        }
    }
}
