import AVFoundation
import CoreImage
import Foundation
import RecorderCore
import XCTest
@testable import DogSCApp

/// Exercises the production request builder and complete MP4 export job,
/// including frame scheduling, subtitle selection, hardware encoding and
/// decoding. Every asset is synthetic; no microphone or personal file is used.
@MainActor
final class SubtitleVideoExportTests: XCTestCase {
    func testBurnedSubtitleOnlyAppearsInsideOriginalInterval() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("screen.mp4")
        try await writeSolidVideo(to: source)
        let project = captionProject()
        let output = folder.appendingPathComponent("subtitles-full.mp4")
        try await export(project: project, source: source, output: output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: EditorSubtitleExport.outputURL(for: output).path),
            "Exporting subtitles alongside video is opt-in")
        let decoded = try await readVideo(output, frameIndices: [3, 6, 12, 18, 24])
        XCTAssertEqual(decoded.count, 30)
        XCTAssertEqual(decoded.duration, 1, accuracy: 1.0 / 30)
        XCTAssertEqual(decoded.firstPTS, 0, accuracy: 0.000_01)
        XCTAssertEqual(decoded.lastPTS, 29.0 / 30, accuracy: 0.000_01)
        let before = try XCTUnwrap(decoded.frames[3])
        let during = try XCTUnwrap(decoded.frames[12])
        let after = try XCTUnwrap(decoded.frames[24])
        XCTAssertEqual(before.whiteGlyphPixels, 0)
        XCTAssertEqual(after.whiteGlyphPixels, 0)
        XCTAssertGreaterThan(during.whiteGlyphPixels, 50)
        XCTAssertGreaterThan(during.translucentBackdropPixels, 100)
        XCTAssertGreaterThan(try XCTUnwrap(decoded.frames[6]).whiteGlyphPixels, 50,
            "Caption start is inclusive at exactly 0.2 seconds")
        XCTAssertEqual(try XCTUnwrap(decoded.frames[18]).whiteGlyphPixels, 0,
            "Caption end is exclusive at exactly 0.6 seconds")
        XCTAssertEqual(before.translucentBackdropPixels, 0)
        XCTAssertEqual(after.translucentBackdropPixels, 0)
        XCTAssertEqual(during.topThirdWhitePixels, 0, "Captions must stay at the final canvas bottom")
        try retainArtifact(output, name: "subtitles-full.mp4")
    }

    func testSelectedRangeRebasesCaptionAndDisabledProjectExportsCleanVideo() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("screen.mp4")
        try await writeSolidVideo(to: source)
        var project = captionProject()
        let selectedOutput = folder.appendingPathComponent("subtitles-selected-range.mp4")
        let selection = try XCTUnwrap(MediaTimeRange(start: 0.3, duration: 0.5))
        try await export(project: project, source: source, output: selectedOutput, range: selection,
            exportsSubtitles: true)
        XCTAssertEqual(try String(contentsOf: EditorSubtitleExport.outputURL(for: selectedOutput), encoding: .utf8),
            "1\n00:00:00,000 --> 00:00:00,300\n字幕测试\n")
        let selected = try await readVideo(selectedOutput, frameIndices: [3, 12])
        XCTAssertEqual(selected.count, 15)
        XCTAssertEqual(selected.duration, 0.5, accuracy: 1.0 / 30)
        XCTAssertEqual(selected.firstPTS, 0, accuracy: 0.000_01)
        XCTAssertGreaterThan(try XCTUnwrap(selected.frames[3]).whiteGlyphPixels, 50,
            "Output 0.1 seconds is project 0.4 seconds, inside the caption")
        XCTAssertEqual(try XCTUnwrap(selected.frames[12]).whiteGlyphPixels, 0,
            "Output 0.4 seconds is project 0.7 seconds, after the caption")
        project.subtitles.enabled = false
        let disabledOutput = folder.appendingPathComponent("subtitles-disabled.mp4")
        try await export(project: project, source: source, output: disabledOutput, exportsSubtitles: true)
        XCTAssertEqual(try String(contentsOf: EditorSubtitleExport.outputURL(for: disabledOutput), encoding: .utf8),
            "1\n00:00:00,200 --> 00:00:00,600\n字幕测试\n")
        let disabled = try await readVideo(disabledOutput, frameIndices: [12])
        XCTAssertEqual(disabled.count, 30)
        let clean = try XCTUnwrap(disabled.frames[12])
        XCTAssertEqual(clean.whiteGlyphPixels, 0)
        XCTAssertEqual(clean.translucentBackdropPixels, 0)
        try retainArtifact(selectedOutput, name: "subtitles-selected-range.mp4")
        try retainArtifact(disabledOutput, name: "subtitles-disabled.mp4")
    }

    func testCompanionCannotOverwriteSourceThroughSymlink() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("screen.mp4")
        try await writeSolidVideo(to: source)
        let project = captionProject()
        let session = EditorSessionID()
        let mediaRequest = EditorMediaRequest(editorSessionID: session,
            sourceURL: source, cameraURL: nil, microphoneURL: nil,
            sourceSequence: project.timeline.sourceSequence, mediaManifest: project.media, pointerEvents: [])
        let payload = try await TimelinePreviewCompositionLoader.prepare(request: mediaRequest)
        let prepared = EditorPreparedMedia(generation: 1, request: mediaRequest, payload: payload)
        let output = folder.appendingPathComponent("output.mp4")
        let subtitleURL = EditorSubtitleExport.outputURL(for: output)
        try FileManager.default.createSymbolicLink(at: subtitleURL, withDestinationURL: source)
        XCTAssertThrowsError(try EditorExportRequestBuilder.make(editorSessionID: session,
            mediaGeneration: 1, project: project, preparedMedia: prepared,
            wallpaperURL: nil, outputURL: output, exportsSubtitles: true)) { error in
            XCTAssertEqual(error as? EditorExportRequestError, .outputCollidesWithInput(subtitleURL.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    private func captionProject() -> RecorderProject {
        var project = RecorderProject(title: "Synthetic subtitle export test",
            capture: CaptureConfiguration(recordsSystemAudio: false),
            canvas: CanvasStyle(padding: 0, cornerRadius: 0, shadowStrength: 0, insetOpacity: 0),
            exportSettings: ExportSettings(frameRate: .fps30, resolution: .source),
            media: ProjectMediaManifest(screen: ProjectMediaReference(relativePath: "screen.mp4")))
        project.audio.isSystemMuted = true
        project.audio.isMicrophoneMuted = true
        let word = SubtitleWord(text: "字幕测试", sourceRanges: [.init(start: 0.2, end: 0.6)])
        project.subtitles = SubtitleDocument(enabled: true,
            style: SubtitleStyle(backgroundOpacity: 0.62, fontSize: 96, bottomInset: 0.065),
            words: [word], cues: [.init(wordIDs: [word.id], text: word.text)])
        return project
    }

    private func export(project: RecorderProject, source: URL, output: URL,
        range: MediaTimeRange? = nil, exportsSubtitles: Bool = false) async throws {
        let session = EditorSessionID()
        let mediaRequest = EditorMediaRequest(editorSessionID: session,
            sourceURL: source, cameraURL: nil, microphoneURL: nil,
            sourceSequence: project.timeline.sourceSequence, mediaManifest: project.media, pointerEvents: [])
        let payload = try await TimelinePreviewCompositionLoader.prepare(request: mediaRequest)
        let prepared = EditorPreparedMedia(generation: 1, request: mediaRequest, payload: payload)
        let request = try EditorExportRequestBuilder.make(editorSessionID: session,
            mediaGeneration: 1, project: project, preparedMedia: prepared,
            wallpaperURL: nil, outputURL: output, exportsSubtitles: exportsSubtitles, outputRange: range)
        if exportsSubtitles {
            let subtitleURL = EditorSubtitleExport.outputURL(for: output).standardizedFileURL
            XCTAssertEqual(request.subtitleExport?.outputURL, subtitleURL)
            XCTAssertEqual(request.subtitleExport?.contents, try EditorSubtitleExport.contents(
                project: project, sourceDuration: request.mediaPlan.timelineMap.fullSourceDuration,
                outputDuration: request.mediaPlan.outputDuration, outputRange: range))
            var withoutSubtitles = project
            withoutSubtitles.subtitles = SubtitleDocument()
            XCTAssertThrowsError(try EditorExportRequestBuilder.make(editorSessionID: session,
                mediaGeneration: 1, project: withoutSubtitles, preparedMedia: prepared,
                wallpaperURL: nil, outputURL: output, exportsSubtitles: true, outputRange: range)) { error in
                XCTAssertEqual(error as? EditorExportRequestError, .noSubtitlesToExport)
            }
        } else {
            XCTAssertNil(request.subtitleExport)
        }
        let exporter = VideoExporter()
        let defaults = UserDefaults.standard
        let soundKey = AppPreferences.exportCompletionSoundEnabledKey
        let previousSound = defaults.object(forKey: soundKey)
        defaults.set(false, forKey: soundKey)
        defer {
            if let previousSound { defaults.set(previousSound, forKey: soundKey) }
            else { defaults.removeObject(forKey: soundKey) }
        }
        exporter.export(request: request)
        for _ in 0..<1_000 {
            if !exporter.isExporting { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        if exporter.isExporting {
            exporter.cancelExport()
            for _ in 0..<100 {
                if !exporter.isExporting { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("Synthetic video export exceeded its 20-second deadline")
            throw SubtitleExportTestError.timeout
        }
        XCTAssertNil(exporter.errorMessage)
        XCTAssertEqual(exporter.lastExportURL, output.standardizedFileURL)
        XCTAssertEqual(exporter.lastSubtitleExportURL, request.subtitleExport?.outputURL)
        XCTAssertEqual(exporter.exportProgress, 1)
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw SubtitleExportTestError.missingOutput
        }
        XCTAssertEqual(FileManager.default.fileExists(atPath: EditorSubtitleExport.outputURL(for: output).path),
            exportsSubtitles)
    }

    private func writeSolidVideo(to url: URL) async throws {
        let width = 640, height = 360
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000,
                AVVideoAllowFrameReorderingKey: false]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        guard writer.canAdd(input) else { throw SubtitleExportTestError.fixtureFailure }
        writer.add(input)
        guard writer.startWriting() else { throw SubtitleExportTestError.fixtureFailure }
        writer.startSession(atSourceTime: .zero)
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { throw SubtitleExportTestError.fixtureFailure }
        CVPixelBufferLockBaseAddress(buffer, [])
        guard let address = CVPixelBufferGetBaseAddress(buffer) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            throw SubtitleExportTestError.fixtureFailure
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<height {
            let bytes = address.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                bytes[x * 4] = 40; bytes[x * 4 + 1] = 40
                bytes[x * 4 + 2] = 200; bytes[x * 4 + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for frame in 0..<30 {
            var attempts = 0
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, attempts < 1_000 else { throw SubtitleExportTestError.fixtureFailure }
                try await Task.sleep(for: .milliseconds(2))
                attempts += 1
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30))
            else { throw SubtitleExportTestError.fixtureFailure }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { throw SubtitleExportTestError.fixtureFailure }
    }

    private struct DecodedVideo {
        let count: Int
        let duration: Double
        let firstPTS: Double
        let lastPTS: Double
        let frames: [Int: FramePixels]
    }
    private struct FramePixels {
        let whiteGlyphPixels: Int
        let translucentBackdropPixels: Int
        let topThirdWhitePixels: Int
    }

    private func readVideo(_ url: URL, frameIndices: Set<Int>) async throws -> DecodedVideo {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        guard reader.canAdd(output) else { throw SubtitleExportTestError.decodeFailure }
        reader.add(output)
        guard reader.startReading() else { throw SubtitleExportTestError.decodeFailure }
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = CIContext(options: [.workingColorSpace: colorSpace, .outputColorSpace: colorSpace])
        var count = 0, firstPTS = 0.0, lastPTS = 0.0
        var frames: [Int: FramePixels] = [:]
        while let sample = output.copyNextSampleBuffer() {
            if count == 0 { firstPTS = sample.presentationTimeStamp.seconds }
            lastPTS = sample.presentationTimeStamp.seconds
            if frameIndices.contains(count) {
                let buffer = try XCTUnwrap(sample.imageBuffer)
                let image = CIImage(cvPixelBuffer: buffer)
                let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
                let third = max(height / 3, 1)
                func pixels(at y: Int) -> (white: Int, backdrop: Int) {
                    var bytes = [UInt8](repeating: 0, count: width * third * 4)
                    context.render(image, toBitmap: &bytes, rowBytes: width * 4,
                        bounds: CGRect(x: 0, y: y, width: width, height: third),
                        format: .RGBA8, colorSpace: colorSpace)
                    var white = 0, backdrop = 0
                    for index in Swift.stride(from: 0, to: bytes.count, by: 4) {
                        let r = bytes[index], g = bytes[index + 1], b = bytes[index + 2]
                        if r > 220 && g > 220 && b > 220 { white += 1 }
                        if (25...170).contains(r) && g < 55 && b < 55 { backdrop += 1 }
                    }
                    return (white, backdrop)
                }
                let bottom = pixels(at: 0), top = pixels(at: height - third)
                frames[count] = FramePixels(whiteGlyphPixels: bottom.white,
                    translucentBackdropPixels: bottom.backdrop, topThirdWhitePixels: top.white)
            }
            count += 1
        }
        guard reader.status == .completed else { throw SubtitleExportTestError.decodeFailure }
        return DecodedVideo(count: count, duration: duration, firstPTS: firstPTS,
            lastPTS: lastPTS, frames: frames)
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DogSC-Subtitle-Export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func retainArtifact(_ url: URL, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["DOGSC_SUBTITLE_EXPORT_ARTIFACTS"] else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: url, to: destination)
    }
}

private enum SubtitleExportTestError: Error {
    case fixtureFailure, decodeFailure, timeout, missingOutput
}
