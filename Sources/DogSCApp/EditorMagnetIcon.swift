import SwiftUI

/// The snapping glyph, drawn on the same 18 pt line grid as every other
/// editor icon (it used to be a heavier filled shape).
struct EditorMagnetIcon: View {
    var body: some View {
        GeometryReader { proxy in
            AppLineIcon(kind: .magnet, size: min(proxy.size.width, proxy.size.height) * 1.15)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityHidden(true)
    }
}
