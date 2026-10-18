import AppKit
import RecorderCore
import SwiftUI

/// The top of every 画面 page: the project's own frame on the wallpaper it
/// has chosen, drawn with the live margin, corner, stroke, shadow and mockup
/// so turning any control repaints a picture rather than a number.
struct EditorFramePreview: View {
    let canvas: CanvasStyle
    let screenImage: NSImage?
    let wallpaper: SystemWallpaperAsset?
    var height: CGFloat = 146

    var body: some View {
        EditorInspectorStage(height: height) {
            ZStack {
                if let wallpaper {
                    Color.clear
                        .overlay { SystemWallpaperThumbnail(asset: wallpaper) }
                        .clipped()
                        .blur(radius: min(max(canvas.backgroundBlur, 0), 40) * 0.25)
                        .overlay { Color.black.opacity(0.06) }
                        .transition(.opacity)
                        .id(wallpaper.id)
                }
                GeometryReader { proxy in
                    screen(in: proxy.size)
                }
            }
            .animation(SpringMotion.fluid, value: wallpaper?.id)
        }
        .animation(SpringMotion.settle, value: canvas.padding)
        .animation(SpringMotion.settle, value: canvas.cornerRadius)
        .animation(SpringMotion.settle, value: canvas.borderWidth)
        .animation(SpringMotion.settle, value: canvas.shadowStrength)
        .animation(SpringMotion.settle, value: canvas.screenFrame)
        .animation(SpringMotion.settle, value: canvas.screenFrameScale)
        .animation(SpringMotion.settle, value: canvas.contentPosition)
        .consoleReveal()
    }

    private var frame: ScreenFrameStyle { canvas.screenFrame }
    private var isDark: Bool { frame == .windowDark || frame == .browserDark }

    private func screen(in stage: CGSize) -> some View {
        let margin = min(
            14 + (min(max(canvas.padding, 0), 360) / 360) * (stage.height * 0.26),
            min(stage.width, stage.height) * 0.42
        )
        let bar: CGFloat = frame.isWindowFrame || frame.isBrowserFrame ? 11 : 0
        let bezel: CGFloat = frame.isDeviceFrame ? 4.5 : 0
        let scale = frame == .none ? 1 : min(max(canvas.screenFrameScale, 0.6), 1.6)
        let available = CGSize(
            width: max(stage.width - margin * 2 - bezel * 2, 20),
            height: max(stage.height - margin * 2 - bar - bezel * 2, 20)
        )
        let base = editorStageScreenSize(in: available, image: screenImage, widthFraction: 1, heightLimit: 1)
        let content = CGSize(
            width: min(base.width * scale, available.width),
            height: min(base.height * scale, available.height)
        )
        let contentRadius = 3 + (min(max(radius, 0), 160) / 160) * 9
        let total = CGSize(width: content.width + bezel * 2, height: content.height + bar + bezel * 2)
        let free = CGSize(
            width: max(stage.width - total.width, 0), height: max(stage.height - total.height, 0)
        )
        let position = canvas.contentPosition
        let shape = RoundedRectangle(
            cornerRadius: frame.isDeviceFrame ? bezel * 3 : frame == .none ? contentRadius : 6,
            style: .continuous
        )
        return VStack(spacing: 0) {
            if bar > 0 { chromeBar(height: bar, width: total.width) }
            EditorStageScreen(image: screenImage, radius: frame == .none ? contentRadius : (frame.isDeviceFrame ? 3 : 0))
                .shadow(color: .clear, radius: 0)
                .frame(width: content.width, height: content.height)
        }
        .padding(bezel)
        .background {
            if frame.isDeviceFrame {
                shape.fill(Color(white: 0.1))
                    .overlay { shape.strokeBorder(Color.white.opacity(0.3), lineWidth: 0.75) }
            }
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(.white.opacity(0.92), lineWidth: min(max(canvas.borderWidth, 0), 40) * 0.3)
        }
        .shadow(color: .black.opacity(0.18 + 0.4 * min(max(canvas.shadowStrength, 0), 1)), radius: 9, y: 5)
        .position(
            x: total.width / 2 + free.width * CGFloat(min(max(position.x, 0), 1)),
            y: total.height / 2 + free.height * CGFloat(min(max(position.y, 0), 1))
        )
    }

    private var radius: Double {
        frame == .none ? canvas.cornerRadius
            : canvas.screenFrameContentCornerRadius ?? frame.defaultContentCornerRadius
    }

    private func chromeBar(height: CGFloat, width: CGFloat) -> some View {
        HStack(spacing: 3) {
            ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                     Color(red: 0.16, green: 0.78, blue: 0.25)], id: \.self) {
                Circle().fill($0).frame(width: 4, height: 4)
            }
            if frame.isBrowserFrame {
                Capsule(style: .continuous)
                    .fill(isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.07))
                    .frame(height: 5)
                    .padding(.horizontal, 14)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 6)
        .frame(width: width, height: height)
        .background(isDark ? Color(white: 0.17) : Color(white: 0.96))
    }
}
