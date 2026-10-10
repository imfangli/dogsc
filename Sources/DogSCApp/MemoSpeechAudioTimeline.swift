import AVFoundation
import CoreMedia

/// Speech consumes the converted frames, whose integral lengths need not
/// exactly match the capture packet duration. Keep its clock on target frame
/// boundaries while retaining real gaps in the capture stream. The recording
/// writer continues to use the original sample buffers and timestamps.
struct MemoSpeechAudioTimeline {
    private var origin: CMTime?
    private var nextEndFrame: Int64 = 0
    private var timeScale: CMTimeScale?

    mutating func startTime(
        captureTime: CMTime, frameCount: AVAudioFrameCount, sampleRate: Double
    ) -> CMTime? {
        guard captureTime.isNumeric, frameCount > 0,
              sampleRate.isFinite, sampleRate > 0,
              sampleRate.rounded() == sampleRate,
              sampleRate <= Double(Int32.max) else { return nil }
        let scale = CMTimeScale(sampleRate)
        guard timeScale == nil || timeScale == scale else { return nil }
        let relative = CMTimeSubtract(captureTime, origin ?? captureTime)
        guard relative.isNumeric else { return nil }
        let aligned = CMTimeConvertScale(relative, timescale: scale, method: .roundTowardPositiveInfinity)
        guard aligned.isNumeric else { return nil }
        let start = max(aligned.value, nextEndFrame)
        let (end, overflow) = start.addingReportingOverflow(Int64(frameCount))
        guard !overflow else { return nil }
        origin = origin ?? captureTime
        timeScale = scale
        nextEndFrame = end
        return CMTime(value: start, timescale: scale)
    }
}
