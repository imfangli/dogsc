import Foundation

/// A small, in-memory transcript assembled by audio range rather than by
/// appending every hypothesis. Revised partials replace their earlier text.
public struct SpeechTranscriptWindow: Sendable {
    private struct Segment: Sendable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
        let isFinal: Bool
    }

    private var segments: [Segment] = []
    private var latestEnd: TimeInterval = 0
    private let duration: TimeInterval

    public init(duration: TimeInterval = 8) {
        self.duration = max(duration, 1)
    }

    public var text: String { String(segments.map(\.text).joined(separator: " ").suffix(512)) }
    public var isFinal: Bool { segments.last?.isFinal ?? false }

    @discardableResult
    public mutating func update(
        text: String, start: TimeInterval, end: TimeInterval, isFinal: Bool
    ) -> Bool {
        guard start.isFinite, end.isFinite, start >= 0, end >= start else { return false }
        let cutoff = max(latestEnd, end) - duration
        guard end >= cutoff else { return false }
        let overlapping = segments.filter { Self.overlaps($0, start: start, end: end) }
        // A delayed provisional hypothesis must not replace finalized audio.
        if !isFinal, overlapping.contains(where: \.isFinal) { return false }
        let previousText = self.text
        let previousFinal = self.isFinal
        latestEnd = max(latestEnd, end)
        segments.removeAll { $0.end < cutoff || Self.overlaps($0, start: start, end: end) }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(Segment(text: text, start: start, end: end, isFinal: isFinal))
        }
        segments.sort { $0.start < $1.start }
        return self.text != previousText || self.isFinal != previousFinal
    }

    private static func overlaps(_ segment: Segment, start: TimeInterval, end: TimeInterval) -> Bool {
        abs(segment.start - start) < 0.000_01
            || (segment.start < end - 0.000_01 && start < segment.end - 0.000_01)
    }
}
