import CoreImage
import XCTest
@testable import DogSCApp
@testable import RecorderCore

@MainActor
final class SubtitleRenderingTests: XCTestCase {
    func testRasterFitsTwoLinesWithoutDroppingMixedGraphemes() throws {
        let text = String(repeating: "中文 SpeechAnalyzer 👨‍👩‍👧‍👦 cafe\u{301} 字幕校对 ", count: 9)
        let scene = FrameSubtitleScene(text: text, fontSize: 44, bottomInset: 70)
        let raster = try XCTUnwrap(SharedFrameSubtitleRenderer.raster(
            scene: scene, canvasSize: CompositionSize(width: 1080, height: 1920)
        ))
        XCTAssertLessThanOrEqual(raster.lines.count, 2)
        XCTAssertEqual(visibleCharacters(raster.lines.joined()), visibleCharacters(text))
        XCTAssertLessThan(raster.fontSize, 44)
        XCTAssertLessThanOrEqual(raster.width, 1080)
        for line in raster.lines {
            XCTAssertFalse(line.hasPrefix("\u{200D}"))
            XCTAssertFalse(line.hasSuffix("\u{200D}"))
            XCTAssertFalse(line.hasPrefix("\u{301}"))
        }
    }

    func testForcedBreaksFitWithoutTruncationAndEnglishWordsWrap() throws {
        let scene = FrameSubtitleScene(
            text: "Hello SpeechAnalyzer\n这是第二行\n这是第三行", fontSize: 44, bottomInset: 60
        )
        let raster = try XCTUnwrap(SharedFrameSubtitleRenderer.raster(
            scene: scene, canvasSize: CompositionSize(width: 1080, height: 1080)
        ))
        XCTAssertLessThanOrEqual(raster.lines.count, 2)
        XCTAssertEqual(visibleCharacters(raster.lines.joined()), visibleCharacters(scene.text))
        XCTAssertTrue(raster.lines.contains(where: { $0.contains("SpeechAnalyzer") }))
    }

    func testRasterCacheAndFinalCanvasPlacementScale() throws {
        let size = CompositionSize(width: 1920, height: 1080)
        var scene = FrameSubtitleScene(text: "字幕在最终画布居中", fontSize: 44, bottomInset: 70)
        let raster = try XCTUnwrap(SharedFrameSubtitleRenderer.raster(scene: scene, canvasSize: size))
        let first = try XCTUnwrap(SharedFrameSubtitleRenderer.image(scene: scene, canvasSize: size))
        XCTAssertEqual(first.extent.midX, size.width / 2, accuracy: 0.001)
        XCTAssertEqual(first.extent.minY, 70, accuracy: 0.001)
        scene.bottomInset = 100
        let reused = try XCTUnwrap(SharedFrameSubtitleRenderer.raster(scene: scene, canvasSize: size))
        XCTAssertTrue(raster === reused, "Moving captions should not rasterize the same text again")
        let moved = try XCTUnwrap(SharedFrameSubtitleRenderer.image(scene: scene, canvasSize: size))
        XCTAssertEqual(moved.extent.minY, 100, accuracy: 0.001)
        scene.textColor = HexColor(rgb24: 0xFF0000)
        let recolored = try XCTUnwrap(SharedFrameSubtitleRenderer.raster(scene: scene, canvasSize: size))
        XCTAssertFalse(raster === recolored)
        scene.text = "新的字幕"
        XCTAssertFalse(recolored === SharedFrameSubtitleRenderer.raster(scene: scene, canvasSize: size))

        let doubled = try XCTUnwrap(SharedFrameSubtitleRenderer.image(
            scene: FrameSubtitleScene(text: "字幕在最终画布居中", fontSize: 88, bottomInset: 140),
            canvasSize: CompositionSize(width: 3840, height: 2160)
        ))
        XCTAssertEqual(doubled.extent.midX, 1920, accuracy: 0.001)
        XCTAssertEqual(doubled.extent.minY, 140, accuracy: 0.001)
        XCTAssertEqual(doubled.extent.width, first.extent.width * 2, accuracy: 2)
        XCTAssertEqual(doubled.extent.height, first.extent.height * 2, accuracy: 2)
    }

    func testSubtitleRasterKeepsTransparentBlackBackdropAndWhiteGlyphs() throws {
        let scene = FrameSubtitleScene(text: "Hello 字幕", fontSize: 44,
                                       backgroundOpacity: 0.62, bottomInset: 60)
        let raster = try XCTUnwrap(SharedFrameSubtitleRenderer.raster(
            scene: scene, canvasSize: CompositionSize(width: 1920, height: 1080)
        ))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = CIContext(options: [.workingColorSpace: colorSpace, .outputColorSpace: colorSpace])
        var bytes = [UInt8](repeating: 0, count: raster.width * raster.height * 4)
        context.render(raster.image, toBitmap: &bytes, rowBytes: raster.width * 4,
                       bounds: raster.image.extent, format: .RGBA8, colorSpace: colorSpace)
        var blackBackdrop = 0
        var whiteGlyph = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            if bytes[offset] == 0, bytes[offset + 1] == 0, bytes[offset + 2] == 0,
               (155...161).contains(bytes[offset + 3]) { blackBackdrop += 1 }
            if bytes[offset] > 235, bytes[offset + 1] > 235, bytes[offset + 2] > 235,
               bytes[offset + 3] > 245 { whiteGlyph += 1 }
        }
        XCTAssertGreaterThan(blackBackdrop, 100)
        XCTAssertGreaterThan(whiteGlyph, 100)
        XCTAssertEqual(bytes[3], 0, "The rounded backdrop's outside corner should be transparent")
    }

    func testCanonicalLayoutKeepsLineBreaksAcrossPreviewAndExportSizes() throws {
        let text = "使用 SpeechAnalyzer 生成字幕，然后让 AI 校对中文、English terms 和口播内容，最后导出清晰的视频"
        let reference = try XCTUnwrap(SharedFrameSubtitleRenderer.raster(
            scene: FrameSubtitleScene(text: text, fontSize: 44, bottomInset: 70),
            canvasSize: CompositionSize(width: 1920, height: 1080)
        ))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = CIContext(options: [.workingColorSpace: colorSpace, .outputColorSpace: colorSpace])
        for scale in [0.5, 2.0] {
            let raster = try XCTUnwrap(SharedFrameSubtitleRenderer.raster(
                scene: FrameSubtitleScene(text: text, fontSize: 44 * scale, bottomInset: 70 * scale),
                canvasSize: CompositionSize(width: 1920 * scale, height: 1080 * scale)
            ))
            XCTAssertEqual(raster.lines, reference.lines)
            XCTAssertEqual(raster.fontSize, reference.fontSize * scale, accuracy: 0.001)
            XCTAssertEqual(Double(raster.width), Double(reference.width) * scale, accuracy: 2)
            XCTAssertEqual(Double(raster.height), Double(reference.height) * scale, accuracy: 2)
            var bytes = [UInt8](repeating: 0, count: raster.width * raster.height * 4)
            context.render(raster.image, toBitmap: &bytes, rowBytes: raster.width * 4,
                           bounds: raster.image.extent, format: .RGBA8, colorSpace: colorSpace)
            let glyphXs = stride(from: 0, to: bytes.count, by: 4).compactMap { offset -> Int? in
                guard bytes[offset] > 235, bytes[offset + 1] > 235, bytes[offset + 2] > 235,
                      bytes[offset + 3] > 245 else { return nil }
                return (offset / 4) % raster.width
            }
            XCTAssertGreaterThan(glyphXs.count, 100)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(glyphXs.min()), Int(8 * scale))
            XCTAssertLessThan(try XCTUnwrap(glyphXs.max()), raster.width - Int(8 * scale),
                              "Scaled glyphs should retain both backdrop gutters without clipping")
        }
    }

    func testSceneEndExclusiveBoundaryAndPreviewRevision() throws {
        var project = captionProject()
        let before = plan(project, at: 0.999)
        let during = plan(project, at: 1)
        let end = plan(project, at: 2)
        XCTAssertNil(before.scene.subtitle)
        XCTAssertEqual(during.scene.subtitle?.text, "第一条字幕")
        XCTAssertNil(end.scene.subtitle)
        XCTAssertEqual(during.scene.layerOrder.last, .subtitles)
        XCTAssertFalse(SharedPreviewFramePipeline.canSeparateCursor(in: during))
        XCTAssertNotEqual(signature(before), signature(during))
        XCTAssertNotEqual(signature(during), signature(end))

        project.subtitles.cues[0].text = "修改后的字幕"
        let changed = plan(project, at: 1)
        XCTAssertNotEqual(signature(during), signature(changed))
        project.subtitles.style.textColor = HexColor(rgb24: 0xFF6600)
        XCTAssertNotEqual(signature(changed), signature(plan(project, at: 1)))
    }

    func testProjectionCacheReusesMappingAcrossStyleAndReferenceEdits() throws {
        let cache = FrameSubtitleCueCache()
        var document = captionProject().subtitles
        func cue(sequence: SourceSequence = .fullRecording, time: Double = 1.5) -> ResolvedSubtitleCue? {
            cache.cue(document: document, sequence: sequence, outputDuration: 4, at: time)
        }
        XCTAssertEqual(cue()?.text, "第一条字幕")
        XCTAssertEqual(cache.projectionCount, 1)
        for step in 0..<60 {
            document.style.fontSize = 18 + Double(step)
            document.style.backgroundOpacity = Double(step) / 60
            document.style.bottomInset = Double(step) / 200
            document.style.textColor = HexColor(rgb24: UInt32(step))
            document.script = "校对稿 \(step)"
            document.theme = "主题 \(step)"
            document.audioSource = .finalMix
            document.generationSignature = "signature-\(step)"
            XCTAssertEqual(cue()?.text, "第一条字幕")
        }
        XCTAssertEqual(cache.projectionCount, 1, "Visual/reference edits must not project all words again")
        document.cues[0].text = "修改后的字幕"
        XCTAssertEqual(cue()?.text, "修改后的字幕")
        XCTAssertEqual(cache.projectionCount, 2)
        document.words[0].sourceRanges = [SubtitleTimeRange(start: 1, end: 3)]
        XCTAssertEqual(cue()?.endTime, 3)
        XCTAssertEqual(cache.projectionCount, 3)
        let retimed = SourceSequence.edited([
            RecordingSegment(sourceStart: 0, sourceDuration: 4, playbackRate: 2),
        ])
        XCTAssertEqual(cue(sequence: retimed, time: 0.75)?.endTime, 1.5)
        XCTAssertEqual(cache.projectionCount, 4)
    }

    func testCommonCompositorPlacesSubtitleAboveCamera() throws {
        var rendered = plan(captionProject(), at: 1.5)
        let size = rendered.scene.canvasSize
        rendered.scene.camera = FrameCameraScene(
            rect: CompositionRect(x: 0, y: 0, width: size.width, height: size.height),
            contentFill: nil, cornerRadius: 0, borderWidth: 0,
            shadow: nil, opacity: 1, isMirrored: false
        )
        rendered.scene.layerOrder = [.background, .camera, .subtitles]
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        let output = try XCTUnwrap(SharedFrameCompositor.composite(
            rendered, resources: SharedFrameRenderResources(screen: red, camera: red), extent: red.extent
        ))
        let subtitle = try XCTUnwrap(rendered.scene.subtitle)
        let raster = try XCTUnwrap(SharedFrameSubtitleRenderer.raster(scene: subtitle, canvasSize: size))
        let profile = try CoreImageFrameColorProfile(contract: .sdrDesktop)
        let context = profile.makeContext(cacheIntermediates: false)
        func pixel(x: Double, y: Double) -> [UInt8] {
            var result = [UInt8](repeating: 0, count: 4)
            context.render(output, toBitmap: &result, rowBytes: 4,
                           bounds: CGRect(x: x, y: y, width: 1, height: 1),
                           format: .RGBA8, colorSpace: profile.outputColorSpace)
            return result
        }
        let behind = pixel(x: size.width / 2, y: 20)
        XCTAssertGreaterThan(behind[0], 250)
        let backdrop = pixel(x: (size.width - Double(raster.width)) / 2 + 5,
                             y: subtitle.bottomInset + Double(raster.height) / 2)
        XCTAssertGreaterThan(backdrop[0], 10)
        XCTAssertLessThan(backdrop[0], 235, "Camera pixels must darken under the final subtitle backdrop")
        XCTAssertLessThan(backdrop[1], 5)
        XCTAssertLessThan(backdrop[2], 5)
    }

    func testCaptionPositionIsIndependentOfScreenProjectionAndSelectionTime() throws {
        var project = captionProject()
        let original = plan(project, at: 1.5)
        project.canvas.padding = 200
        let changed = plan(project, at: 1.5)
        XCTAssertEqual(original.scene.subtitle, changed.scene.subtitle)
        // Export callers keep selection offsets on presentationTime; the
        // final scene must select the cue at that same edited-video clock.
        XCTAssertEqual(changed.presentationTime, 1.5)
        XCTAssertEqual(changed.scene.subtitle?.text, "第一条字幕")
        let refreshed = FrameSceneEvaluator.refreshingCursor(
            in: original, at: 2, project: project, pointerTrack: nil,
            cursorMetrics: nil, cursorMetricsByAssetID: [:], zoomTrack: ZoomAnimationTrack([])
        )
        XCTAssertNil(refreshed.scene.subtitle, "Exact presentation ticks must honor cue end boundaries")
        XCTAssertFalse(refreshed.scene.layerOrder.contains(.subtitles))
    }

    private func visibleCharacters(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }

    private func captionProject() -> RecorderProject {
        var project = RecorderProject()
        let word = SubtitleWord(text: "第一条字幕", sourceRanges: [SubtitleTimeRange(start: 1, end: 2)])
        project.subtitles = SubtitleDocument(enabled: true, words: [word], cues: [
            SubtitleCue(wordIDs: [word.id], text: word.text),
        ])
        return project
    }

    private func plan(_ project: RecorderProject, at time: Double) -> FrameRenderPlan {
        FrameSceneEvaluator.renderPlan(
            project: project, presentationTime: time, outputDuration: 4, frameRate: 30,
            canvasSize: CompositionSize(width: 1920, height: 1080), sourceAspectRatio: 16.0 / 9
        )
    }

    private func signature(_ plan: FrameRenderPlan) -> PreviewVisualSignature {
        PreviewVisualSignature(plan: plan, separatesCursor: false, contentRevision: 0,
                               backingScale: 1, destinationPixelSize: CGSize(width: 1920, height: 1080),
                               colorContract: .sdrDesktop)
    }
}
