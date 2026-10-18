import Foundation

/// The AI response intentionally has no timestamp fields. Every boundary is a
/// stable original timed-unit ID, validated before any project value changes.
public struct SubtitleCorrectionGroup: Codable, Equatable, Sendable {
    public var wordIDs: [UUID]
    public var text: String

    public init(wordIDs: [UUID], text: String) {
        self.wordIDs = wordIDs
        self.text = text
    }
}

public enum SubtitleEditingError: Error, Equatable, Sendable {
    case cueNotFound
    case invalidSplit
    case nonAdjacentCues
    case invalidTimeRange
    case overlappingTiming
    case invalidCorrectionIDs
    case invalidCorrectionText
    case invalidDocument(reason: String)
}

extension SubtitleEditingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cueNotFound: return "字幕已不存在，请刷新后重试。"
        case .invalidSplit: return "请选择字幕内部的字词分界。"
        case .nonAdjacentCues: return "只能合并相邻字幕。"
        case .invalidTimeRange: return "字幕时间必须位于成片内，且结束时间晚于开始时间。"
        case .overlappingTiming: return "字幕时间与其他字幕重叠，请先调整相邻字幕。"
        case .invalidCorrectionIDs: return "AI 返回的字幕未完整保留原始字词顺序，已拒绝应用。"
        case .invalidCorrectionText: return "AI 返回了空白或过长的字幕，已拒绝应用。"
        case let .invalidDocument(reason): return "字幕数据无效：\(reason)"
        }
    }
}

extension SubtitleDocument {
    /// Acknowledges a projected interval without replacing authored text,
    /// creating fragment IDs, or losing the original unit ownership.
    @discardableResult
    public mutating func materializeResolvedCue(
        id: String, timeline: ProjectTimeline, sourceDuration: TimeInterval
    ) throws -> UUID {
        let projected = try resolvedCues(timeline: timeline, sourceDuration: sourceDuration)
        guard let selected = projected.first(where: { $0.id == id }),
              let index = cues.firstIndex(where: { $0.id == selected.cueID }) else {
            throw SubtitleEditingError.cueNotFound
        }
        if selected.requiresReview {
            cues[index].manualSourceRanges = try Self.sourceRanges(
                for: .init(start: selected.startTime, end: selected.endTime),
                timeline: timeline, sourceDuration: sourceDuration)
            cues[index].isManuallyEdited = true
        }
        return selected.cueID
    }

    /// Restores an unassigned cue into a free output gap. Its original words
    /// and authored text remain intact; only the human timing override changes.
    public mutating func placeCue(
        id: UUID, atOutputTime start: TimeInterval,
        timeline: ProjectTimeline, sourceDuration: TimeInterval
    ) throws {
        guard let cue = cues.first(where: { $0.id == id }),
              !SubtitleTextFormatter.format(cue.text).isEmpty else { throw SubtitleEditingError.cueNotFound }
        let map = try TimelineMap(sourceSequence: timeline.sourceSequence, fullSourceDuration: sourceDuration)
        guard start.isFinite, start >= 0, start < map.outputDuration else { throw SubtitleEditingError.invalidTimeRange }
        let others = try resolvedCues(timeline: timeline, sourceDuration: sourceDuration).filter { $0.cueID != id }
        guard !others.contains(where: { start >= $0.startTime && start < $0.endTime }) else {
            throw SubtitleEditingError.overlappingTiming
        }
        let nextStart = others.filter { $0.startTime > start }.map(\.startTime).min() ?? map.outputDuration
        let end = min(start + cue.suggestedDuration, nextStart, map.outputDuration)
        try updateCueTiming(id: id, outputTimeRange: .init(start: start, end: end),
                            timeline: timeline, sourceDuration: sourceDuration)
    }

    /// Validates exact ordered coverage for the whole document, or an explicit
    /// ordered batch. Applying is atomic and does not alter any timed unit.
    public mutating func applyCorrections(
        _ groups: [SubtitleCorrectionGroup], wordIDs selectedIDs: [UUID]? = nil
    ) throws {
        let protectedIDs = Set(cues.filter(\.isManuallyEdited).flatMap(\.wordIDs))
        let expected = selectedIDs ?? words.map(\.id).filter { !protectedIDs.contains($0) }
        let allIDs = words.map(\.id)
        let selectedSet = Set(expected)
        guard !expected.isEmpty, Set(expected).count == expected.count,
              selectedSet.isDisjoint(with: protectedIDs),
              allIDs.filter({ selectedSet.contains($0) }) == expected,
              groups.flatMap(\.wordIDs) == expected,
              groups.allSatisfy({ group in
                  guard let firstID = group.wordIDs.first,
                        let first = allIDs.firstIndex(of: firstID),
                        first + group.wordIDs.count <= allIDs.count else { return false }
                  return Array(allIDs[first..<(first + group.wordIDs.count)]) == group.wordIDs
              }) else {
            throw SubtitleEditingError.invalidCorrectionIDs
        }
        let replacements = try groups.map { group in
            let text = SubtitleTextFormatter.format(group.text)
            guard !text.isEmpty, text.count <= 512, text.utf8.count <= 4_096,
                  !text.unicodeScalars.contains(where: {
                      $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t"
                  }) else { throw SubtitleEditingError.invalidCorrectionText }
            return SubtitleCue(wordIDs: group.wordIDs, text: text)
        }
        let selected = Set(expected)
        let affected = cues.indices.filter { !selected.isDisjoint(with: cues[$0].wordIDs) }
        // A batch cannot silently overwrite the other half of an existing cue.
        guard affected.allSatisfy({ Set(cues[$0].wordIDs).isSubset(of: selected) }) else {
            throw SubtitleEditingError.invalidCorrectionIDs
        }
        let insertion = affected.first ?? cues.endIndex
        var next = cues
        for index in affected.reversed() { next.remove(at: index) }
        next.insert(contentsOf: replacements, at: min(insertion, next.count))
        let positions = Dictionary(allIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        next = next.enumerated().sorted { lhs, rhs in
            let a = lhs.element.wordIDs.compactMap { positions[$0] }.min() ?? Int.max
            let b = rhs.element.wordIDs.compactMap { positions[$0] }.min() ?? Int.max
            return a == b ? lhs.offset < rhs.offset : a < b
        }.map(\.element)
        cues = next
    }

    public mutating func updateCueText(id: UUID, text: String) throws {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { throw SubtitleEditingError.cueNotFound }
        cues[index].text = SubtitleTextFormatter.format(text)
        cues[index].isManuallyEdited = true
    }

    /// Word boundaries preserve ASR timestamps exactly. Corrected text can be
    /// supplied explicitly; defaults fall back to the original timed units.
    public mutating func splitCue(
        id: UUID, atWordIndex boundary: Int, firstText: String? = nil, secondText: String? = nil
    ) throws {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { throw SubtitleEditingError.cueNotFound }
        let cue = cues[index]
        guard boundary > 0, boundary < cue.wordIDs.count, cue.manualSourceRanges == nil else {
            throw SubtitleEditingError.invalidSplit
        }
        let lookup = Dictionary(words.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        let firstIDs = Array(cue.wordIDs[..<boundary])
        let secondIDs = Array(cue.wordIDs[boundary...])
        let first = SubtitleCue(
            id: cue.id, wordIDs: firstIDs,
            text: SubtitleTextFormatter.format(firstText ?? SubtitleTextFormatter.joinUnits(firstIDs.compactMap { lookup[$0] })),
            isManuallyEdited: true
        )
        let second = SubtitleCue(
            wordIDs: secondIDs,
            text: SubtitleTextFormatter.format(secondText ?? SubtitleTextFormatter.joinUnits(secondIDs.compactMap { lookup[$0] })),
            isManuallyEdited: true
        )
        cues.replaceSubrange(index...index, with: [first, second])
    }

    public mutating func mergeCues(firstID: UUID, secondID: UUID) throws {
        guard let first = cues.firstIndex(where: { $0.id == firstID }),
              let second = cues.firstIndex(where: { $0.id == secondID }) else {
            throw SubtitleEditingError.cueNotFound
        }
        guard second == first + 1 else { throw SubtitleEditingError.nonAdjacentCues }
        let a = cues[first], b = cues[second]
        let lookup = Dictionary(words.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let manual: [SubtitleTimeRange]?
        if a.manualSourceRanges != nil || b.manualSourceRanges != nil {
            manual = (a.manualSourceRanges ?? a.wordIDs.flatMap { lookup[$0]?.sourceRanges ?? [] })
                + (b.manualSourceRanges ?? b.wordIDs.flatMap { lookup[$0]?.sourceRanges ?? [] })
        } else { manual = nil }
        cues.replaceSubrange(first...second, with: [SubtitleCue(
            id: a.id, wordIDs: a.wordIDs + b.wordIDs,
            text: SubtitleTextFormatter.joinUnits([a.text, b.text]), manualSourceRanges: manual,
            isManuallyEdited: true
        )])
    }

    /// A human split may use a free playhead boundary, even inside the smallest
    /// ASR unit. Both texts are explicit user input; no character timing is
    /// inferred. Stable unit ownership is assigned once, by its midpoint.
    public mutating func splitCue(
        id: UUID, atOutputTime boundary: TimeInterval, firstText: String, secondText: String,
        timeline: ProjectTimeline, sourceDuration: TimeInterval
    ) throws {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { throw SubtitleEditingError.cueNotFound }
        let resolved = try resolvedCues(timeline: timeline, sourceDuration: sourceDuration)
            .filter { $0.cueID == id }
        guard resolved.count == 1, let interval = resolved.first,
              boundary.isFinite, boundary > interval.startTime, boundary < interval.endTime,
              !SubtitleTextFormatter.format(firstText).isEmpty,
              !SubtitleTextFormatter.format(secondText).isEmpty else { throw SubtitleEditingError.invalidSplit }
        let firstRanges = try Self.sourceRanges(
            for: .init(start: interval.startTime, end: boundary), timeline: timeline, sourceDuration: sourceDuration
        )
        let secondRanges = try Self.sourceRanges(
            for: .init(start: boundary, end: interval.endTime), timeline: timeline, sourceDuration: sourceDuration
        )
        let map = try TimelineMap(sourceSequence: timeline.sourceSequence, fullSourceDuration: sourceDuration)
        let cue = cues[index]
        let lookup = Dictionary(words.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let firstIDs = cue.wordIDs.filter { wordID in
            guard let word = lookup[wordID] else { return false }
            let points = word.sourceRanges.compactMap { map.outputTime(forSourceTime: ($0.start + $0.end) / 2) }
            return !points.isEmpty && points.reduce(0, +) / Double(points.count) < boundary
        }
        let firstSet = Set(firstIDs)
        cues.replaceSubrange(index...index, with: [
            SubtitleCue(id: cue.id, wordIDs: firstIDs, text: SubtitleTextFormatter.format(firstText),
                        manualSourceRanges: firstRanges, isManuallyEdited: true),
            SubtitleCue(wordIDs: cue.wordIDs.filter { !firstSet.contains($0) }, text: SubtitleTextFormatter.format(secondText),
                        manualSourceRanges: secondRanges, isManuallyEdited: true),
        ])
    }

    /// Humans can author free boundaries, then those output times are converted
    /// back to source clock. AI correction never calls this method.
    public mutating func updateCueTiming(
        id: UUID, outputTimeRange: SubtitleTimeRange,
        timeline: ProjectTimeline, sourceDuration: TimeInterval
    ) throws {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { throw SubtitleEditingError.cueNotFound }
        let map = try TimelineMap(sourceSequence: timeline.sourceSequence, fullSourceDuration: sourceDuration)
        guard outputTimeRange.isValid, outputTimeRange.end <= map.outputDuration + 0.000_01 else {
            throw SubtitleEditingError.invalidTimeRange
        }
        let ranges = try Self.sourceRanges(for: outputTimeRange, timeline: timeline, sourceDuration: sourceDuration)
        guard !ranges.isEmpty else { throw SubtitleEditingError.invalidTimeRange }
        let others = try resolvedCues(timeline: timeline, sourceDuration: sourceDuration).filter { $0.cueID != id }
        guard !others.contains(where: {
            min($0.endTime, outputTimeRange.end) - max($0.startTime, outputTimeRange.start) > 0.000_01
        }) else { throw SubtitleEditingError.overlappingTiming }
        cues[index].manualSourceRanges = ranges
        cues[index].isManuallyEdited = true
    }

    public func validate() throws {
        guard style.backgroundOpacity.isFinite, (0...1).contains(style.backgroundOpacity),
              style.fontSize.isFinite, (18...96).contains(style.fontSize),
              style.bottomInset.isFinite, (0...0.4).contains(style.bottomInset) else {
            throw SubtitleEditingError.invalidDocument(reason: "字号、颜色透明度或底部间距超出范围。")
        }
        var wordIDs = Set<UUID>()
        for word in words {
            guard wordIDs.insert(word.id).inserted, !word.sourceRanges.isEmpty,
                  word.sourceRanges.allSatisfy(\.isValid), word.text.count <= 8_192 else {
                throw SubtitleEditingError.invalidDocument(reason: "字词 ID 或原始时间范围无效。")
            }
            let sorted = word.sourceRanges.sorted { $0.start < $1.start }
            guard zip(sorted, sorted.dropFirst()).allSatisfy({ $0.end <= $1.start + 0.000_01 }) else {
                throw SubtitleEditingError.invalidDocument(reason: "同一字词重复使用源音频。")
            }
        }
        var cueIDs = Set<UUID>()
        var usedWords = Set<UUID>()
        for cue in cues {
            guard cueIDs.insert(cue.id).inserted,
                  cue.wordIDs.allSatisfy({ wordIDs.contains($0) && usedWords.insert($0).inserted }),
                  !cue.wordIDs.isEmpty || cue.manualSourceRanges != nil,
                  cue.text.count <= 8_192,
                  cue.manualSourceRanges.map({ !$0.isEmpty && $0.allSatisfy(\.isValid) }) ?? true else {
                throw SubtitleEditingError.invalidDocument(reason: "字幕 ID、字词引用或人工时间范围无效。")
            }
            if let ranges = cue.manualSourceRanges {
                let sorted = ranges.sorted { $0.start < $1.start }
                guard zip(sorted, sorted.dropFirst()).allSatisfy({ $0.end <= $1.start + 0.000_01 }) else {
                    throw SubtitleEditingError.invalidDocument(reason: "人工字幕重复使用源音频。")
                }
            }
        }
    }
}
