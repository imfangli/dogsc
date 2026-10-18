import Foundation

extension SubtitleDocument {
    /// Converts edited-audio ASR time to persistent screen-source anchors.
    /// Each returned range belongs to one recording segment, in output order.
    public static func sourceRanges(
        for outputTimeRange: SubtitleTimeRange,
        timeline: ProjectTimeline,
        sourceDuration: TimeInterval
    ) throws -> [SubtitleTimeRange] {
        guard outputTimeRange.isValid else { throw SubtitleEditingError.invalidTimeRange }
        let map = try TimelineMap(sourceSequence: timeline.sourceSequence, fullSourceDuration: sourceDuration)
        return map.segments.compactMap { segment in
            let start = max(outputTimeRange.start, segment.outputStart)
            let end = min(outputTimeRange.end, segment.outputEnd)
            guard end > start else { return nil }
            return SubtitleTimeRange(
                start: segment.sourceStart + (start - segment.outputStart) * segment.playbackRate,
                end: segment.sourceStart + (end - segment.outputStart) * segment.playbackRate
            )
        }
    }

    /// Text is authored independently of the cut. Projection only selects a
    /// surviving interval; it never reconstructs a sentence from ASR units.
    public func resolvedCues(
        timeline: ProjectTimeline,
        sourceDuration: TimeInterval
    ) throws -> [ResolvedSubtitleCue] {
        let map = try TimelineMap(sourceSequence: timeline.sourceSequence, fullSourceDuration: sourceDuration)
        let lookup = Dictionary(words.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let speech = words.flatMap { word in
            Self.project(word.sourceRanges, through: map).map { (id: word.id, range: $0) }
        }.sorted { $0.range.start < $1.range.start }
        var maximumEnd = 0.0
        let maximumEnds = speech.map { item in
            maximumEnd = max(maximumEnd, item.range.end)
            return maximumEnd
        }
        func containsForeignSpeech(from start: Double, to end: Double, owned: Set<UUID>) -> Bool {
            var lower = 0, upper = speech.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if maximumEnds[middle] <= start + 0.000_01 { lower = middle + 1 } else { upper = middle }
            }
            var index = lower
            while index < speech.count, speech[index].range.start < end - 0.000_01 {
                if speech[index].range.end > start + 0.000_01, !owned.contains(speech[index].id) { return true }
                index += 1
            }
            return false
        }
        var result: [ResolvedSubtitleCue] = []
        for cue in cues {
            let text = SubtitleTextFormatter.format(cue.text)
            // Explicit deletion stays deleted, even when source video returns.
            guard !text.isEmpty else { continue }
            let anchors = cue.manualSourceRanges ?? cue.wordIDs.flatMap { lookup[$0]?.sourceRanges ?? [] }
            let pieces = Self.project(anchors, through: map)
            guard !pieces.isEmpty else { continue }
            let owned = Set(cue.wordIDs)
            var runs: [[ProjectedRange]] = []
            for piece in pieces {
                if let previous = runs.last?.last {
                    let ordered = piece.sourceRangeIndex > previous.sourceRangeIndex
                        || (piece.sourceRangeIndex == previous.sourceRangeIndex
                            && piece.sourceStart >= previous.sourceEnd - 0.000_01)
                    let foreign = cue.manualSourceRanges == nil
                        && containsForeignSpeech(from: previous.end, to: piece.start, owned: owned)
                    if ordered, !foreign, Self.canBridge(previous, piece, through: map) {
                        runs[runs.count - 1].append(piece)
                        continue
                    }
                }
                runs.append([piece])
            }
            // Reordered sentences occur once, on their longest continuous
            // surviving run. Equal runs prefer the earlier output position.
            let chosen = runs.max { a, b in
                let aDuration = a.last!.end - a.first!.start
                let bDuration = b.last!.end - b.first!.start
                return abs(aDuration - bDuration) < 0.000_01
                    ? a.first!.start > b.first!.start : aDuration < bDuration
            }!
            let retained = pieces.reduce(0.0) { $0 + $1.sourceDuration }
            let authored = anchors.reduce(0.0) { $0 + $1.duration }
            result.append(ResolvedSubtitleCue(
                id: "\(cue.id.uuidString):full", cueID: cue.id, text: text,
                startTime: chosen.first!.start, endTime: chosen.last!.end,
                requiresReview: runs.count > 1 || abs(retained - authored) > 0.000_01,
                wasRearranged: runs.count > 1
            ))
        }
        return result.sorted {
            $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime < $1.startTime
        }
    }

    public func unassignedCues(timeline: ProjectTimeline, sourceDuration: TimeInterval) throws -> [SubtitleCue] {
        let assigned = Set(try resolvedCues(timeline: timeline, sourceDuration: sourceDuration).map(\.cueID))
        return cues.filter { !assigned.contains($0.id) && !SubtitleTextFormatter.format($0.text).isEmpty }
    }

    private struct ProjectedRange {
        let start: TimeInterval
        let end: TimeInterval
        let sourceDuration: TimeInterval
        let sourceRangeIndex: Int
        let sourceStart: TimeInterval
        let sourceEnd: TimeInterval
    }

    private static func project(_ ranges: [SubtitleTimeRange], through map: TimelineMap) -> [ProjectedRange] {
        var result: [ProjectedRange] = []
        for segment in map.segments {
            for (index, range) in ranges.enumerated() {
                let start = max(range.start, segment.sourceStart)
                let end = min(range.end, segment.sourceEnd)
                guard end > start else { continue }
                result.append(ProjectedRange(
                    start: segment.outputStart + (start - segment.sourceStart) / segment.playbackRate,
                    end: segment.outputStart + (end - segment.sourceStart) / segment.playbackRate,
                    sourceDuration: end - start, sourceRangeIndex: index, sourceStart: start, sourceEnd: end
                ))
            }
        }
        return result.sorted {
            $0.start == $1.start ? $0.sourceRangeIndex < $1.sourceRangeIndex : $0.start < $1.start
        }
    }

    /// Natural silence between a cue's anchors belongs to the sentence, while
    /// newly inserted/reordered source material must not stretch it over others.
    private static func canBridge(_ a: ProjectedRange, _ b: ProjectedRange, through map: TimelineMap) -> Bool {
        if b.start <= a.end + 0.000_01 { return true }
        guard b.sourceStart >= a.sourceEnd - 0.000_01 else { return false }
        var previousEnd = a.sourceEnd
        for segment in map.segments {
            let start = max(a.end, segment.outputStart)
            let end = min(b.start, segment.outputEnd)
            guard end > start + 0.000_01 else { continue }
            let sourceStart = segment.sourceStart + (start - segment.outputStart) * segment.playbackRate
            let sourceEnd = segment.sourceStart + (end - segment.outputStart) * segment.playbackRate
            guard sourceStart >= previousEnd - 0.000_01, sourceEnd <= b.sourceStart + 0.000_01 else { return false }
            previousEnd = sourceEnd
        }
        return true
    }
}

public enum SubtitleSRTExporter {
    /// SRT always uses current edited output times, including rate changes.
    public static func export(_ cues: [ResolvedSubtitleCue]) -> String {
        var entries: [String] = []
        for cue in cues.sorted(by: { $0.startTime < $1.startTime }) {
            guard cue.startTime.isFinite, cue.endTime.isFinite, cue.startTime >= 0,
                  cue.endTime > cue.startTime,
                  cue.endTime < Double(Int64.max / 1_000) else { continue }
            let start = Int64((cue.startTime * 1_000).rounded())
            let end = max(Int64((cue.endTime * 1_000).rounded()), start + 1)
            let text = SubtitleTextFormatter.format(cue.text).split(separator: "\n", omittingEmptySubsequences: true)
                .joined(separator: "\n")
            guard !text.isEmpty else { continue }
            entries.append("\(entries.count + 1)\n\(timestamp(start)) --> \(timestamp(end))\n\(text)")
        }
        return entries.isEmpty ? "" : entries.joined(separator: "\n\n") + "\n"
    }

    private static func timestamp(_ milliseconds: Int64) -> String {
        String(format: "%02lld:%02lld:%02lld,%03lld", milliseconds / 3_600_000,
               (milliseconds / 60_000) % 60, (milliseconds / 1_000) % 60, milliseconds % 1_000)
    }
}
