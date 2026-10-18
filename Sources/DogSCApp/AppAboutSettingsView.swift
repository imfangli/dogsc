import AppKit
import SwiftUI

/// Identity in the centre of the island, three ways to reach the project as
/// tiles, and the update controls as one bar along the bottom.
struct AppAboutSettingsView: View {
    @ObservedObject private var updateController = AppUpdateController.shared
    @State private var showsSupportSheet = false
    @State private var heroArrived = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 76, height: 76)
                    .shadow(color: RecorderStyle.lift, radius: 12, y: 6)
                    .scaleEffect(heroArrived || RecorderMotion.reduces ? 1 : 0.84)
                    .offset(y: heroArrived || RecorderMotion.reduces ? 0 : 6)
                    .accessibilityHidden(true)

                VStack(spacing: 5) {
                    Text(AppIdentity.displayName)
                        .font(.appUI(size: 21, weight: .semibold))
                        .foregroundStyle(RecorderStyle.ink)

                    Text(appLocalized("丝滑、优雅的高性能屏幕录制工具"))
                        .font(.appUI(size: 12))
                        .foregroundStyle(SettingsTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(updateController.currentVersionDescription)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(SettingsTheme.track, in: Capsule(style: .continuous))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
            .padding(.bottom, 22)
            .onAppear {
                withAnimation((RecorderMotion.morph ?? .easeOut(duration: 0.2)).delay(0.14)) { heroArrived = true }
            }

            HStack(spacing: 8) {
                SettingsLinkTile(icon: .code, title: "开源仓库 (GitHub)") {
                    NSWorkspace.shared.open(AppProjectLinks.source)
                }
                SettingsLinkTile(icon: .feedback, title: "反馈与建议") {
                    NSWorkspace.shared.open(AppProjectLinks.feedback)
                }
                SettingsLinkTile(icon: .cup, title: "自愿赞赏支持", trailingIcon: .chevron,
                                 accessibilityIdentifier: "settings.about.support") {
                    showsSupportSheet = true
                }
            }

            HStack(spacing: 12) {
                AppLineIcon(kind: .refresh, size: 18)
                    .foregroundStyle(SettingsTheme.textSecondary)
                Text(appLocalized("自动检查更新"))
                    .font(.appUI(size: 12.5, weight: .semibold))
                    .foregroundStyle(SettingsTheme.textPrimary)
                Spacer(minLength: 8)
                Button {
                    updateController.checkForUpdates()
                } label: {
                    Text(appLocalized("检查更新"))
                }
                .buttonStyle(SettingsPillButtonStyle(compact: true))
                .disabled(!updateController.isFormalRelease || !updateController.isReady)
                .help(appLocalized(updateController.availabilityDescription))
                .accessibilityHint(appLocalized("从 GitHub Release 检查并安装 DogSC 新版本"))

                SettingsToggle(
                    isOn: Binding(
                        get: { updateController.automaticallyChecksForUpdates },
                        set: { updateController.setAutomaticallyChecksForUpdates($0) }
                    ),
                    accessibilityLabel: "自动检查更新"
                )
                .disabled(!updateController.isFormalRelease)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 56)
            .settingsTile()
            .padding(.top, 8)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .sheet(isPresented: $showsSupportSheet) { AppSupportSheet() }
    }
}

/// A destination as a tile: glyph and a travelling arrow on top, name below.
private struct SettingsLinkTile: View {
    let icon: AppLineIcon.Kind
    let title: String
    var trailingIcon: AppLineIcon.Kind = .external
    var accessibilityIdentifier: String? = nil
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    AppLineIcon(kind: icon, size: 22)
                        .foregroundStyle(hovered ? SettingsTheme.textPrimary : SettingsTheme.textSecondary)
                    Spacer(minLength: 0)
                    AppLineIcon(kind: trailingIcon, size: 11)
                        .foregroundStyle(hovered ? SettingsTheme.textSecondary : SettingsTheme.textFaint)
                        .offset(x: hovered && !RecorderMotion.reduces ? 2 : 0,
                                y: hovered && !RecorderMotion.reduces && trailingIcon == .external ? -2 : 0)
                }
                Spacer(minLength: 16)
                Text(appLocalized(title))
                    .font(.appUI(size: 12.5, weight: .semibold))
                    .foregroundStyle(SettingsTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
            .settingsTile(hovered: hovered)
            .contentShape(RoundedRectangle(cornerRadius: SettingsLayout.tileRadius, style: .continuous))
        }
        .buttonStyle(SettingsPressStyle(scale: 0.97))
        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: SettingsLayout.tileRadius, style: .continuous))
        .onHover { inside in withAnimation(RecorderMotion.settle ?? RecorderMotion.fade) { hovered = inside } }
        .accessibilityLabel(appLocalized(title))
        .accessibilityIdentifier(accessibilityIdentifier ?? "settings.about.\(title)")
    }
}

private enum AppProjectLinks {
    static let source = URL(string: "https://github.com/laogou717/dogsc")!
    static let feedback = URL(string: "https://github.com/laogou717/dogsc/issues")!
}
