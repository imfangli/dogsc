import Foundation

/// Resolves source-anchored cues only when the script or edit sequence changes.
/// The display clock then performs an indexed lookup without projecting every
/// timed word again for every preview/export frame.
enum FrameSubtitleEvaluator {
    private static let cache = FrameSubtitleCueCache()

    static func scene(
        project: RecorderProject,
        at time: TimeInterval,
        outputDuration: TimeInterval?,
        canvasSize: CompositionSize
    ) -> FrameSubtitleScene? {
        let document = project.subtitles
        guard document.enabled,
              let cue = cache.cue(
                document: document, sequence: project.timeline.sourceSequence,
                outputDuration: outputDuration, at: time
              ) else { return nil }
        let scale = CompositionSceneEvaluator.canonicalStyleScale(
            canvasWidth: canvasSize.width, canvasHeight: canvasSize.height
        )
        return FrameSubtitleScene(
            text: cue.text,
            fontSize: document.style.fontSize * scale,
            textColor: document.style.textColor,
            backgroundColor: document.style.backgroundColor,
            backgroundOpacity: document.style.backgroundOpacity,
            bottomInset: document.style.bottomInset * canvasSize.height
        )
    }
}

final class FrameSubtitleCueCache: @unchecked Sendable {
    /// Only projection inputs belong here. Style, reference script/theme,
    /// audio selection and visibility do not change source-to-output mapping.
    private struct Key: Equatable {
        let words: [SubtitleWord]
        let cues: [SubtitleCue]
        let sequence: SourceSequence
        let outputDuration: TimeInterval?
    }

    private struct Entry {
        let key: Key
        let cues: [ResolvedSubtitleCue]
        let prefixMaxEnd: [TimeInterval]
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var completedProjections = 0

    /// An instance-local probe verifies that visual slider changes reuse the
    /// projection. It never counts frame lookups or text rasterization.
    var projectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return completedProjections
    }

    func cue(
        document: SubtitleDocument,
        sequence: SourceSequence,
        outputDuration: TimeInterval?,
        at time: TimeInterval
    ) -> ResolvedSubtitleCue? {
        guard time.isFinite, time >= 0, !document.cues.isEmpty else { return nil }
        let key = Key(words: document.words, cues: document.cues, sequence: sequence,
                      outputDuration: outputDuration)
        lock.lock()
        defer { lock.unlock() }
        let entry: Entry
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entry = entries.remove(at: index)
            entries.append(entry)
        } else {
            let sourceDuration: TimeInterval
            switch sequence {
            case .fullRecording:
                sourceDuration = outputDuration ?? max(
                    document.words.lazy.flatMap(\.sourceRanges).map(\.end).max() ?? 0,
                    document.cues.lazy.flatMap { $0.manualSourceRanges ?? [] }.map(\.end).max() ?? 0
                )
            case let .edited(segments):
                sourceDuration = segments.lazy.map(\.sourceEnd).max() ?? 0
            }
            guard sourceDuration.isFinite, sourceDuration > 0 else { return nil }
            let cues = (try? document.resolvedCues(
                timeline: ProjectTimeline(sourceSequence: sequence), sourceDuration: sourceDuration
            )) ?? []
            completedProjections += 1
            var maximum: TimeInterval = 0
            let prefixMaxEnd = cues.map { cue in
                maximum = max(maximum, cue.endTime)
                return maximum
            }
            entry = Entry(key: key,
                          cues: cues, prefixMaxEnd: prefixMaxEnd)
            if entries.count >= 4 { entries.removeFirst() }
            entries.append(entry)
        }
        var lower = 0
        var upper = entry.cues.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if entry.cues[middle].startTime <= time { lower = middle + 1 } else { upper = middle }
        }
        var index = lower - 1
        var selected: ResolvedSubtitleCue?
        // Normally one cue is active. If authored timing overlaps, preserve
        // deterministic source order instead of flickering between captions.
        while index >= 0, entry.prefixMaxEnd[index] > time {
            let cue = entry.cues[index]
            if cue.endTime > time { selected = cue }
            index -= 1
        }
        return selected
    }
}
