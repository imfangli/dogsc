import Foundation

public struct ScriptMatch: Sendable {
    public let sentenceRange: NSRange?
    public let matchedRange: NSRange?
    public let isTracking: Bool

    public init(sentenceRange: NSRange?, matchedRange: NSRange?, isTracking: Bool) {
        self.sentenceRange = sentenceRange
        self.matchedRange = matchedRange
        self.isTracking = isTracking
    }
}

/// Matches an ASR snapshot, rather than appending each revision of a partial.
/// It intentionally waits when text alone cannot distinguish repeated passages.
public struct ScriptFollower: Sendable {
    private let index: ScriptIndex
    private var latestRevision: UInt64?
    private var latestText = ""
    private var latestIsFinal = false
    private var latestTime: TimeInterval = -.infinity
    private var lastLocalTime: TimeInterval = -.infinity
    private var lastGlobalTime: TimeInterval = -.infinity
    private var stableEnd: Int?
    private var pendingJump: Alignment?
    private var lastResult = ScriptMatch(sentenceRange: nil, matchedRange: nil, isTracking: false)

    public init(index: ScriptIndex) { self.index = index }

    public mutating func reset() {
        latestRevision = nil
        latestText = ""
        latestIsFinal = false
        latestTime = -.infinity
        lastLocalTime = -.infinity
        lastGlobalTime = -.infinity
        stableEnd = nil
        pendingJump = nil
        lastResult = ScriptMatch(sentenceRange: nil, matchedRange: nil, isTracking: false)
    }

    public mutating func anchor(atUTF16Offset offset: Int) {
        guard let position = index.unitPosition(atUTF16Offset: offset) else { reset(); return }
        stableEnd = position + 1
        pendingJump = nil
        lastLocalTime = -.infinity
        lastGlobalTime = -.infinity
        let range = index.units[position].range
        lastResult = ScriptMatch(sentenceRange: index.sentenceRange(atUTF16Offset: range.location),
            matchedRange: range, isTracking: false)
    }

    /// The caller may retry the latest identical snapshot at a later processing
    /// time after coalescing a batch. Retrying never creates additional speech
    /// evidence; confirmation still requires the matched position to advance.
    public mutating func update(text: String, isFinal: Bool, revision: UInt64, timestamp: TimeInterval) -> ScriptMatch {
        if let latestRevision {
            if revision < latestRevision { return lastResult }
            if revision == latestRevision, text != latestText || isFinal != latestIsFinal { return lastResult }
        }
        if latestRevision != revision {
            latestRevision = revision
            latestText = text
            latestIsFinal = isFinal
        }
        let time = timestamp.isFinite ? max(timestamp, latestTime) : (latestTime.isFinite ? latestTime : 0)
        latestTime = time
        // Final results confirm without additional text once a search is due,
        // but share the same CPU limits. The coalescer retries the latest
        // identical snapshot if it arrives before its processing slot.
        guard time - lastLocalTime >= 0.125 else { return lastResult }
        lastLocalTime = time
        let normalized = ScriptNormalizer.units(in: String(text.suffix(512)))
        let query = Array(normalized.suffix(48).map { index.vocabulary[$0.value] ?? 0 })
        guard query.count >= 8, Set(query.filter { $0 != 0 }).count >= 3 else {
            pendingJump = nil
            return waiting()
        }
        if query.count < 12 { pendingJump = nil }

        let local = stableEnd.flatMap { localMatch(query: query, near: $0) }
        var global: Alignment?
        if query.count >= 12, time - lastGlobalTime >= 0.5 {
            lastGlobalTime = time
            global = globalMatch(query: query)
        }

        if let global {
            let distant = stableEnd == nil || abs(global.end - stableEnd!) > 64
            let stronger = local == nil || global.evidence >= local!.evidence + 4
                || global.similarity >= local!.similarity + 0.12
            if distant && stronger {
                if isFinal || confirmsPendingJump(global) {
                    pendingJump = nil
                    return accept(global)
                }
                // Keep the first reliable location as the evidence baseline.
                // Apple often extends a partial one character at a time; moving
                // this baseline on every revision would never accumulate four
                // additional units and would prevent initial locking forever.
                if !continuesPendingJump(global) { pendingJump = global }
                return waiting()
            }
            if local == nil {
                // A nearby restart is also allowed. With a known anchor it
                // does not need a second utterance to return to the same line.
                pendingJump = nil
                return accept(global)
            }
        }
        if let local {
            pendingJump = nil
            return accept(local)
        }
        // Retain a pending jump only while waiting for the next scheduled
        // global search. A completed, inconclusive search invalidates it.
        if time == lastGlobalTime { pendingJump = nil }
        return waiting()
    }

    private mutating func waiting() -> ScriptMatch {
        lastResult = ScriptMatch(sentenceRange: lastResult.sentenceRange,
            matchedRange: lastResult.matchedRange, isTracking: false)
        return lastResult
    }

    private mutating func accept(_ alignment: Alignment) -> ScriptMatch {
        guard let range = index.originalRange(from: alignment.start, to: alignment.end) else { return waiting() }
        stableEnd = alignment.end
        lastResult = ScriptMatch(sentenceRange: index.sentenceRange(atUTF16Offset: NSMaxRange(range) - 1),
            matchedRange: range, isTracking: true)
        return lastResult
    }

    private func confirmsPendingJump(_ candidate: Alignment) -> Bool {
        guard let pendingJump else { return false }
        return continuesPendingJump(candidate) && candidate.end - pendingJump.end >= 4
    }

    private func continuesPendingJump(_ candidate: Alignment) -> Bool {
        guard let pendingJump else { return false }
        let overlap = max(0, min(candidate.end, pendingJump.end) - max(candidate.start, pendingJump.start))
        return overlap >= 8 && candidate.end >= pendingJump.end
            && candidate.evidence >= pendingJump.evidence
    }

    private func suffixLengths(count: Int, minimum: Int) -> [Int] {
        Array(Set([min(count, 48), 32, 20, 12, 8].filter { $0 >= minimum && $0 <= count })).sorted(by: >)
    }

    private func localMatch(query: [Int], near position: Int) -> Alignment? {
        let window = max(0, position - 96)..<min(index.identifiers.count, position + 192)
        guard !window.isEmpty else { return nil }
        for length in suffixLengths(count: query.count, minimum: 8) {
            let suffix = Array(query.suffix(length))
            let matches = distinctLocations(align(suffix, in: window).filter {
                $0.similarity >= 0.75 && abs($0.end - position) <= 64
            })
            guard let bestScore = matches.map(\.similarity).max() else { continue }
            // Once anchored, short repeated words stay near the current place.
            // Unique later context still wins when its score is better.
            return matches.filter { $0.similarity >= bestScore - 0.08 }.min {
                let lhsDistance = abs($0.end - position)
                let rhsDistance = abs($1.end - position)
                return lhsDistance == rhsDistance ? $0.similarity > $1.similarity : lhsDistance < rhsDistance
            }
        }
        return nil
    }

    private func globalMatch(query: [Int]) -> Alignment? {
        for length in suffixLengths(count: query.count, minimum: 12) {
            let suffix = Array(query.suffix(length))
            var candidates: [Alignment] = []
            for window in candidateWindows(for: suffix) { candidates += align(suffix, in: window) }
            let locations = distinctLocations(candidates.filter { $0.similarity >= 0.73 })
            guard let best = locations.first, best.similarity >= 0.85 else { continue }
            if locations.count > 1, best.similarity - locations[1].similarity < 0.12 { continue }
            return best
        }
        return nil
    }

    private func candidateWindows(for query: [Int]) -> [Range<Int>] {
        guard query.count >= 3 else { return [] }
        var grams: [(position: Int, postings: [Int])] = []
        for position in 0..<(query.count - 2) {
            let gram = ScriptTrigram(query, at: position)
            if let postings = index.trigrams[gram], postings.count <= 512 {
                grams.append((position, postings))
            }
        }
        grams.sort {
            $0.postings.count == $1.postings.count ? $0.position > $1.position : $0.postings.count < $1.postings.count
        }
        var votes: [Int: Int] = [:]
        for gram in grams.prefix(8) {
            for position in gram.postings { votes[(position - gram.position) / 4, default: 0] += 1 }
        }
        return votes.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.prefix(16).map { bucket, _ in
            let start = bucket * 4
            let lower = max(0, start - 12)
            let upper = min(index.identifiers.count, max(lower, start + query.count + 16))
            return lower..<upper
        }.filter { !$0.isEmpty }
    }

    private struct Alignment: Sendable {
        let start: Int
        let end: Int
        let evidence: Int
        let similarity: Double
    }

    /// Semi-global edit distance: the speech must align in full, while an
    /// arbitrary leading portion of the script window is free to skip.
    private func align(_ query: [Int], in window: Range<Int>) -> [Alignment] {
        let width = window.count
        guard width > 0 else { return [] }
        var previous = [Int](repeating: 0, count: width + 1)
        var current = previous
        var previousStarts = Array(0...width)
        var currentStarts = previousStarts
        for row in query.indices {
            current[0] = row + 1
            currentStarts[0] = 0
            for column in 1...width {
                let equal = query[row] != 0 && query[row] == index.identifiers[window.lowerBound + column - 1]
                let diagonal = previous[column - 1] + (equal ? 0 : 1)
                let deletion = previous[column] + 1
                let insertion = current[column - 1] + 1
                if diagonal <= deletion && diagonal <= insertion {
                    current[column] = diagonal
                    currentStarts[column] = previousStarts[column - 1]
                } else if deletion <= insertion {
                    current[column] = deletion
                    currentStarts[column] = previousStarts[column]
                } else {
                    current[column] = insertion
                    currentStarts[column] = currentStarts[column - 1]
                }
            }
            swap(&previous, &current)
            swap(&previousStarts, &currentStarts)
        }
        var result: [Alignment] = []
        for end in 1...width {
            let start = previousStarts[end]
            guard end > start else { continue }
            let score = 1 - Double(previous[end]) / Double(max(query.count, end - start))
            if score >= 0.73 {
                result.append(Alignment(start: window.lowerBound + start, end: window.lowerBound + end,
                    evidence: query.count, similarity: score))
            }
        }
        return result
    }

    private func distinctLocations(_ candidates: [Alignment]) -> [Alignment] {
        let sorted = candidates.sorted {
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            if $0.evidence != $1.evidence { return $0.evidence > $1.evidence }
            return $0.end < $1.end
        }
        var result: [Alignment] = []
        for candidate in sorted {
            let duplicate = result.contains { existing in
                let overlap = max(0, min(existing.end, candidate.end) - max(existing.start, candidate.start))
                let shorter = min(existing.end - existing.start, candidate.end - candidate.start)
                return abs(existing.end - candidate.end) <= 4 || Double(overlap) >= Double(shorter) * 0.6
            }
            if !duplicate { result.append(candidate) }
        }
        return result
    }
}
