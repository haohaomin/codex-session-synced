import AppKit
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
    public init() {}

    public func isCodexRunning() -> Bool {
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
        let paginatedProviderWarnings = settings.alignProvidersForVisibility
            ? SidebarRepairPlanner.paginatedProviderWarnings(
                threads: threads,
                rollouts: rolloutInfo,
                targetProvider: providerInfo.provider
            )
            : []
        let sqliteProviderUpdates: [ProviderRepair]
        let rolloutRepairs: [RolloutRepair]
        if settings.alignProvidersForVisibility {
            sqliteProviderUpdates = SidebarRepairPlanner.providerAlignmentRepairs(
                threads: threads,
                targetProvider: providerInfo.provider
            )
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
