import SwiftUI

/// Ephemeral editor feedback. Ongoing failures retain their own save/preview
/// status entry; this card never holds the workspace until manually dismissed.
struct EditorTransientNotice: View {
    let message: String
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var remaining: CGFloat = 1

    private var content: (title: String, detail: String) {
        if message == appLocalized("此处已有同轨道动画，无法粘贴完整片段。请在足够长的空白处粘贴。") {
            return (appLocalized("这里已有片段"), appLocalized("移到空白处，或贴近边缘再粘贴"))
        }
        if message == appLocalized("此位置到片尾的时长不足，无法粘贴完整片段。请选择更靠前的位置。") {
            return (appLocalized("剩余空间不够"), appLocalized("移到更靠前的位置，保留完整片段"))
        }
        let prefix = "项目已打开，但"
        if message.hasPrefix(prefix) {
            return (appLocalized("项目已打开，需要留意"), appLocalized(String(message.dropFirst(prefix.count))))
        }
        return (appLocalized("操作未完成"), appLocalized(message))
    }

    var body: some View {
        let text = content
        let lifetime = min(max(Double(text.detail.count) * 0.08, 5), 10)
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                EditorSymbol("info", size: 17)
                    .font(.appUI(size: 13, weight: .semibold))
                    .foregroundStyle(EditorTheme.primaryText.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .background(EditorTheme.chrome(0.06), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(text.title).font(.appUI(size: 13, weight: .semibold))
                        .foregroundStyle(EditorTheme.chrome(0.86))
                    Text(text.detail).font(.appUI(size: 12))
                        .foregroundStyle(EditorTheme.chrome(0.56))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: dismiss) {
                    EditorSymbol("xmark", size: 12.5).font(.appUI(size: 10, weight: .semibold))
                }
                .buttonStyle(.editorDismissIcon(size: 24))
                .help("关闭提示")
                .accessibilityLabel("关闭提示")
            }
            GeometryReader { geometry in
                Capsule().fill(EditorTheme.chrome(0.045))
                Capsule().fill(LinearGradient(colors: [EditorTheme.chrome(0.12), EditorTheme.chrome(0.32)],
                                              startPoint: .leading, endPoint: .trailing))
                    .frame(width: geometry.size.width * remaining)
            }
            .frame(height: 2)
            .padding(.leading, 41)
            .accessibilityHidden(true)
        }
        .padding(14)
        .frame(width: 352)
        .modifier(EditorFloatingSurface(cornerRadius: 16))
        .appControlFocusAppearance()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(text.title + "：" + text.detail)
        .task {
            remaining = 1
            await Task.yield()
            guard !Task.isCancelled else { return }
            if !reduceMotion { withAnimation(.linear(duration: lifetime)) { remaining = 0 } }
            do { try await Task.sleep(for: .seconds(lifetime)) }
            catch { return }
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }
}
