import Foundation
import RecorderCore

/// Coalesces bursts of Apple partials without dropping their final snapshot.
/// Matching stays off MainActor and retries the latest snapshot once the
/// full-script cadence permits it. Repeated text never supplies new evidence.
actor MemoScriptMatcher {
    private var follower: ScriptFollower
    private var latest: MemoSpeechText?
    private var burstBaseline: MemoSpeechText?
    private var hasSeededBurst = false
    private var receivedAt: TimeInterval = 0
    private var inputEnded = false
    private var publishedRevision: UInt64?
    private var publishedMatch: ScriptMatch?

    init(text: String, anchor: Int?) {
        follower = ScriptFollower(index: ScriptIndex(text: text))
        if let anchor { follower.anchor(atUTF16Offset: anchor) }
    }

    func matches(from input: AsyncThrowingStream<MemoSpeechText, any Error>) -> AsyncThrowingStream<ScriptMatch, any Error> {
        let output = AsyncThrowingStream<ScriptMatch, any Error>.makeStream(bufferingPolicy: .bufferingNewest(2))
        let task = Task {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        do {
                            for try await value in input {
                                try Task.checkCancellation()
                                await self.receive(value)
                            }
                            await self.endInput()
                        } catch {
                            await self.endInput()
                            throw error
                        }
                    }
                    group.addTask {
                        while !Task.isCancelled {
                            guard await self.tick(output.continuation) else { return }
                            try await Task.sleep(for: .milliseconds(125))
                        }
                    }
                    try await group.waitForAll()
                }
                output.continuation.finish()
            } catch {
                output.continuation.finish(throwing: error)
            }
        }
        output.continuation.onTermination = { _ in task.cancel() }
        return output.stream
    }

    private func receive(_ value: MemoSpeechText) {
        guard latest == nil || value.revision > latest!.revision else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if latest == nil || now - receivedAt > 0.75 {
            hasSeededBurst = false
            burstBaseline = nil
        }
        if !hasSeededBurst, ScriptIndex.effectiveUnitCount(in: String(value.text.suffix(512))) >= 12 {
            // Retain two real observations when a whole partial burst arrives
            // between ticks; reprocessing one snapshot cannot confirm a jump.
            burstBaseline = value
            hasSeededBurst = true
        }
        latest = value
        receivedAt = now
    }

    private func endInput() { inputEnded = true }

    private func tick(_ output: AsyncThrowingStream<ScriptMatch, any Error>.Continuation) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard let latest else { return !inputEnded }
        // One global interval plus a local tick is enough to process the tail
        // of a burst, including when the speaker has already gone silent.
        guard now - receivedAt <= 0.75 else { return !inputEnded }
        let value = burstBaseline ?? latest
        burstBaseline = nil
        let match = follower.update(text: value.text, isFinal: value.isFinal,
            revision: value.revision, timestamp: now)
        let changed = publishedRevision != value.revision
            || publishedMatch?.isTracking != match.isTracking
            || publishedMatch?.matchedRange != match.matchedRange
            || publishedMatch?.sentenceRange != match.sentenceRange
        if changed {
            output.yield(match)
            publishedRevision = value.revision
            publishedMatch = match
        }
        return true
    }
}
