import AppKit
import CodexSyncedCore
import SwiftUI
import OSLog

@MainActor
final class SoftwareUpdateModel: ObservableObject {
    @Published var checkOnLaunch = UserDefaults.standard.bool(forKey: "checkForUpdatesOnLaunch") {
        didSet { UserDefaults.standard.set(checkOnLaunch, forKey: "checkForUpdatesOnLaunch") }
    }
    @Published private(set) var isChecking = false
    @Published private(set) var candidate: SoftwareUpdate?
    @Published private(set) var checkedAt: Date?
    @Published private(set) var error: String?
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    func check(manual: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        candidate = nil
        error = nil
        checkedAt = nil
        defer { isChecking = false }
        do {
            candidate = try await SoftwareUpdateService.check(currentVersion: currentVersion)
            checkedAt = Date()
        } catch {
            // Startup failures never show a modal or interrupt a repair.
            if manual { self.error = error.localizedDescription }
            else { Logger(subsystem: "com.zhoujia.codex-synced", category: "updates").notice("Update check failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func openDownloadPage() {
        guard let candidate else { return }
        if !NSWorkspace.shared.open(candidate.pageURL) {
            error = "Could not open the default browser."
        }
    }
}

struct SoftwareUpdateView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @ObservedObject var updater: SoftwareUpdateModel
    @State private var confirmingDownload = false

    var body: some View {
        SoftPanel {
            VStack(alignment: .leading, spacing: 14) {
                Text(viewModel.l10n.text("应用更新", "Software Update")).font(.headline)
                Text(viewModel.l10n.text("当前版本：\(updater.currentVersion)", "Current version: \(updater.currentVersion)"))
                Toggle(viewModel.l10n.text("启动时检查更新（不下载）", "Check on launch (no download)"), isOn: $updater.checkOnLaunch)
                Text(viewModel.l10n.text("来源：haohaomin/codex-session-synced · GitHub 稳定发布", "Source: haohaomin/codex-session-synced · GitHub stable releases"))
                    .font(.caption).foregroundStyle(DS.muted)
                SecondaryButton(title: viewModel.l10n.text(updater.isChecking ? "正在检查…" : "检查更新", updater.isChecking ? "Checking…" : "Check for Updates"), systemImage: "arrow.clockwise") {
                    Task { await updater.check(manual: true) }
                }.disabled(updater.isChecking)
                if let candidate = updater.candidate {
                    Text(viewModel.l10n.text("发现新版本：\(candidate.version)", "New version: \(candidate.version)"))
                    if !candidate.notes.isEmpty {
                        ScrollView {
                            Text(verbatim: candidate.notes).font(.system(size: 12)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 180)
                    }
                    SecondaryButton(title: viewModel.l10n.text("打开下载页面", "Open Download Page"), systemImage: "arrow.up.right.square") {
                        confirmingDownload = true
                    }.disabled(viewModel.isBusy)
                } else if updater.checkedAt != nil {
                    Text(viewModel.l10n.text("没有更新的稳定版本。", "No newer stable release is available."))
                }
                if let date = updater.checkedAt {
                    Text(viewModel.l10n.text("检查时间：", "Checked: ") + date.formatted()).font(.caption).foregroundStyle(DS.muted)
                }
                if let error = updater.error {
                    Text(viewModel.l10n.text("检查或打开页面失败：", "Check or browser launch failed: ") + error).foregroundStyle(.orange)
                }
                Text(viewModel.l10n.text(
                    "当前仅检查版本并打开下载页，不自动安装。发布包尚无独立更新签名；请手动安装，并保留旧应用与备份。不会修改 Codex 对话或配置。",
                    "Checks versions and opens the download page only; no automatic installation. Packages do not yet have independent updater signatures. Install manually and keep the old app and backups. Codex chats and configuration are not modified."))
                    .font(.caption).foregroundStyle(DS.muted).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert(viewModel.l10n.text("手动更新 Codex Synced", "Update Codex Synced Manually"), isPresented: $confirmingDownload) {
            Button(viewModel.l10n.text("打开发布页", "Open Release Page")) { updater.openDownloadPage() }
            Button(viewModel.l10n.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(viewModel.l10n.text("下载对应版本的 macOS DMG。安装前请完成修复并正常退出 Codex Synced，保留旧应用和备份，再手动替换应用。打开页面不代表已安装；重启后检查版本。", "Download the macOS DMG for this version. Finish repairs and quit Codex Synced normally, keep the old app and backups, then replace the app manually. Opening the page does not mean installation succeeded; verify the version after relaunch."))
        }
    }
}
