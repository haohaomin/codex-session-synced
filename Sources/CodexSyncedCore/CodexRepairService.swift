import AppKit
import CryptoKit
import Foundation

public enum CodexRepairError: LocalizedError, Sendable {
    case noStateDatabase(URL)
    case codexIsRunning
    case noScanResult
    case noBackupManifest(URL)

    public var errorDescription: String? {
        switch self {
        case .noStateDatabase(let url): "未找到状态库：\(url.path)"
        case .codexIsRunning: "检测到 Codex 正在运行，请退出 Codex 后再修复。"
        case .noScanResult: "请先扫描待修复项。"
        case .noBackupManifest(let url): "未找到备份描述文件：\(url.path)"
        }
    }
}

public final class CodexRepairService {
    private let runningCheck: () -> Bool

    public convenience init() {
        self.init(isRunning: { Self.detectCodexRunning() })
    }

    init(isRunning: @escaping () -> Bool) {
        runningCheck = isRunning
    }

    public func isCodexRunning() -> Bool {
        runningCheck()
    }

    private static func detectCodexRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier == "com.openai.codex" || app.localizedName == "Codex"
        }
    }

    public func openCodex() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Codex.app"))
        }
    }

    public func openDirectory(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    public func scan(settings: AppSettings) throws -> ScanResult {
        let codexHome = CodexPathResolver.effectiveCodexHome(settings: settings)
        let configURL = codexHome.appendingPathComponent("config.toml")
        let parsedConfig = ConfigParser.parse(url: configURL)
        let sqliteHome = CodexPathResolver.effectiveSQLiteHome(settings: settings, parsedConfig: parsedConfig)
        let providerInfo = providerInfo(parsedConfig: parsedConfig, configURL: configURL)
        let state = latestStateDatabase(in: sqliteHome)

        var threads: [ThreadRow] = []
        if let state {
            let db = try SQLiteDatabase(path: state.url.path, readonly: true)
            threads = try db.queryThreads()
        }

        let rolloutInfo = SidebarRepairPlanner.rolloutInfoByPath(for: threads)
        let paginatedPlan = settings.alignProvidersForVisibility
            ? PaginatedProviderRepairService().scan(
                settings: settings,
                threads: threads,
                targetProvider: providerInfo.provider,
                stateDatabase: state?.url
            )
            : PaginatedProviderScan(repairs: [], warnings: [])
        let paginatedRepairIDs = Set(paginatedPlan.repairs.map(\.threadID))
        let paginatedProviderWarnings = settings.alignProvidersForVisibility
            ? SidebarRepairPlanner.paginatedProviderWarnings(
                threads: threads,
                rollouts: rolloutInfo,
                targetProvider: providerInfo.provider
            ).filter { !paginatedRepairIDs.contains($0.threadID) }
            : []
        let sqliteProviderUpdates: [ProviderRepair]
        let rolloutRepairs: [RolloutRepair]
        if settings.alignProvidersForVisibility {
            sqliteProviderUpdates = SidebarRepairPlanner.providerAlignmentRepairs(
                threads: threads,
                targetProvider: providerInfo.provider
            ).filter { !paginatedRepairIDs.contains($0.thread.id) }
            rolloutRepairs = SidebarRepairPlanner.rolloutProviderAlignmentRepairs(
                threads: threads,
                targetProvider: providerInfo.provider
            )
        } else {
            sqliteProviderUpdates = SidebarRepairPlanner.providerRepairs(threads: threads, rollouts: rolloutInfo)
            rolloutRepairs = []
        }
        let sqliteCompatibilityUpdates: [ThreadRow] = []
        let sqliteTimestampRepairs = SidebarRepairPlanner.timestampRepairs(threads: threads, rollouts: rolloutInfo)
        let sqliteTitleRepairs = SidebarRepairPlanner.titleRepairs(threads: threads)
        let rolloutMtimeRepairs = SidebarRepairPlanner.rolloutMtimeRepairs(threads: threads, rollouts: rolloutInfo)
        let projectedThreads = SidebarRepairPlanner.projectedThreads(
            threads: threads,
            titleRepairs: sqliteTitleRepairs,
            timestampRepairs: sqliteTimestampRepairs
        )
        let indexRepairs = SidebarRepairPlanner.indexRepairs(codexHome: codexHome, threads: projectedThreads)
        let globalStateRepair = SidebarRepairPlanner.globalStateRepair(codexHome: codexHome, threads: projectedThreads)
        let backups = loadBackups(codexHome: codexHome)
        let lastRepairAt = backups.sorted { $0.createdAt > $1.createdAt }.first?.createdAt

        return ScanResult(
            providerInfo: providerInfo,
            stateDatabase: state,
            threads: threads,
            sqliteProviderUpdates: sqliteProviderUpdates,
            sqliteCompatibilityUpdates: sqliteCompatibilityUpdates,
            rolloutRepairs: rolloutRepairs,
            indexRepairs: indexRepairs,
            sqliteTimestampRepairs: sqliteTimestampRepairs,
            sqliteTitleRepairs: sqliteTitleRepairs,
            rolloutMtimeRepairs: rolloutMtimeRepairs,
            paginatedProviderWarnings: paginatedProviderWarnings,
            paginatedProviderRepairs: paginatedPlan.repairs,
            paginatedProviderDiagnostics: paginatedPlan.warnings,
            globalStateRepair: globalStateRepair,
            backups: backups,
            codexHome: codexHome,
            sqliteHome: sqliteHome,
            lastRepairAt: lastRepairAt
        )
    }

    public func repair(scan: ScanResult, settings: AppSettings, mode: BackupMode) throws -> BackupRecord? {
        guard !isCodexRunning() else { throw CodexRepairError.codexIsRunning }
        guard let state = scan.stateDatabase else { throw CodexRepairError.noStateDatabase(scan.sqliteHome) }
        guard scan.hasRepairs else { return nil }

        let backup = try createBackup(scan: scan, settings: settings, mode: mode)
        let db = try SQLiteDatabase(path: state.url.path, readonly: false)
        try db.updateProviders(scan.sqliteProviderUpdates)
        try db.updateTimestamps(scan.sqliteTimestampRepairs)
        try db.updateTitles(scan.sqliteTitleRepairs)
        try db.updateCompatibility(threadIDs: scan.sqliteCompatibilityUpdates.map(\.id))
        for repair in scan.rolloutRepairs {
            try RolloutRepairer.apply(repair)
        }
        try SidebarRepairPlanner.applyRolloutMtimes(scan.rolloutMtimeRepairs)
        if let globalStateRepair = scan.globalStateRepair {
            try SidebarRepairPlanner.applyGlobalStateRepair(globalStateRepair, codexHome: scan.codexHome)
        }
        if !scan.indexRepairs.isEmpty {
            try SidebarRepairPlanner.rebuildSessionIndex(scan.indexRepairs, codexHome: scan.codexHome)
        }
        try rotateBackups(codexHome: scan.codexHome, mode: mode, limit: mode == .full ? settings.fullLimit : settings.lightweightLimit)
        return backup
    }

    /// Explicit second-stage operation for a fully planned paginated Provider
    /// repair. It is deliberately separate from repair(scan:) so the ordinary
    /// sidebar button can never leave a paginated thread half-updated.
    public func repairPaginated(_ repair: PaginatedProviderRepair, scan: ScanResult, settings: AppSettings, mode: BackupMode) throws -> BackupRecord {
        guard !isCodexRunning() else { throw CodexRepairError.codexIsRunning }
        guard let state = scan.stateDatabase,
              let thread = scan.threads.first(where: { $0.id == repair.threadID }),
              scan.paginatedProviderRepairs.first(where: { $0 == repair }) != nil else {
            throw HistoryRepairError.stale
        }
        let fresh = try self.scan(settings: settings)
        guard let current = fresh.paginatedProviderRepairs.first(where: { $0.threadID == repair.threadID }) else {
            throw HistoryRepairError.stale
        }
        guard current == repair else { throw HistoryRepairError.stale }

        let extraURLs = repair.rolloutRepairs.map(\.url)
        let backup = try createBackup(scan: scan, settings: settings, mode: mode, extraRolloutURLs: extraURLs)
        let backupURL = URL(fileURLWithPath: backup.path)
        let trialRoot = backupURL.appendingPathComponent("paginated-trial", isDirectory: true)
        try FileUtilities.ensureDirectory(trialRoot)
        defer { try? FileManager.default.removeItem(at: trialRoot) }

        let stateSnapshot = trialRoot.appendingPathComponent("state.sqlite")
        let historySnapshot = trialRoot.appendingPathComponent("thread_history.sqlite")
        let trialRollouts = trialRoot.appendingPathComponent("rollouts", isDirectory: true)
        try FileUtilities.ensureDirectory(trialRollouts)
        try SQLiteDatabase(path: state.url.path, readonly: true).backup(to: stateSnapshot)
        try SQLiteDatabase(path: repair.historyDatabase.path, readonly: true).backup(to: historySnapshot)
        let providerRepair = ProviderRepair(thread: thread, targetProvider: repair.targetProvider)
        let trialState = try SQLiteDatabase(path: stateSnapshot.path, readonly: false)
        try trialState.updateProvidersCompareAndSwap([providerRepair])
        let trialHistory = try SQLiteDatabase(path: historySnapshot.path, readonly: false)
        try trialHistory.updatePaginatedTurnOffsets(repair.turnOffsetRepairs)
        for projection in repair.projectionOffsetRepairs { try trialHistory.updatePaginatedProjectionOffset(projection) }

        let trialFiles = try repair.rolloutRepairs.enumerated().map { index, item -> PaginatedRolloutRepair in
            let destinationDirectory = trialRollouts.appendingPathComponent(String(format: "%03d-%@", index, item.physicalID), isDirectory: true)
            try FileUtilities.ensureDirectory(destinationDirectory)
            let destination = destinationDirectory.appendingPathComponent(item.url.lastPathComponent)
            try FileManager.default.copyItem(at: item.url, to: destination)
            var copy = item
            copy.url = destination
            return copy
        }
        let trialRepair = PaginatedProviderRepair(threadID: repair.threadID, title: repair.title, targetProvider: repair.targetProvider, currentSQLiteProvider: repair.currentSQLiteProvider, stateDatabase: stateSnapshot, historyDatabase: historySnapshot, rolloutRepairs: trialFiles, turnOffsetRepairs: repair.turnOffsetRepairs, projectionOffsetRepairs: repair.projectionOffsetRepairs)
        let planner = PaginatedProviderRepairService()
        try planner.applyRollouts(trialRepair)
        try SQLiteDatabase(path: stateSnapshot.path, readonly: true).checkIntegrity()
        try SQLiteDatabase(path: historySnapshot.path, readonly: true).checkIntegrity()

        var bodyHashes: [String: Data] = [:]
        for item in repair.rolloutRepairs { bodyHashes[item.url.standardizedFileURL.path] = try rolloutBodyHash(item.url) }
        do {
            try planner.applyRollouts(repair)
            try SQLiteDatabase(path: state.url.path, readonly: false).updateProvidersCompareAndSwap([providerRepair])
            let history = try SQLiteDatabase(path: repair.historyDatabase.path, readonly: false)
            try history.updatePaginatedTurnOffsets(repair.turnOffsetRepairs)
            for projection in repair.projectionOffsetRepairs { try history.updatePaginatedProjectionOffset(projection) }
            for item in repair.rolloutRepairs {
                guard try rolloutBodyHash(item.url) == bodyHashes[item.url.standardizedFileURL.path] else {
                    throw HistoryRepairError.unsafe("rollout 正文发生变化 / Rollout body changed")
                }
            }
            let verified = try self.scan(settings: settings)
            guard !verified.paginatedProviderRepairs.contains(where: { $0.threadID == repair.threadID }) else {
                throw HistoryRepairError.unsafe("分页 Provider 修复未收敛 / Paginated Provider repair did not converge")
            }
        } catch {
            try? restore(backup: backup)
            throw error
        }
        try rotateBackups(codexHome: scan.codexHome, mode: mode, limit: mode == .full ? settings.fullLimit : settings.lightweightLimit)
        return backup
    }

    public func restore(backup: BackupRecord) throws {
        guard !isCodexRunning() else { throw CodexRepairError.codexIsRunning }
        let backupURL = URL(fileURLWithPath: backup.path)
        let manifestURL = backupURL.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw CodexRepairError.noBackupManifest(manifestURL)
        }
        let manifest = try JSONDecoder.codexSynced.decode(BackupManifest.self, from: data)
        let fm = FileManager.default
        for item in manifest.files {
            let source = backupURL.appendingPathComponent(item.backupRelativePath)
            let destination = URL(fileURLWithPath: item.originalPath)
            try FileUtilities.ensureDirectory(destination.deletingLastPathComponent())
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: source, to: destination)
        }
        for item in manifest.rolloutFirstLines {
            try RolloutRepairer.restore(url: URL(fileURLWithPath: item.originalPath), firstLine: item.firstLine)
        }
        if let rolloutMtimes = manifest.rolloutMtimes {
            try SidebarRepairPlanner.restoreRolloutMtimes(rolloutMtimes)
        }
    }

    private func providerInfo(parsedConfig: ParsedConfig, configURL: URL) -> ProviderInfo {
        let provider = parsedConfig.rootValues["model_provider"].flatMap { $0.isEmpty ? nil : $0 } ?? "openai"
        let section = parsedConfig.providerSections[provider] ?? [:]
        let authLabel: String
        if provider == "openai" {
            authLabel = section["requires_openai_auth"] == "false" ? "OpenAI API Key" : "OpenAI OAuth"
        } else if section["requires_openai_auth"] == "true" {
            authLabel = "第三方 API"
        } else {
            authLabel = "自定义 Provider"
        }
        return ProviderInfo(provider: provider, authLabel: authLabel, configURL: configURL)
    }

    private func latestStateDatabase(in sqliteHome: URL) -> StateDatabase? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sqliteHome, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        let states = files.filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
        return states.compactMap { url in
            let modifiedAt = CodexPathResolver.stateDatabaseActivityDate(url)
            return StateDatabase(url: url, modifiedAt: modifiedAt)
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
        .first
    }

    private func rolloutBodyHash(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            if let newline = pending.firstIndex(of: 10) {
                try handle.seek(toOffset: UInt64(newline + 1))
                break
            }
        }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { digest.update(data: chunk) }
        return Data(digest.finalize())
    }

}

struct BackupManifest: Codable {
    struct FileItem: Codable {
        var originalPath: String
        var backupRelativePath: String
    }

    struct FirstLineItem: Codable {
        var originalPath: String
        var firstLine: String
    }

    struct MtimeItem: Codable {
        var originalPath: String
        var modifiedAtMs: Int64
    }

    var record: BackupRecord
    var files: [FileItem]
    /// Consolidated SQLite Backup API snapshots. These are evidence/verification
    /// artifacts and are intentionally not copied over the live database on restore.
    var sqliteSnapshots: [FileItem]?
    var rolloutFirstLines: [FirstLineItem]
    var rolloutMtimes: [MtimeItem]?
}

extension JSONEncoder {
    static var codexSynced: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var codexSynced: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
