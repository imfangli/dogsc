import SwiftUI

struct SubtitleAIConfigurationEditor: View {
    var onSaved: () -> Void = {}
    @State private var configuration = SubtitleAIConfiguration()
    @State private var errorMessage: String?
    @State private var saved = false
    @State private var isTestingConnection = false
    @State private var connectionSucceeded = false
    @State private var connectionTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(appLocalized("配置 OpenAI 兼容接口，用于字幕校对"))
                .font(.appUI(.body)).foregroundStyle(EditorTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                field("服务地址") {
                    TextField("https://example.com/v1", text: $configuration.baseURL)
                }
                field("模型名称") { TextField("model-name", text: $configuration.model) }
                field("API Key") { SecureField("API Key", text: $configuration.apiKey) }
            }.textFieldStyle(.roundedBorder)
            Text(appLocalized("API Key 保存在系统钥匙串中，不写入项目文件"))
                .font(.appUI(.caption)).foregroundStyle(EditorTheme.secondaryText)
            Text(appLocalized("校对时会将字幕文字、参考稿和主题发送到你配置的服务"))
                .font(.appUI(.caption)).foregroundStyle(EditorTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let errorMessage { Text(errorMessage).font(.appUI(.caption)).foregroundStyle(.red) }
            if connectionSucceeded {
                Label(appLocalized("连接成功，模型可用"), systemImage: "checkmark.circle.fill")
                    .font(.appUI(.caption)).foregroundStyle(.green)
            }
            HStack {
                Button(appLocalized("保存配置")) {
                    do {
                        try SubtitleAISettings.save(configuration)
                        errorMessage = nil
                        saved = true
                        onSaved()
                    } catch { errorMessage = appErrorDescription(error) }
                }.buttonStyle(.editorPrimary)
                    .disabled(isTestingConnection)
                    .accessibilityIdentifier("settings.subtitle-ai.save")
                Button(appLocalized(isTestingConnection ? "正在测试连接…" : "测试连接")) {
                    testConnection()
                }.buttonStyle(.editorQuiet)
                    .disabled(isTestingConnection)
                    .accessibilityIdentifier("settings.subtitle-ai.test")
                if isTestingConnection {
                    Button(appLocalized("取消")) { cancelConnectionTest() }
                        .buttonStyle(.editorQuiet)
                }
            }
            if saved { Text(appLocalized("已保存")).font(.appUI(.caption)).foregroundStyle(.secondary) }
            Text(appLocalized("测试只发送一条简短请求，不发送字幕或口播稿"))
                .font(.appUI(.caption)).foregroundStyle(EditorTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            do { configuration = try SubtitleAISettings.load() }
            catch { errorMessage = appErrorDescription(error) }
        }
        .onChange(of: configuration) { _, _ in
            saved = false
            connectionSucceeded = false
            errorMessage = nil
            cancelConnectionTest()
        }
        .onDisappear { cancelConnectionTest() }
        .accessibilityIdentifier("settings.subtitle-ai")
    }

    private func testConnection() {
        guard !isTestingConnection else { return }
        let candidate = configuration
        isTestingConnection = true
        connectionSucceeded = false
        errorMessage = nil
        connectionTask = Task { @MainActor in
            do {
                try await SubtitleAIClient().testConnection(configuration: candidate)
                guard !Task.isCancelled, configuration == candidate else { return }
                connectionSucceeded = true
            } catch {
                guard !Task.isCancelled, configuration == candidate else { return }
                errorMessage = appErrorDescription(error)
            }
            isTestingConnection = false
            connectionTask = nil
        }
    }

    private func cancelConnectionTest() {
        connectionTask?.cancel()
        connectionTask = nil
        isTestingConnection = false
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(appLocalized(title)).font(.appUI(.caption)).foregroundStyle(EditorTheme.secondaryText)
            content().accessibilityLabel(appLocalized(title))
        }
    }
}

struct SubtitleAISettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(appLocalized("AI 校对接口")).font(.appUI(size: 20, weight: .semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.editorQuiet).accessibilityLabel(appLocalized("关闭"))
            }
            SubtitleAIConfigurationEditor(onSaved: { dismiss() })
        }
        .padding(24).frame(width: 480)
        .background(EditorTheme.panelSurface)
        .appControlFocusAppearance()
    }
}
