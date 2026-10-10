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

    public func resolvedCues(
        timeline: ProjectTimeline,
        sourceDuration: TimeInterval
    ) throws -> [ResolvedSubtitleCue] {
        let map = try TimelineMap(sourceSequence: timeline.sourceSequence, fullSourceDuration: sourceDuration)
        let wordLookup = Dictionary(words.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var speechLocations: [(id: UUID, start: TimeInterval, end: TimeInterval)] = []
        let locations: [(id: UUID, start: TimeInterval, end: TimeInterval)] = words.compactMap { word in
            let ranges = Self.project(word.sourceRanges, through: map)
            guard !ranges.isEmpty else { return nil }
            speechLocations.append(contentsOf: ranges.map { (word.id, $0.start, $0.end) })
            let retained = ranges.reduce(0.0) { $0 + $1.sourceDuration }
            let authored = word.sourceRanges.reduce(0.0) { $0 + $1.duration }
            // A cut inside the smallest timed unit cannot safely split its
            // displayed text. Omit it and show retained units for review.
            guard abs(retained - authored) < 0.000_01,
                  Self.rangeOrderIsPreserved(ranges), Self.joinAdjacent(ranges).count == 1 else { return nil }
            return (word.id, ranges.map(\.start).min()!, ranges.map(\.end).max()!)
        }.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        let locationLookup = Dictionary(locations.enumerated().map {
            ($0.element.id, (start: $0.element.start, end: $0.element.end, order: $0.offset))
        }, uniquingKeysWith: { first, _ in first })
        speechLocations.sort { $0.start < $1.start }
        var maximumEnd: TimeInterval = 0
        let prefixMaximumEnds = speechLocations.map { location in
            maximumEnd = max(maximumEnd, location.end)
            return maximumEnd
        }
        // Binary search excludes unrelated speech before/after the cue. This
        // avoids scanning every transcript unit for every manually edited cue.
        func hasForeignSpeech(start: Double, end: Double, ownedIDs: Set<UUID>) -> Bool {
            var lower = 0, upper = prefixMaximumEnds.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if prefixMaximumEnds[middle] <= start { lower = middle + 1 } else { upper = middle }
            }
            var index = lower
            while index < speechLocations.count, speechLocations[index].start < end {
                let candidate = speechLocations[index]
                if candidate.end > start, !ownedIDs.contains(candidate.id) { return true }
                index += 1
            }
            return false
        }
        var result: [ResolvedSubtitleCue] = []
        for cue in cues {
            let ownedIDs = Set(cue.wordIDs)
            let original = cue.wordIDs.compactMap { wordLookup[$0] }
            let mappedWords: [MappedWord] = original.enumerated().compactMap { index, word in
                guard let location = locationLookup[word.id] else { return nil }
                if let manual = cue.manualSourceRanges {
                    let authored = word.sourceRanges.reduce(0.0) { $0 + $1.duration }
                    let covered = word.sourceRanges.reduce(0.0) { total, wordRange in
                        total + manual.reduce(0.0) { sum, range in
                            sum + max(0, min(wordRange.end, range.end) - max(wordRange.start, range.start))
                        }
                    }
                    guard abs(covered - authored) < 0.000_01 else { return nil }
                }
                return MappedWord(
                    word: word, originalIndex: index, globalIndex: location.order,
                    start: location.start, end: location.end
                )
            }.sorted { $0.start == $1.start ? $0.originalIndex < $1.originalIndex : $0.start < $1.start }
            let allRetainedInOrder = mappedWords.count == original.count
                && mappedWords.map(\.originalIndex) == Array(original.indices)
                && zip(mappedWords, mappedWords.dropFirst()).allSatisfy { $1.globalIndex == $0.globalIndex + 1 }
                && !hasForeignSpeech(start: mappedWords.first?.start ?? 0, end: mappedWords.last?.end ?? 0, ownedIDs: ownedIDs)

            if let manual = cue.manualSourceRanges {
                let projected = Self.project(manual, through: map)
                let retained = projected.reduce(0.0) { $0 + $1.sourceDuration }
                let authored = manual.reduce(0.0) { $0 + $1.duration }
                let spanStart = projected.first?.start ?? 0
                let spanEnd = projected.last?.end ?? 0
                let ownsWholeSpan = !hasForeignSpeech(start: spanStart, end: spanEnd, ownedIDs: ownedIDs)
                let preservedRangeOrder = Self.rangeOrderIsPreserved(projected)
                let safeManualSpan = ownsWholeSpan && preservedRangeOrder
                let explicitManualText = cue.isManuallyEdited && safeManualSpan
                // A human-only cue has no original text to fall back to. Keep
                // its timing fragments but flag any cropped authored range.
                if original.isEmpty || (safeManualSpan && (allRetainedInOrder || explicitManualText)
                                        && abs(retained - authored) < 0.000_01) {
                    let displayRanges: [ProjectedRange]
                    if !original.isEmpty, let first = projected.first, let last = projected.last {
                        // Word anchors have silence between them. A human merge
                        // displays one sentence through those gaps, rather than
                        // repeating the complete sentence for each original unit.
                        displayRanges = [.init(start: first.start, end: last.end, sourceDuration: retained)]
                    } else { displayRanges = Self.joinAdjacent(projected) }
                    for (index, range) in displayRanges.enumerated() {
                        append(cue: cue, text: cue.text, start: range.start, end: range.end,
                               fragment: "manual-\(index)", review: abs(retained - authored) >= 0.000_01 || !preservedRangeOrder,
                               to: &result)
                    }
                    continue
                }
            } else if allRetainedInOrder, let first = mappedWords.first, let last = mappedWords.last {
                append(cue: cue, text: cue.text, start: first.start, end: last.end,
                       fragment: "full", review: false, to: &result)
                continue
            }

            // Missing or rearranged units invalidate a whole corrected sentence.
            // Never carry words from deleted speech into a surviving fragment.
            var run: [MappedWord] = []
            func flushRun() {
                guard let first = run.first, let last = run.last else { return }
                append(cue: cue, text: SubtitleTextFormatter.joinUnits(run.map { $0.word.text }),
                       start: first.start, end: last.end,
                       fragment: "\(first.word.id.uuidString)-\(last.word.id.uuidString)", review: true,
                       to: &result)
                run.removeAll(keepingCapacity: true)
            }
            for word in mappedWords {
                if let previous = run.last,
                   word.originalIndex != previous.originalIndex + 1 || word.globalIndex != previous.globalIndex + 1
                    || hasForeignSpeech(start: previous.start, end: word.end, ownedIDs: ownedIDs) {
                    flushRun()
                }
                run.append(word)
            }
            flushRun()
        }
        return result.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            return $0.id < $1.id
        }
    }

    private struct MappedWord {
        let word: SubtitleWord
        let originalIndex: Int
        let globalIndex: Int
        let start: TimeInterval
        let end: TimeInterval
    }

    private struct ProjectedRange {
        var start: TimeInterval
        var end: TimeInterval
        var sourceDuration: TimeInterval
        var sourceRangeIndex: Int = 0
        var sourceStart: TimeInterval = 0
    }

    private static func project(_ ranges: [SubtitleTimeRange], through map: TimelineMap) -> [ProjectedRange] {
        map.segments.flatMap { segment in
            ranges.enumerated().compactMap { index, range in
                let start = max(range.start, segment.sourceStart)
                let end = min(range.end, segment.sourceEnd)
                guard end > start else { return nil }
                return ProjectedRange(
                    start: segment.outputStart + (start - segment.sourceStart) / segment.playbackRate,
                    end: segment.outputStart + (end - segment.sourceStart) / segment.playbackRate,
                    sourceDuration: end - start, sourceRangeIndex: index, sourceStart: start
                )
            }
        }.sorted { $0.start < $1.start }
    }

    private static func joinAdjacent(_ ranges: [ProjectedRange]) -> [ProjectedRange] {
        var result: [ProjectedRange] = []
        for range in ranges {
            if let last = result.last, abs(last.end - range.start) < 0.000_01 {
                result[result.count - 1].end = range.end
                result[result.count - 1].sourceDuration += range.sourceDuration
            } else {
                result.append(range)
            }
        }
        return result
    }

    private static func rangeOrderIsPreserved(_ projected: [ProjectedRange]) -> Bool {
        return zip(projected, projected.dropFirst()).allSatisfy {
            $0.sourceRangeIndex < $1.sourceRangeIndex
                || ($0.sourceRangeIndex == $1.sourceRangeIndex && $0.sourceStart <= $1.sourceStart)
        }
    }

    private func append(
        cue: SubtitleCue, text: String, start: TimeInterval, end: TimeInterval,
        fragment: String, review: Bool, to result: inout [ResolvedSubtitleCue]
    ) {
        let formatted = SubtitleTextFormatter.format(text)
        guard end > start, !formatted.isEmpty else { return }
        result.append(ResolvedSubtitleCue(
            id: "\(cue.id.uuidString):\(fragment)", cueID: cue.id, text: formatted,
            startTime: start, endTime: end, requiresReview: review
        ))
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
