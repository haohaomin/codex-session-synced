import AppKit
import CodexSyncedCore
import Foundation

enum NoticeTone {
    case info
    case success
    case warning
}

struct AppNotice: Identifiable {
    var id = UUID()
    var title: String
    var message: String
    var tone: NoticeTone
    var isLoading: Bool
}

struct OperationProgress: Equatable {
    var title: String
    var detail: String
    var fraction: Double?
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            if oldValue.codexHome != settings.codexHome || oldValue.sqliteHome != settings.sqliteHome {
                settings.historyDatabase = nil
                historyDatabases = []
                managedBackups = []
            }
            settings.save()
            l10n = L10n(language: settings.language)
            if oldValue.codexHome != settings.codexHome || oldValue.sqliteHome != settings.sqliteHome || oldValue.historyDatabase != settings.historyDatabase {
                historyScan = nil
                historyRecords = []
                historyMessage = nil
            }
        }
    }
    @Published var l10n: L10n
    @Published var scanResult: ScanResult?
    @Published var status: ScanStatus = .idle
    @Published var selectedSection: AppSection = .home
    @Published var selectedBackupMode: BackupMode
    @Published var selectedBackupForRestore: BackupRecord?
    @Published var showingRestoreConfirmation = false
    @Published var showingCodexRunningAlert = false
    @Published var notice: AppNotice?
    @Published var lastScanAt: Date?
    @Published var progress: OperationProgress?
    @Published var historyScan: HistoryScan?
    @Published var historyRecords: [HistoryRepairRecord] = []
    @Published var historyMessage: String?
    @Published var historyDatabases: [URL] = []
    @Published var isHistoryScanning = false
    @Published var managedBackups: [ManagedBackup] = []
    @Published var backupWarnings: [String] = []
    @Published var loadingBackups = false

    let service = CodexRepairService()
    let updater = SoftwareUpdateModel()
    private var dismissNoticeTask: Task<Void, Never>?

    init() {
        let loadedSettings = AppSettings.load()
        settings = loadedSettings
        l10n = L10n(language: loadedSettings.language)
        selectedBackupMode = loadedSettings.defaultBackupMode
        Task { await scan(showFeedback: false) }
        if updater.checkOnLaunch { Task { await updater.check(manual: false) } }
    }

    func scan(showFeedback: Bool = true) async {
        guard !isBusy else { return }
        status = .scanning
        setProgress(
            title: l10n.text("识别当前环境", "Detecting environment"),
            detail: l10n.text("正在读取 config.toml、状态库和 Provider 设置。", "Reading config.toml, state database, and provider settings."),
            fraction: 0.16
        )
        if showFeedback {
            showNotice(
                title: l10n.text("正在扫描", "Scanning"),
                message: l10n.text("正在检查本地侧边栏摘要和会话历史。", "Checking local sidebar summaries and conversation history."),
                tone: .info,
                isLoading: true,
                autoDismiss: false
            )
        }
        do {
            let currentSettings = settings
            await Task.yield()
            setProgress(
                title: l10n.text("扫描本地历史", "Scanning local history"),
                detail: l10n.text("正在比对 SQLite、rollout 和 session_index。", "Comparing SQLite, rollout files, and session_index."),
                fraction: 0.42
            )
            let result = try await Task.detached(priority: .userInitiated) {
                try CodexRepairService().scan(settings: currentSettings)
            }.value
            setProgress(
                title: l10n.text("整理修复预览", "Preparing repair preview"),
                detail: l10n.text("正在生成备份和写入预览。", "Preparing backup and write preview."),
                fraction: 0.86
            )
            scanResult = result
            status = .ready
            lastScanAt = Date()
            progress = nil
            if showFeedback {
                let count = pendingRepairCount
                showNotice(
                    title: l10n.text("扫描完成", "Scan Complete"),
                    message: count == 0
                        ? l10n.text("侧边栏会话摘要状态正常。", "Sidebar conversation summaries look healthy.")
                        : l10n.text("发现 \(count) 项待处理，请查看修复方案。", "Found \(count) items. Review the repair plan."),
                    tone: count == 0 ? .success : .warning
                )
            }
        } catch {
            status = .failed(error.localizedDescription)
            progress = nil
            showNotice(
                title: l10n.text("扫描失败", "Scan Failed"),
                message: error.localizedDescription,
                tone: .warning
            )
        }
    }

    func repairNow() async {
        guard !isBusy else { return }
        guard let scanResult else {
            status = .failed(CodexRepairError.noScanResult.localizedDescription)
            return
        }
        do {
            status = .repairing(l10n.text("正在创建备份", "Creating backup"))
            setProgress(
                title: l10n.text("准备备份", "Preparing backup"),
                detail: l10n.text("正在确认 Codex 已退出并准备回滚数据。", "Checking that Codex is closed and preparing rollback data."),
                fraction: 0.12
            )
            showNotice(
                title: l10n.text("正在备份并修复", "Backing Up and Repairing"),
                message: l10n.text("请稍候，完成前不要退出应用。", "Please wait and keep this app open."),
                tone: .info,
                isLoading: true,
                autoDismiss: false
            )
            let currentSettings = settings
            let mode = selectedBackupMode
            await Task.yield()
            setProgress(
                title: l10n.text("写入修复项", "Writing repairs"),
                detail: l10n.text("正在创建备份并写入 SQLite、rollout 和索引。", "Creating backup and writing SQLite, rollout, and index changes."),
                fraction: 0.48
            )
            _ = try await Task.detached(priority: .userInitiated) {
                try CodexRepairService().repair(scan: scanResult, settings: currentSettings, mode: mode)
            }.value
            status = .success(l10n.text("修复完成", "Repair complete"))
            setProgress(
                title: l10n.text("复核结果", "Verifying result"),
                detail: l10n.text("正在重新扫描确认修复收敛。", "Scanning again to verify the repair converged."),
                fraction: 0.82
            )
            self.scanResult = try await Task.detached(priority: .userInitiated) {
                try CodexRepairService().scan(settings: currentSettings)
            }.value
            lastScanAt = Date()
            progress = nil
            showNotice(
                title: l10n.text("修复完成", "Repair Complete"),
                message: l10n.text("侧边栏会话摘要已修复，并已创建备份。", "Sidebar conversation summaries were repaired and backed up."),
                tone: .success
            )
            if settings.openCodexAfterRepair {
                service.openCodex()
            }
        } catch CodexRepairError.codexIsRunning {
            showingCodexRunningAlert = true
            status = .failed(CodexRepairError.codexIsRunning.localizedDescription)
            progress = nil
            showNotice(title: l10n.text("需要先退出 Codex", "Quit Codex First"), message: CodexRepairError.codexIsRunning.localizedDescription, tone: .warning)
        } catch {
            status = .failed(error.localizedDescription)
            progress = nil
            showNotice(title: l10n.text("修复失败", "Repair Failed"), message: error.localizedDescription, tone: .warning)
        }
    }

    func repairPaginated(_ repair: PaginatedProviderRepair) async {
        guard !isBusy, let scanResult else { return }
        do {
            status = .repairing(l10n.text("正在修复分页 Provider", "Repairing paginated Provider"))
            setProgress(
                title: l10n.text("准备一致性试写", "Preparing consistency trial"),
                detail: l10n.text("正在验证 rollout 首行、history_base、turn 偏移和 projection 状态。", "Checking rollout headers, history_base, turn offsets, and projection state."),
                fraction: 0.28
            )
            showNotice(
                title: l10n.text("正在修复分页 Provider", "Repairing paginated Provider"),
                message: l10n.text("先备份并在副本验证全部偏移，完成前不要退出应用。", "Backing up and validating every offset on copies. Keep the app open."),
                tone: .info,
                isLoading: true,
                autoDismiss: false
            )
            let captured = settings
            let mode = selectedBackupMode
            await Task.yield()
            setProgress(
                title: l10n.text("提交分页修复", "Applying paginated repair"),
                detail: l10n.text("只改 session metadata 与必要的 SQLite 偏移字段，正文保持不变。", "Updating session metadata and required SQLite offsets; message bodies stay unchanged."),
                fraction: 0.62
            )
            _ = try await Task.detached(priority: .userInitiated) {
                try CodexRepairService().repairPaginated(repair, scan: scanResult, settings: captured, mode: mode)
            }.value
            setProgress(
                title: l10n.text("复核分页读取状态", "Verifying paginated state"),
                detail: l10n.text("正在重新扫描确认 Provider 与偏移全部收敛。", "Rescanning to confirm Provider and offsets converged."),
                fraction: 0.86
            )
            self.scanResult = try await Task.detached(priority: .userInitiated) {
                try CodexRepairService().scan(settings: captured)
            }.value
            status = .success(l10n.text("分页 Provider 修复完成", "Paginated Provider repair complete"))
            lastScanAt = Date()
            progress = nil
            showNotice(
                title: l10n.text("分页 Provider 修复完成", "Paginated Provider repair complete"),
                message: l10n.text("已备份并重算关联偏移；仍需重新打开对话和重启 Codex 完成人工正文验收。", "Offsets were recalculated and backed up; reopen the chat and restart Codex for final body verification."),
                tone: .success
            )
            if settings.openCodexAfterRepair { service.openCodex() }
        } catch CodexRepairError.codexIsRunning {
            showingCodexRunningAlert = true
            status = .failed(CodexRepairError.codexIsRunning.localizedDescription)
            progress = nil
            showNotice(title: l10n.text("需要先退出 Codex", "Quit Codex First"), message: CodexRepairError.codexIsRunning.localizedDescription, tone: .warning)
        } catch {
            status = .failed(error.localizedDescription)
            progress = nil
            showNotice(title: l10n.text("分页修复失败", "Paginated Repair Failed"), message: error.localizedDescription, tone: .warning)
        }
    }

    func restore(_ backup: BackupRecord) async {
        guard !isBusy else { return }
        do {
            status = .repairing(l10n.text("正在恢复备份", "Restoring backup"))
            setProgress(
                title: l10n.text("恢复备份", "Restoring backup"),
                detail: l10n.text("正在还原 SQLite、session_index 和 rollout metadata。", "Restoring SQLite, session_index, and rollout metadata."),
                fraction: 0.32
            )
            showNotice(
                title: l10n.text("正在恢复备份", "Restoring Backup"),
                message: l10n.text("正在恢复状态文件和 rollout metadata。", "Restoring state files and rollout metadata."),
                tone: .info,
                isLoading: true,
                autoDismiss: false
            )
            let currentSettings = settings
            try await Task.detached(priority: .userInitiated) {
                try CodexRepairService().restore(backup: backup)
            }.value
            status = .success(l10n.text("备份已恢复", "Backup restored"))
            setProgress(
                title: l10n.text("复核结果", "Verifying result"),
                detail: l10n.text("正在重新扫描恢复后的状态。", "Scanning the restored state."),
                fraction: 0.82
            )
            scanResult = try await Task.detached(priority: .userInitiated) {
                try CodexRepairService().scan(settings: currentSettings)
            }.value
            lastScanAt = Date()
            progress = nil
            showNotice(title: l10n.text("恢复完成", "Restore Complete"), message: l10n.text("备份已经恢复，可以重新打开 Codex。", "The backup is restored. You can reopen Codex."), tone: .success)
        } catch CodexRepairError.codexIsRunning {
            showingCodexRunningAlert = true
            status = .failed(CodexRepairError.codexIsRunning.localizedDescription)
            progress = nil
            showNotice(title: l10n.text("需要先退出 Codex", "Quit Codex First"), message: CodexRepairError.codexIsRunning.localizedDescription, tone: .warning)
        } catch {
            status = .failed(error.localizedDescription)
            progress = nil
            showNotice(title: l10n.text("恢复失败", "Restore Failed"), message: error.localizedDescription, tone: .warning)
        }
        showingRestoreConfirmation = false
        selectedBackupForRestore = nil
    }

    func openCodex() {
        service.openCodex()
        showNotice(title: l10n.text("正在打开 Codex", "Opening Codex"), message: l10n.text("已向系统发送打开请求。", "The open request was sent to macOS."), tone: .info)
    }

    func openBackupDirectory() {
        let root = service.backupRoot(codexHome: settings.codexHome)
        openExistingDirectory(root)
    }

    func openHistoryRecords() {
        openExistingDirectory(HistoryRepairService().backupRoot(settings: settings), history: true)
    }

    private func openExistingDirectory(_ root: URL, history: Bool = false) {
        var isDirectory: ObjCBool = false
        let message: String
        let opened: Bool
        if !FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            message = l10n.text("目录尚不存在：只有完成相应备份或修复后才会创建。", "This folder does not exist yet; it is created when a backup or repair is performed.") + "\n" + root.path
            opened = false
        } else {
            opened = NSWorkspace.shared.open(root)
            message = opened ? root.path : l10n.text("系统未能打开目录，请检查访问权限。", "The system could not open this folder. Check access permissions.") + "\n" + root.path
        }
        if history { historyMessage = message }
        showNotice(title: l10n.text(opened ? "目录已打开" : "未打开目录", opened ? "Folder Opened" : "Folder Not Opened"), message: message, tone: opened ? .info : .warning)
    }

    func refreshHistoryContext() {
        historyDatabases = []
        historyRecords = []
        do { historyDatabases = try HistoryRepairService().databaseCandidates(settings: settings) }
        catch { historyMessage = error.localizedDescription }
        // Repair records remain accessible even when database selection or scanning fails.
        do { historyRecords = try HistoryRepairService().records(settings: settings) }
        catch { historyMessage = error.localizedDescription }
    }

    func refreshBackups() async {
        guard !loadingBackups else { return }
        loadingBackups = true
        defer { loadingBackups = false }
        let home = settings.codexHome
        let inventory = await Task.detached(priority: .userInitiated) {
            BackupManagementService().inventory(codexHome: home)
        }.value
        guard home == settings.codexHome else { return }
        managedBackups = inventory.items
        backupWarnings = inventory.warnings
    }

    func deleteBackup(_ backup: ManagedBackup) async {
        guard !isBusy else { return }
        status = .repairing(l10n.text("移到废纸篓", "Moving to Trash"))
        let home = settings.codexHome
        do {
            try await Task.detached(priority: .userInitiated) {
                try BackupManagementService().delete(backup, codexHome: home)
            }.value
            scanResult?.backups.removeAll { $0.path == backup.directory.path }
            historyRecords.removeAll { $0.directory == backup.directory.path }
            selectedBackupForRestore = nil
            status = .ready
            await refreshBackups()
            showNotice(title: l10n.text("备份已移到废纸篓", "Backup Moved to Trash"),
                message: l10n.text("未改动当前对话。需要时可在 Finder 废纸篓中放回原目录，再刷新列表。", "Live chats were not changed. Put the backup back from Finder's Trash and refresh to recover it."), tone: .success)
        } catch {
            status = .failed(error.localizedDescription)
            showNotice(title: l10n.text("删除失败", "Deletion Failed"), message: error.localizedDescription, tone: .warning, autoDismiss: false)
        }
    }

    var pendingRepairCount: Int {
        guard let scanResult else { return 0 }
        return scanResult.sqliteProviderUpdates.count
            + scanResult.sqliteCompatibilityUpdates.count
            + scanResult.rolloutRepairs.count
            + scanResult.indexRepairs.count
            + scanResult.sqliteTimestampRepairs.count
            + scanResult.sqliteTitleRepairs.count
            + scanResult.rolloutMtimeRepairs.count
            + scanResult.paginatedProviderRepairs.count
            + (scanResult.globalStateRepair?.changes.count ?? 0)
    }

    var isBusy: Bool {
        switch status {
        case .scanning, .repairing:
            return true
        default:
            return false
        }
    }

    func dismissNotice() {
        dismissNoticeTask?.cancel()
        notice = nil
    }

    func scanHistory() async {
        guard !isBusy else { return }
        status = .scanning
        isHistoryScanning = true
        defer { isHistoryScanning = false }
        historyScan = nil
        historyMessage = nil
        refreshHistoryContext()
        let captured = settings
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try HistoryRepairService().scan(settings: captured)
            }.value
            guard captured.codexHome == settings.codexHome, captured.sqliteHome == settings.sqliteHome,
                  captured.historyDatabase == settings.historyDatabase else {
                throw HistoryRepairError.stale
            }
            historyScan = result
            status = .ready
            historyMessage = l10n.text("扫描完成：检查了 \(result.diagnoses.count) 个分页对话，\(result.diagnoses.filter(\.canRepair).count) 个入口可修复。", "Scan complete: \(result.diagnoses.count) paginated chats checked; \(result.diagnoses.filter(\.canRepair).count) entrypoints can be repaired.")
        } catch {
            status = .failed(error.localizedDescription)
            historyMessage = error.localizedDescription
            showNotice(title: l10n.text("对话扫描未完成", "Chat Scan Incomplete"), message: error.localizedDescription, tone: .warning)
        }
    }

    func repairHistory(_ diagnosis: HistoryDiagnosis) async {
        guard !isBusy, let scan = historyScan else { return }
        status = .repairing("Entrypoint")
        let captured = settings
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try HistoryRepairService().repair(diagnosis, scan: scan, settings: captured)
            }.value
            status = .ready
            await scanHistory()
            let rescanFailure = historyMessage
            historyMessage = l10n.text(
                "入口已修复：数据库副本试写、所有字段与原文件 SHA-256 校验通过。尚未验证客户端逐条读取；请重新打开对话，再正常退出并重启 Codex 检查。",
                "Entrypoint repaired: database-copy trial, metadata and source SHA-256 checks passed. Client message-by-message reading is NOT verified. Reopen the chat, then quit and restart Codex to check persistence.")
            if let rescanFailure { historyMessage? += "\n" + rescanFailure }
            scanResult = nil
        } catch {
            status = .failed(error.localizedDescription)
            historyMessage = error.localizedDescription
        }
    }

    func rollbackHistory(_ record: HistoryRepairRecord) async {
        guard !isBusy else { return }
        status = .repairing("Rollback")
        let captured = settings
        do {
            try await Task.detached(priority: .userInitiated) {
                try HistoryRepairService().rollback(record, settings: captured)
            }.value
            status = .ready
            await scanHistory()
            let rescanFailure = historyMessage
            historyMessage = l10n.text("仅本次入口修改已撤销，未覆盖其他会话或整库。", "Only this entrypoint change was reverted; other chats and the database were not replaced.")
            if let rescanFailure { historyMessage? += "\n" + rescanFailure }
            scanResult = nil
        } catch {
            status = .failed(error.localizedDescription)
            historyMessage = error.localizedDescription
        }
    }

    private func setProgress(title: String, detail: String, fraction: Double?) {
        progress = OperationProgress(title: title, detail: detail, fraction: fraction)
    }

    private func showNotice(
        title: String,
        message: String,
        tone: NoticeTone,
        isLoading: Bool = false,
        autoDismiss: Bool = true
    ) {
        dismissNoticeTask?.cancel()
        let newNotice = AppNotice(title: title, message: message, tone: tone, isLoading: isLoading)
        notice = newNotice
        guard autoDismiss else { return }
        dismissNoticeTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, notice?.id == newNotice.id else { return }
            notice = nil
        }
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case home
    case pending
    case history
    case backups
    case settings

    var id: String { rawValue }
}
