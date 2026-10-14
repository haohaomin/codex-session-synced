import CodexSyncedCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HeaderView(
                    title: viewModel.l10n.text("设置", "Settings"),
                    subtitle: viewModel.l10n.text("保留最少必要配置，避免把工具做成数据库管理器。", "Only the necessary settings for this repair tool.")
                )

                SoftPanel {
                    VStack(spacing: 0) {
                        pickerRow(title: viewModel.l10n.text("界面语言", "Language")) {
                            LanguageSwitch()
                                .frame(width: 220)
                        }
                        rowDivider

                        pathRow(
                            title: "Codex Home",
                            url: viewModel.settings.codexHome,
                            action: { chooseDirectory { viewModel.settings.codexHome = $0 } }
                        )
                        rowDivider

                        pathRow(
                            title: "SQLite Home",
                            url: viewModel.settings.sqliteHome ?? viewModel.settings.codexHome,
                            action: { chooseDirectory { viewModel.settings.sqliteHome = $0 } }
                        )
                        rowDivider

                        pickerRow(title: viewModel.l10n.text("默认备份模式", "Default Backup")) {
                            BackupModeSwitch(selection: Binding(
                                get: { viewModel.settings.defaultBackupMode },
                                set: {
                                    viewModel.settings.defaultBackupMode = $0
                                    viewModel.selectedBackupMode = $0
                                }
                            ), language: viewModel.settings.language)
                            .frame(width: 240)
                        }
                        rowDivider

                        stepperRow(title: viewModel.l10n.text("轻量备份最大数量", "Lightweight Limit"), value: $viewModel.settings.lightweightLimit, range: 1...30)
                        rowDivider
                        stepperRow(title: viewModel.l10n.text("全量备份最大数量", "Full Limit"), value: $viewModel.settings.fullLimit, range: 1...12)
                        rowDivider

                        HStack(alignment: .center, spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(viewModel.l10n.text("跨 Provider 显示历史", "Cross-provider history visibility"))
                                    .foregroundStyle(DS.ink)
                                Text(viewModel.l10n.text("切到 custom/openai_http 后，将可恢复本地会话对齐到当前 Provider。", "When switching to custom/openai_http, align recoverable local threads to the active provider."))
                                    .font(.system(size: 12))
                                    .foregroundStyle(DS.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            AnimatedToggle(isOn: Binding(
                                get: { viewModel.settings.alignProvidersForVisibility },
                                set: { value in
                                    viewModel.settings.alignProvidersForVisibility = value
                                    Task { await viewModel.scan() }
                                }
                            ))
                        }
                        .padding(.vertical, 13)
                        .animation(AppMotion.smooth, value: viewModel.settings.alignProvidersForVisibility)
                        rowDivider

                        HStack {
                            Text(viewModel.l10n.text("修复完成后自动打开 Codex", "Open Codex after repair"))
                                .foregroundStyle(DS.ink)
                            Spacer()
                            AnimatedToggle(isOn: $viewModel.settings.openCodexAfterRepair)
                        }
                        .padding(.vertical, 13)
                        .animation(AppMotion.smooth, value: viewModel.settings.openCodexAfterRepair)
                    }
                }
                SoftwareUpdateView(updater: viewModel.updater)
            }
            .padding(28)
        }
    }

    private func pickerRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(DS.ink)
            Spacer()
            content()
        }
        .padding(.vertical, 13)
    }

    private func pathRow(title: String, url: URL, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(DS.ink)
            Spacer()
            Text(url.path)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(DS.muted)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 390, alignment: .trailing)
            SecondaryButton(title: viewModel.l10n.text("选择", "Choose"), systemImage: "folder", action: action)
        }
        .padding(.vertical, 13)
    }

    private func stepperRow(title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(DS.ink)
            Spacer()
            CounterControl(value: value, range: range)
        }
        .padding(.vertical, 13)
    }

    private var rowDivider: some View {
        Divider().opacity(0.42)
    }

    private func chooseDirectory(_ onChoose: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            onChoose(url)
            Task { await viewModel.scan() }
        }
    }
}
