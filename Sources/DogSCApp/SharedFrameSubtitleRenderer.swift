import AppKit
import CoreImage
import CoreText
import Foundation
import RecorderCore

/// The same small, sRGB glyph bitmap is used by editor preview and export.
/// Only the final-canvas placement varies between frames; text layout is
/// cached independently of time, cue identity and screen/camera geometry.
enum SharedFrameSubtitleRenderer {
    private static let cache = SubtitleRasterCache()

    nonisolated static func image(
        scene: FrameSubtitleScene,
        canvasSize: CompositionSize
    ) -> CIImage? {
        guard let raster = raster(scene: scene, canvasSize: canvasSize) else { return nil }
        let x = (canvasSize.width - Double(raster.width)) / 2
        let y = min(scene.bottomInset, max(canvasSize.height - Double(raster.height), 0))
        return raster.image.transformed(by: CGAffineTransform(translationX: x, y: y))
    }

    nonisolated static func raster(
        scene: FrameSubtitleScene,
        canvasSize: CompositionSize
    ) -> SubtitleRaster? {
        let key = SubtitleRasterKey(scene: scene, canvasSize: canvasSize)
        return cache.raster(for: key) { SubtitleRasterizer.make(scene: scene, canvasSize: canvasSize) }
    }
}

/// Immutable CPU-backed storage. Core Image converts its explicit sRGB input
/// through the compositor's existing linear working/output color contract.
final class SubtitleRaster: @unchecked Sendable {
    let image: CIImage
    let width: Int
    let height: Int
    let lines: [String]
    let fontSize: CGFloat

    init(image: CGImage, lines: [String], fontSize: CGFloat, colorSpace: CGColorSpace) {
        self.image = CIImage(cgImage: image, options: [.colorSpace: colorSpace])
        width = image.width
        height = image.height
        self.lines = lines
        self.fontSize = fontSize
    }

    var cost: Int { width * height * 4 }
}

private struct SubtitleRasterKey: Hashable {
    let text: String
    let fontSize: Double
    let textColor: HexColor
    let backgroundColor: HexColor
    let backgroundOpacity: Double
    let canvasWidth: Double
    let canvasHeight: Double

    init(scene: FrameSubtitleScene, canvasSize: CompositionSize) {
        text = scene.text
        fontSize = scene.fontSize
        textColor = scene.textColor
        backgroundColor = scene.backgroundColor
        backgroundOpacity = scene.backgroundOpacity
        canvasWidth = canvasSize.width
        canvasHeight = canvasSize.height
    }
}

/// A strict count and byte bound avoids retaining every cue in a long movie.
/// The lock also serializes cache misses from simultaneous preview/export.
private final class SubtitleRasterCache: @unchecked Sendable {
    private struct Entry {
        let key: SubtitleRasterKey
        let raster: SubtitleRaster
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var totalCost = 0
    private let countLimit = 48
    private let costLimit = 24 * 1_024 * 1_024

    func raster(for key: SubtitleRasterKey, make: () -> SubtitleRaster?) -> SubtitleRaster? {
        lock.lock()
        defer { lock.unlock() }
        if let index = entries.firstIndex(where: { $0.key == key }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.raster
        }
        guard let result = make() else { return nil }
        guard result.cost <= costLimit else { return result }
        while entries.count >= countLimit || totalCost + result.cost > costLimit {
            totalCost -= entries.removeFirst().raster.cost
        }
        entries.append(Entry(key: key, raster: result))
        totalCost += result.cost
        return result
    }
}

private enum SubtitleRasterizer {
    private struct Line {
        let text: String
        let line: CTLine
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        let leading: CGFloat
    }

    nonisolated static func make(
        scene: FrameSubtitleScene,
        canvasSize: CompositionSize
    ) -> SubtitleRaster? {
        guard canvasSize.width.isFinite, canvasSize.height.isFinite,
              canvasSize.width >= 2, canvasSize.height >= 2,
              canvasSize.width <= 32_768, canvasSize.height <= 32_768,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // Preserve user-authored breaks; normalize CRLF and horizontal space
        // without touching the displayed words, punctuation or graphemes.
        let paragraphs = scene.text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            .filter { !$0.isEmpty }
        // Three explicit lines cannot satisfy the two-line presentation at
        // any font size. Treat only those extra breaks as soft boundaries.
        let text = paragraphs.joined(separator: paragraphs.count <= 2 ? "\n" : " ")
        guard !text.isEmpty else { return nil }
        let scale = CGFloat(CompositionSceneEvaluator.canonicalStyleScale(
            canvasWidth: canvasSize.width, canvasHeight: canvasSize.height
        ))
        // Shape at the project's canonical size, then rasterize that layout
        // through the output scale. Asking the system font to shape at 44 and
        // 88 independently changes its optical metrics and CJK glyph advances,
        // which otherwise changes widths and line breaks between preview/4K.
        let paddingX: CGFloat = 18
        let paddingY: CGFloat = 10
        let maxWidth = max(CGFloat(canvasSize.width) / scale - 96 - paddingX * 2, 1)
        let maxHeight = max(CGFloat(canvasSize.height) / scale - 32 - paddingY * 2, 1)
        let color = scene.textColor.components
        let foreground = CGColor(colorSpace: colorSpace, components: [
            color.red, color.green, color.blue, 1,
        ])!

        func layout(at size: CGFloat) -> [Line] {
            lines(text: text, fontSize: size, maxWidth: maxWidth, foreground: foreground)
        }
        func fits(_ candidate: [Line], size: CGFloat) -> Bool {
            candidate.count <= 2 && !candidate.isEmpty
                && candidate.allSatisfy { $0.width <= maxWidth + 0.001 }
                && contentHeight(candidate, fontSize: size) <= maxHeight
        }

        var fontSize = min(CGFloat(scene.fontSize) / scale, maxHeight)
        var fittedLines = layout(at: fontSize)
        if !fits(fittedLines, size: fontSize) {
            // Generation normally emits short cues. An arbitrarily long
            // manual edit still displays every character in at most two
            // lines, by reducing size rather than clipping/ellipsizing it.
            var lower: CGFloat = 0.01
            var upper = fontSize
            for _ in 0..<20 {
                let trial = (lower + upper) / 2
                let candidate = layout(at: trial)
                if fits(candidate, size: trial) { lower = trial } else { upper = trial }
            }
            fontSize = lower
            fittedLines = layout(at: fontSize)
        }
        guard !fittedLines.isEmpty, fittedLines.count <= 2 else { return nil }
        let contentWidth = fittedLines.map(\.width).max() ?? 0
        let fittedContentHeight = contentHeight(fittedLines, fontSize: fontSize)
        let width = max(Int(ceil((contentWidth + paddingX * 2) * scale)), 1)
        let height = max(Int(ceil((fittedContentHeight + paddingY * 2) * scale)), 1)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let backdrop = scene.backgroundColor.components
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [
            backdrop.red, backdrop.green, backdrop.blue, scene.backgroundOpacity,
        ])!)
        let rect = CGRect(x: 0, y: 0, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 8,
                              cornerHeight: 8, transform: nil))
        context.fillPath()
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(false)
        context.textMatrix = .identity
        var top = CGFloat(height) / scale - paddingY
        for line in fittedLines {
            context.textPosition = CGPoint(x: (CGFloat(width) / scale - line.width) / 2,
                                           y: top - line.ascent)
            CTLineDraw(line.line, context)
            top -= line.ascent + line.descent + max(line.leading, fontSize * 0.16)
        }
        guard let image = context.makeImage() else { return nil }
        return SubtitleRaster(image: image, lines: fittedLines.map(\.text),
                              fontSize: fontSize * scale, colorSpace: colorSpace)
    }

    private nonisolated static func contentHeight(_ lines: [Line], fontSize: CGFloat) -> CGFloat {
        lines.enumerated().reduce(0) { result, value in
            let (index, line) = value
            return result + line.ascent + line.descent
                + (index < lines.count - 1 ? max(line.leading, fontSize * 0.16) : 0)
        }
    }

    private nonisolated static func lines(
        text: String, fontSize: CGFloat, maxWidth: CGFloat, foreground: CGColor
    ) -> [Line] {
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String):
                NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground,
        ])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let source = text as NSString
        let boundaries = [0] + text.indices.dropFirst().map {
            $0.utf16Offset(in: text)
        } + [source.length]
        var offset = 0
        var result: [Line] = []
        // A third line is enough to reject a candidate size. Avoid laying out
        // hundreds of overflow lines during the fitting search.
        while offset < source.length, result.count < 3 {
            let suggested = CTTypesetterSuggestLineBreak(typesetter, offset, Double(maxWidth))
            var end = boundaries.last(where: { $0 <= offset + max(suggested, 1) }) ?? offset
            if end <= offset {
                end = boundaries.first(where: { $0 > offset }) ?? source.length
            }
            let range = CFRange(location: offset, length: end - offset)
            let line = CTTypesetterCreateLine(typesetter, range)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
                - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
            result.append(Line(text: source.substring(with: NSRange(location: offset, length: end - offset)),
                               line: line, width: max(width, 0), ascent: ascent,
                               descent: descent, leading: leading))
            offset = end
        }
        return result
    }
}
