import Foundation

extension CodexRepairService {
    func loadBackups(codexHome: URL) -> [BackupRecord] {
        let root = backupRoot(codexHome: codexHome)
        guard let directories = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        return directories.compactMap { directory in
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder.codexSynced.decode(BackupManifest.self, from: data) else {
                return nil
            }
            var record = manifest.record
            record.sizeBytes = FileUtilities.directorySize(directory)
            record.path = directory.path
            return record
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func createBackup(scan: ScanResult, settings: AppSettings, mode: BackupMode) throws -> BackupRecord {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directoryName = "\(mode.rawValue)-\(formatter.string(from: now))"
        let directory = backupRoot(codexHome: scan.codexHome).appendingPathComponent(directoryName)
        try FileUtilities.ensureDirectory(directory)

        let summary = RepairSummary(
            targetProvider: scan.providerInfo.provider,
            sqliteProviderUpdates: scan.sqliteProviderUpdates.count,
            sqliteCompatibilityUpdates: scan.sqliteCompatibilityUpdates.count,
            rolloutUpdates: scan.rolloutRepairs.count + scan.rolloutMtimeRepairs.count,
            indexInsertions: scan.indexRepairs.count,
            repairedAt: now
        )

        var files: [BackupManifest.FileItem] = []
        var sqliteSnapshots: [BackupManifest.FileItem] = []
        func copy(_ url: URL, relative: String) throws {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let destination = directory.appendingPathComponent(relative)
            try FileUtilities.ensureDirectory(destination.deletingLastPathComponent())
            try FileUtilities.copyIfExists(url, to: destination)
            files.append(.init(originalPath: url.path, backupRelativePath: relative))
        }

        // Keep the live database trio for exact rollback, and also create a
        // SQLite Backup API snapshot. The latter is the consistent WAL-aware
        // artifact used for independent integrity checks and incident review.
        let sqliteURLs = try sqliteBackupCandidates(in: scan.sqliteHome, active: scan.stateDatabase?.url)
        for sqliteURL in sqliteURLs {
            try copy(sqliteURL, relative: "sqlite/\(sqliteURL.lastPathComponent)")
            try copy(URL(fileURLWithPath: sqliteURL.path + "-wal"), relative: "sqlite/\(sqliteURL.lastPathComponent)-wal")
            try copy(URL(fileURLWithPath: sqliteURL.path + "-shm"), relative: "sqlite/\(sqliteURL.lastPathComponent)-shm")

            let snapshotRelative = "sqlite/snapshots/\(sqliteURL.lastPathComponent).snapshot.sqlite"
            let snapshotURL = directory.appendingPathComponent(snapshotRelative)
            try FileUtilities.ensureDirectory(snapshotURL.deletingLastPathComponent())
            let source = try SQLiteDatabase(path: sqliteURL.path, readonly: true)
            try source.backup(to: snapshotURL)
            sqliteSnapshots.append(.init(originalPath: sqliteURL.path, backupRelativePath: snapshotRelative))
        }
        try copy(scan.codexHome.appendingPathComponent("config.toml"), relative: "codex/config.toml")
        try copy(scan.codexHome.appendingPathComponent("session_index.jsonl"), relative: "codex/session_index.jsonl")
        try copy(scan.codexHome.appendingPathComponent(".codex-global-state.json"), relative: "codex/.codex-global-state.json")

        if mode == .full {
            try copyDirectoryIfExists(scan.codexHome.appendingPathComponent("sessions"), to: directory.appendingPathComponent("codex/sessions"))
            try copyDirectoryIfExists(scan.codexHome.appendingPathComponent("archived_sessions"), to: directory.appendingPathComponent("codex/archived_sessions"))
        }

        let firstLines = scan.rolloutRepairs.map {
            BackupManifest.FirstLineItem(originalPath: $0.url.path, firstLine: $0.originalFirstLine)
        }
        let mtimes = scan.rolloutMtimeRepairs.map {
            BackupManifest.MtimeItem(originalPath: $0.rolloutPath, modifiedAtMs: $0.currentMtimeMs)
        }
        let record = BackupRecord(
            directoryName: directoryName,
            createdAt: now,
            mode: mode,
            targetProvider: scan.providerInfo.provider,
            summary: summary,
            sizeBytes: 0,
            path: directory.path
        )
        let manifest = BackupManifest(record: record, files: files, sqliteSnapshots: sqliteSnapshots, rolloutFirstLines: firstLines, rolloutMtimes: mtimes)
        let manifestData = try JSONEncoder.codexSynced.encode(manifest)
        try manifestData.write(to: directory.appendingPathComponent("manifest.json"))

        var finalRecord = record
        finalRecord.sizeBytes = FileUtilities.directorySize(directory)
        let finalManifest = BackupManifest(record: finalRecord, files: files, sqliteSnapshots: sqliteSnapshots, rolloutFirstLines: firstLines, rolloutMtimes: mtimes)
        try JSONEncoder.codexSynced.encode(finalManifest).write(to: directory.appendingPathComponent("manifest.json"))
        return finalRecord
    }

    func rotateBackups(codexHome: URL, mode: BackupMode, limit: Int) throws {
        let backups = loadBackups(codexHome: codexHome).filter { $0.mode == mode }.sorted { $0.createdAt > $1.createdAt }
        guard backups.count > limit else { return }
        for backup in backups.dropFirst(limit) {
            try FileManager.default.removeItem(at: URL(fileURLWithPath: backup.path))
        }
    }

    public func backupRoot(codexHome: URL) -> URL {
        codexHome.appendingPathComponent("codex-synced-backups", isDirectory: true)
    }

    private func sqliteBackupCandidates(in home: URL, active: URL?) throws -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        let prefixes = ["state_", "thread_history_", "logs_"]
        let candidates = entries.filter { url in
            guard url.pathExtension == "sqlite",
                  prefixes.contains(where: { url.lastPathComponent.hasPrefix($0) }) else { return false }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != false
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        // The active state database is selected by scan() and must always be in
        // the snapshot set, even if a platform exposes unusual file attributes.
        if let active, !candidates.contains(where: { $0.standardizedFileURL == active.standardizedFileURL }) {
            return [active] + candidates
        }
        return candidates
    }

    private func copyDirectoryIfExists(_ source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileUtilities.ensureDirectory(destination.deletingLastPathComponent())
        try FileManager.default.copyItem(at: source, to: destination)
    }
}
