import Foundation

public enum Language: String, CaseIterable, Identifiable, Sendable {
    case zh
    case en

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .zh: "中文"
        case .en: "English"
        }
    }
}

public enum BackupMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case lightweight
    case full

    public var id: String { rawValue }

    public var zhTitle: String {
        switch self {
        case .lightweight: "轻量备份"
        case .full: "全量备份"
        }
    }

    public var enTitle: String {
        switch self {
        case .lightweight: "Lightweight"
        case .full: "Full"
        }
    }
}

public enum ScanStatus: Equatable, Sendable {
    case idle
    case scanning
    case ready
    case repairing(String)
    case success(String)
    case failed(String)
}

public struct AppSettings: Sendable {
    public var language: Language
    public var codexHome: URL
    public var sqliteHome: URL?
    public var defaultBackupMode: BackupMode
    public var lightweightLimit: Int
    public var fullLimit: Int
    public var openCodexAfterRepair: Bool
    public var alignProvidersForVisibility: Bool

    public init(language: Language, codexHome: URL, sqliteHome: URL?, defaultBackupMode: BackupMode, lightweightLimit: Int, fullLimit: Int, openCodexAfterRepair: Bool, alignProvidersForVisibility: Bool = true) {
        self.language = language
        self.codexHome = codexHome
        self.sqliteHome = sqliteHome
        self.defaultBackupMode = defaultBackupMode
        self.lightweightLimit = lightweightLimit
        self.fullLimit = fullLimit
        self.openCodexAfterRepair = openCodexAfterRepair
        self.alignProvidersForVisibility = alignProvidersForVisibility
    }

    public static func load() -> AppSettings {
        let defaults = UserDefaults.standard
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let codexHomePath = defaults.string(forKey: "codexHome")
            ?? env["CODEX_HOME"]
            ?? home.appendingPathComponent(".codex").path
        let sqliteHomePath = defaults.string(forKey: "sqliteHome")
            ?? env["CODEX_SQLITE_HOME"]
        let language = Language(rawValue: defaults.string(forKey: "language") ?? "zh") ?? .zh
        let backupMode = BackupMode(rawValue: defaults.string(forKey: "defaultBackupMode") ?? "lightweight") ?? .lightweight

        return AppSettings(
            language: language,
            codexHome: URL(fileURLWithPath: codexHomePath).standardizedFileURL,
            sqliteHome: sqliteHomePath.map { URL(fileURLWithPath: $0).standardizedFileURL },
            defaultBackupMode: backupMode,
            lightweightLimit: max(defaults.integer(forKey: "lightweightLimit"), 5),
            fullLimit: max(defaults.integer(forKey: "fullLimit"), 3),
            openCodexAfterRepair: defaults.object(forKey: "openCodexAfterRepair") as? Bool ?? true,
            alignProvidersForVisibility: defaults.object(forKey: "alignProvidersForVisibility") as? Bool ?? true
        )
    }

    public func save() {
        let defaults = UserDefaults.standard
        defaults.set(language.rawValue, forKey: "language")
        defaults.set(codexHome.path, forKey: "codexHome")
        defaults.set(sqliteHome?.path, forKey: "sqliteHome")
        defaults.set(defaultBackupMode.rawValue, forKey: "defaultBackupMode")
        defaults.set(lightweightLimit, forKey: "lightweightLimit")
        defaults.set(fullLimit, forKey: "fullLimit")
        defaults.set(openCodexAfterRepair, forKey: "openCodexAfterRepair")
        defaults.set(alignProvidersForVisibility, forKey: "alignProvidersForVisibility")
    }
}

public struct ProviderInfo: Equatable, Sendable {
    public var provider: String
    public var authLabel: String
    public var configURL: URL

    public init(provider: String, authLabel: String, configURL: URL) {
        self.provider = provider
        self.authLabel = authLabel
        self.configURL = configURL
    }
}

public struct StateDatabase: Identifiable, Equatable, Sendable {
    public var id: String { url.path }
    public var url: URL
    public var modifiedAt: Date

    public init(url: URL, modifiedAt: Date) {
        self.url = url
        self.modifiedAt = modifiedAt
    }
}

public struct ThreadRow: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var rolloutPath: String
    public var title: String
    public var modelProvider: String
    public var hasUserEvent: Bool
    public var cwd: String
    public var source: String
    public var threadSource: String?
    public var archived: Bool
    public var updatedAt: Int64
    public var updatedAtMs: Int64?
    public var firstUserMessage: String
    public var preview: String
    public var createdAt: Int64
    public var createdAtMs: Int64?
    public var recencyAt: Int64
    public var recencyAtMs: Int64?

    public var effectiveUpdatedAtMs: Int64 {
        if let updatedAtMs, updatedAtMs > 0 {
            return updatedAtMs
        }
        return updatedAt * 1000
    }

    public var effectiveCreatedAtMs: Int64 {
        if let createdAtMs, createdAtMs > 0 {
            return createdAtMs
        }
        return createdAt * 1000
    }

    public var effectiveRecencyAtMs: Int64? {
        if let recencyAtMs, recencyAtMs > 0 {
            return recencyAtMs
        }
        return recencyAt > 0 ? recencyAt * 1000 : nil
    }

    public init(id: String, rolloutPath: String, title: String, modelProvider: String, hasUserEvent: Bool, cwd: String, source: String, threadSource: String?, archived: Bool, updatedAt: Int64, updatedAtMs: Int64?, firstUserMessage: String, preview: String, createdAt: Int64 = 0, createdAtMs: Int64? = nil, recencyAt: Int64 = 0, recencyAtMs: Int64? = nil) {
        self.id = id
        self.rolloutPath = rolloutPath
        self.title = title
        self.modelProvider = modelProvider
        self.hasUserEvent = hasUserEvent
        self.cwd = cwd
        self.source = source
        self.threadSource = threadSource
        self.archived = archived
        self.updatedAt = updatedAt
        self.updatedAtMs = updatedAtMs
        self.firstUserMessage = firstUserMessage
        self.preview = preview
        self.createdAt = createdAt
        self.createdAtMs = createdAtMs
        self.recencyAt = recencyAt
        self.recencyAtMs = recencyAtMs
    }
}

public struct ProviderRepair: Identifiable, Equatable, Codable, Sendable {
    public var id: String { thread.id }
    public var thread: ThreadRow
    public var targetProvider: String

    public init(thread: ThreadRow, targetProvider: String) {
        self.thread = thread
        self.targetProvider = targetProvider
    }
}

public struct RolloutRepair: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var url: URL
    public var sessionID: String
    public var currentProvider: String?
    public var targetProvider: String
    public var originalFirstLine: String
    public var repairedFirstLine: String

    public init(id: String, url: URL, sessionID: String, currentProvider: String?, targetProvider: String, originalFirstLine: String, repairedFirstLine: String) {
        self.id = id
        self.url = url
        self.sessionID = sessionID
        self.currentProvider = currentProvider
        self.targetProvider = targetProvider
        self.originalFirstLine = originalFirstLine
        self.repairedFirstLine = repairedFirstLine
    }
}

public struct IndexRepair: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var threadID: String
    public var title: String
    public var updatedAtMs: Int64

    public init(threadID: String, title: String, updatedAtMs: Int64) {
        self.id = threadID
        self.threadID = threadID
        self.title = title
        self.updatedAtMs = updatedAtMs
    }
}

public struct TimestampRepair: Identifiable, Equatable, Codable, Sendable {
    public var id: String { threadID }
    public var threadID: String
    public var title: String
    public var currentUpdatedAtMs: Int64
    public var targetUpdatedAtMs: Int64
    public var currentCreatedAtMs: Int64?
    public var targetCreatedAtMs: Int64?

    public init(threadID: String, title: String, currentUpdatedAtMs: Int64, targetUpdatedAtMs: Int64, currentCreatedAtMs: Int64? = nil, targetCreatedAtMs: Int64? = nil) {
        self.threadID = threadID
        self.title = title
        self.currentUpdatedAtMs = currentUpdatedAtMs
        self.targetUpdatedAtMs = targetUpdatedAtMs
        self.currentCreatedAtMs = currentCreatedAtMs
        self.targetCreatedAtMs = targetCreatedAtMs
    }
}

public struct TitleRepair: Identifiable, Equatable, Codable, Sendable {
    public var id: String { threadID }
    public var threadID: String
    public var currentTitle: String
    public var targetTitle: String

    public init(threadID: String, currentTitle: String, targetTitle: String) {
        self.threadID = threadID
        self.currentTitle = currentTitle
        self.targetTitle = targetTitle
    }
}

public struct RolloutMtimeRepair: Identifiable, Equatable, Codable, Sendable {
    public var id: String { rolloutPath }
    public var threadID: String
    public var title: String
    public var rolloutPath: String
    public var currentMtimeMs: Int64
    public var targetMtimeMs: Int64

    public init(threadID: String, title: String, rolloutPath: String, currentMtimeMs: Int64, targetMtimeMs: Int64) {
        self.threadID = threadID
        self.title = title
        self.rolloutPath = rolloutPath
        self.currentMtimeMs = currentMtimeMs
        self.targetMtimeMs = targetMtimeMs
    }
}

public struct PaginatedProviderWarning: Identifiable, Equatable, Codable, Sendable {
    public var id: String { threadID }
    public var threadID: String
    public var title: String
    public var rolloutPath: String
    public var currentProvider: String
    public var targetProvider: String

    public init(threadID: String, title: String, rolloutPath: String, currentProvider: String, targetProvider: String) {
        self.threadID = threadID
        self.title = title
        self.rolloutPath = rolloutPath
        self.currentProvider = currentProvider
        self.targetProvider = targetProvider
    }
}

public struct PaginatedRolloutRepair: Identifiable, Equatable, Sendable {
    public var id: String { url.path }
    public var url: URL
    public var originalFirstLine: String
    public var repairedFirstLine: String
    public var originalByteLength: Int64
    public var repairedByteLength: Int64
    public var byteDelta: Int64 { repairedByteLength - originalByteLength }
    public var logicalID: String
    public var physicalID: String

    public init(url: URL, originalFirstLine: String, repairedFirstLine: String, originalByteLength: Int64, repairedByteLength: Int64, logicalID: String, physicalID: String) {
        self.url = url
        self.originalFirstLine = originalFirstLine
        self.repairedFirstLine = repairedFirstLine
        self.originalByteLength = originalByteLength
        self.repairedByteLength = repairedByteLength
        self.logicalID = logicalID
        self.physicalID = physicalID
    }
}

public struct PaginatedTurnOffsetRepair: Identifiable, Equatable, Sendable {
    public var id: String { "\(threadID):\(turnID)" }
    public var threadID: String
    public var turnID: String
    public var currentStartOffset: Int64
    public var targetStartOffset: Int64
    public var currentEndOffset: Int64?
    public var targetEndOffset: Int64?

    public init(threadID: String, turnID: String, currentStartOffset: Int64, targetStartOffset: Int64, currentEndOffset: Int64?, targetEndOffset: Int64?) {
        self.threadID = threadID
        self.turnID = turnID
        self.currentStartOffset = currentStartOffset
        self.targetStartOffset = targetStartOffset
        self.currentEndOffset = currentEndOffset
        self.targetEndOffset = targetEndOffset
    }
}

public struct PaginatedProjectionOffsetRepair: Identifiable, Equatable, Sendable {
    public var id: String { threadID }
    public var threadID: String
    public var currentOffset: Int64
    public var targetOffset: Int64

    public init(threadID: String, currentOffset: Int64, targetOffset: Int64) {
        self.threadID = threadID
        self.currentOffset = currentOffset
        self.targetOffset = targetOffset
    }
}

public struct PaginatedProviderRepair: Identifiable, Equatable, Sendable {
    public var id: String { threadID }
    public var threadID: String
    public var title: String
    public var targetProvider: String
    public var currentSQLiteProvider: String
    public var stateDatabase: URL
    public var historyDatabase: URL
    public var rolloutRepairs: [PaginatedRolloutRepair]
    public var turnOffsetRepairs: [PaginatedTurnOffsetRepair]
    public var projectionOffsetRepairs: [PaginatedProjectionOffsetRepair]

    public init(threadID: String, title: String, targetProvider: String, currentSQLiteProvider: String = "", stateDatabase: URL, historyDatabase: URL, rolloutRepairs: [PaginatedRolloutRepair], turnOffsetRepairs: [PaginatedTurnOffsetRepair], projectionOffsetRepairs: [PaginatedProjectionOffsetRepair]) {
        self.threadID = threadID
        self.title = title
        self.targetProvider = targetProvider
        self.currentSQLiteProvider = currentSQLiteProvider
        self.stateDatabase = stateDatabase
        self.historyDatabase = historyDatabase
        self.rolloutRepairs = rolloutRepairs
        self.turnOffsetRepairs = turnOffsetRepairs
        self.projectionOffsetRepairs = projectionOffsetRepairs
    }

    public var isMeaningful: Bool {
        !rolloutRepairs.isEmpty || !turnOffsetRepairs.isEmpty || !projectionOffsetRepairs.isEmpty
    }
}

public struct GlobalStateRepair: Equatable, Codable, Sendable {
    public var changes: [String]
    public var repairedJSON: String

    public init(changes: [String], repairedJSON: String) {
        self.changes = changes
        self.repairedJSON = repairedJSON
    }
}

public struct ScanResult: Equatable, Sendable {
    public var providerInfo: ProviderInfo
    public var stateDatabase: StateDatabase?
    public var threads: [ThreadRow]
    public var sqliteProviderUpdates: [ProviderRepair]
    public var sqliteCompatibilityUpdates: [ThreadRow]
    public var rolloutRepairs: [RolloutRepair]
    public var indexRepairs: [IndexRepair]
    public var sqliteTimestampRepairs: [TimestampRepair]
    public var sqliteTitleRepairs: [TitleRepair]
    public var rolloutMtimeRepairs: [RolloutMtimeRepair]
    public var paginatedProviderWarnings: [PaginatedProviderWarning]
    public var paginatedProviderRepairs: [PaginatedProviderRepair]
    public var paginatedProviderDiagnostics: [String]
    public var globalStateRepair: GlobalStateRepair?
    public var backups: [BackupRecord]
    public var codexHome: URL
    public var sqliteHome: URL
    public var lastRepairAt: Date?

    public var hasRepairs: Bool {
        !sqliteProviderUpdates.isEmpty ||
            !sqliteCompatibilityUpdates.isEmpty ||
            !rolloutRepairs.isEmpty ||
            !indexRepairs.isEmpty ||
            !sqliteTimestampRepairs.isEmpty ||
            !sqliteTitleRepairs.isEmpty ||
            !rolloutMtimeRepairs.isEmpty ||
            globalStateRepair != nil
    }

    public init(providerInfo: ProviderInfo, stateDatabase: StateDatabase?, threads: [ThreadRow], sqliteProviderUpdates: [ProviderRepair], sqliteCompatibilityUpdates: [ThreadRow], rolloutRepairs: [RolloutRepair], indexRepairs: [IndexRepair], sqliteTimestampRepairs: [TimestampRepair], sqliteTitleRepairs: [TitleRepair], rolloutMtimeRepairs: [RolloutMtimeRepair], paginatedProviderWarnings: [PaginatedProviderWarning] = [], paginatedProviderRepairs: [PaginatedProviderRepair] = [], paginatedProviderDiagnostics: [String] = [], globalStateRepair: GlobalStateRepair?, backups: [BackupRecord], codexHome: URL, sqliteHome: URL, lastRepairAt: Date?) {
        self.providerInfo = providerInfo
        self.stateDatabase = stateDatabase
        self.threads = threads
        self.sqliteProviderUpdates = sqliteProviderUpdates
        self.sqliteCompatibilityUpdates = sqliteCompatibilityUpdates
        self.rolloutRepairs = rolloutRepairs
        self.indexRepairs = indexRepairs
        self.sqliteTimestampRepairs = sqliteTimestampRepairs
        self.sqliteTitleRepairs = sqliteTitleRepairs
        self.rolloutMtimeRepairs = rolloutMtimeRepairs
        self.paginatedProviderWarnings = paginatedProviderWarnings
        self.paginatedProviderRepairs = paginatedProviderRepairs
        self.paginatedProviderDiagnostics = paginatedProviderDiagnostics
        self.globalStateRepair = globalStateRepair
        self.backups = backups
        self.codexHome = codexHome
        self.sqliteHome = sqliteHome
        self.lastRepairAt = lastRepairAt
    }
}

public struct RepairSummary: Codable, Equatable, Sendable {
    public var targetProvider: String
    public var sqliteProviderUpdates: Int
    public var sqliteCompatibilityUpdates: Int
    public var rolloutUpdates: Int
    public var indexInsertions: Int
    public var repairedAt: Date

    public init(targetProvider: String, sqliteProviderUpdates: Int, sqliteCompatibilityUpdates: Int, rolloutUpdates: Int, indexInsertions: Int, repairedAt: Date) {
        self.targetProvider = targetProvider
        self.sqliteProviderUpdates = sqliteProviderUpdates
        self.sqliteCompatibilityUpdates = sqliteCompatibilityUpdates
        self.rolloutUpdates = rolloutUpdates
        self.indexInsertions = indexInsertions
        self.repairedAt = repairedAt
    }
}

public struct BackupRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: String { directoryName }
    public var directoryName: String
    public var createdAt: Date
    public var mode: BackupMode
    public var targetProvider: String
    public var summary: RepairSummary
    public var sizeBytes: Int64
    public var path: String

    public init(directoryName: String, createdAt: Date, mode: BackupMode, targetProvider: String, summary: RepairSummary, sizeBytes: Int64, path: String) {
        self.directoryName = directoryName
        self.createdAt = createdAt
        self.mode = mode
        self.targetProvider = targetProvider
        self.summary = summary
        self.sizeBytes = sizeBytes
        self.path = path
    }
}
