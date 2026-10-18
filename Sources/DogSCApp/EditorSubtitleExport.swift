import Foundation
import RecorderCore

/// Subtitle timing uses the same frozen project clock as the media export.
/// A selected export clips display intervals, then rebases them to file time.
enum EditorSubtitleExport {
    static func contents(
        project: RecorderProject,
        sourceDuration: Double,
        outputDuration: Double,
        outputRange: MediaTimeRange? = nil
    ) throws -> String {
        guard outputDuration.isFinite, outputDuration > 0,
              let fullRange = MediaTimeRange(start: 0, duration: outputDuration) else {
            throw EditorExportRequestError.invalidOutputRange
        }
        let range = outputRange ?? fullRange
        let tolerance = max(outputDuration.ulp * 8, 0.000_001)
        guard range.start >= -tolerance, range.end <= outputDuration + tolerance else {
            throw EditorExportRequestError.invalidOutputRange
        }
        let rangeStart = max(range.start, 0)
        let rangeEnd = min(range.end, outputDuration)
        // Resolve the whole project before clipping. Rebuilding a selected
        // timeline would invalidate words cropped at its edges and discard
        // their corrected text, unlike the video renderer's display clipping.
        let resolved = try project.subtitles.resolvedCues(
            timeline: project.timeline, sourceDuration: sourceDuration)
        let clipped = resolved.compactMap { cue -> ResolvedSubtitleCue? in
            let start = max(cue.startTime, rangeStart)
            let end = min(cue.endTime, rangeEnd)
            guard end > start else { return nil }
            var result = cue
            result.startTime = start - rangeStart
            result.endTime = end - rangeStart
            return result
        }
        return SubtitleSRTExporter.export(clipped)
    }

    static func outputURL(for mediaURL: URL) -> URL {
        mediaURL.deletingPathExtension().appendingPathExtension("srt")
    }
}
