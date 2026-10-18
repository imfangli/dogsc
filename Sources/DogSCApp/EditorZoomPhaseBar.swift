import RecorderCore
import SwiftUI

/// Overview of the authored phases; the same duration bindings below perform
/// the actual edit, including the existing short-clip transition resolution.
/// Segments resize with the shared settle spring while duration sliders move.
struct EditorInspectorZoomPhases: View {
    let animation: ZoomAnimationClip

    var body: some View {
        GeometryReader { geometry in
            let total = max(animation.duration + animation.exitDuration, 0.001)
            let width = geometry.size.width
            let enter = width * min(animation.enterDuration / total, 1)
            let hold = width * max(animation.duration - animation.enterDuration, 0) / total
            let exit = max(width - enter - hold, 0)
            // One continuous capsule in the zoom clip's own colour: it ramps
            // in, holds and ramps out, with fine seams at each phase change.
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(LinearGradient(
                        stops: [
                            .init(color: surface.opacity(0.28), location: 0),
                            .init(color: surface, location: min(enter / max(width, 1), 1)),
                            .init(color: surface, location: min((enter + hold) / max(width, 1), 1)),
                            .init(color: surface.opacity(0.28), location: 1)
                        ],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(EditorTheme.timelineZoomInk.opacity(0.12), lineWidth: 0.5)
                    }
                HStack(spacing: 0) {
                    label("进入", icon: "arrow.down.right", width: enter)
                    seam(visible: enter > 0 && hold > 0)
                    label("保持", icon: "viewfinder", width: hold)
                    seam(visible: exit > 0 && hold > 0)
                    label("退出", icon: "arrow.up.left", width: exit)
                }
            }
        }
        .frame(height: 28)
        .accessibilityHidden(true)
        .animation(SpringMotion.settle, value: animation)
    }

    private var surface: Color { EditorTheme.timelineZoomSurface }

    private func seam(visible: Bool) -> some View {
        Rectangle()
            .fill(EditorTheme.timelineZoomInk.opacity(visible ? 0.22 : 0))
            .frame(width: 1, height: 14)
    }

    private func label(_ title: String, icon: String, width: CGFloat) -> some View {
        HStack(spacing: 4) {
            EditorSymbol(icon, size: 11.5)
                .font(.appUI(size: 10, weight: .semibold))
            Text(appLocalized(title))
                .font(.appUI(size: 11, weight: .semibold))
        }
        .foregroundStyle(EditorTheme.timelineZoomInk.opacity(0.85))
        .lineLimit(1)
        .fixedSize()
        .opacity(width > 58 ? 1 : 0)
        .frame(width: max(width - 1, 0))
        .clipped()
    }
}
