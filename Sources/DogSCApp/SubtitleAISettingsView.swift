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
        VStack(alignment: .leading, spacing: 24) {
            settingsGroup("AI 校对接口", footer: "API Key 保存在系统钥匙串中，不写入项目文件") {
                VStack(alignment: .leading, spacing: 16) {
                    Text(appLocalized("配置 OpenAI 兼容接口，用于字幕校对"))
                        .font(.appUI(size: 13)).foregroundStyle(SettingsTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 14) {
                        field("服务地址") {
                            TextField("https://example.com/v1", text: $configuration.baseURL)
                        }
                        field("模型名称") { TextField("model-name", text: $configuration.model) }
                        field("API Key") { SecureField("API Key", text: $configuration.apiKey) }
                    }
                    .textFieldStyle(.roundedBorder)
                    Text(appLocalized("校对时会将字幕文字、参考稿和主题发送到你配置的服务"))
                        .font(EditorTypography.helper).foregroundStyle(SettingsTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
            }

            settingsGroup(footer: "测试只发送一条简短请求，不发送字幕或口播稿") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Button(appLocalized("保存配置")) {
                            do {
                                try SubtitleAISettings.save(configuration)
                                errorMessage = nil
                                saved = true
                                onSaved()
                            } catch { errorMessage = appErrorDescription(error) }
                        }
                        .buttonStyle(SettingsPillButtonStyle(prominent: true))
                        .disabled(isTestingConnection)
                        .accessibilityIdentifier("settings.subtitle-ai.save")

                        Button(appLocalized(isTestingConnection ? "正在测试连接…" : "测试连接")) {
                            testConnection()
                        }
                        .buttonStyle(SettingsPillButtonStyle())
                        .disabled(isTestingConnection)
                        .accessibilityIdentifier("settings.subtitle-ai.test")

                        if isTestingConnection {
                            Button(appLocalized("取消")) { cancelConnectionTest() }
                                .buttonStyle(SettingsPillButtonStyle())
                        }
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(EditorTypography.helper).foregroundStyle(SettingsTheme.recording)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if connectionSucceeded {
                        HStack(spacing: 5) {
                            AppLineIcon(kind: .checkCircle, size: 15)
                            Text(appLocalized("连接成功，模型可用"))
                        }
                        .font(EditorTypography.helper).foregroundStyle(RecorderStyle.positiveInk)
                    }
                    if saved {
                        Text(appLocalized("已保存"))
                            .font(EditorTypography.helper).foregroundStyle(SettingsTheme.textSecondary)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(SettingsTheme.textPrimary)
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

    private func settingsGroup<Content: View>(
        _ title: String? = nil,
        footer: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { SettingsCaption(title) }
            content().settingsTile()
            Text(appLocalized(footer))
                .font(EditorTypography.helper)
                .foregroundStyle(SettingsTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
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
            Text(appLocalized(title)).font(.appUI(size: 12, weight: .medium)).foregroundStyle(SettingsTheme.textSecondary)
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
                Button { dismiss() } label: { AppLineIcon(kind: .close, size: 15) }
                    .buttonStyle(SettingsPillButtonStyle()).accessibilityLabel(appLocalized("关闭"))
            }
            SubtitleAIConfigurationEditor(onSaved: { dismiss() })
        }
        .padding(24).frame(width: 480)
        .foregroundStyle(SettingsTheme.textPrimary)
        .background(SettingsTheme.canvasBackground)
        .tint(SettingsTheme.mint)
        .appControlFocusAppearance()
    }
}
