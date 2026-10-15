import CryptoKit
import Foundation

public enum ManagedBackupKind: String, Sendable {
    case ordinary = "codex-synced-backups"
    case history = "history-entrypoint-backups"
}

/// Issued by a read-only inventory; deletion revalidates its location and manifest.
public struct ManagedBackup: Identifiable, Sendable {
    public var id: String { directory.path }
    public let directory: URL
    public let kind: ManagedBackupKind
    public let createdAt: Date
    public let title: String
    public let backup: BackupRecord?
    public let historyRecord: HistoryRepairRecord?
    let manifestHash: String
    let fileNumber: UInt64
}

public struct BackupInventory: Sendable {
    public let items: [ManagedBackup]
    public let warnings: [String]
}

public final class BackupManagementService {
    private let trashItem: (URL) throws -> Void

    public convenience init() {
        self.init(trashItem: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
    }

    init(trashItem: @escaping (URL) throws -> Void) { self.trashItem = trashItem }

    public func inventory(codexHome: URL) -> BackupInventory {
        var items: [ManagedBackup] = []
        var warnings: [String] = []
        for kind in [ManagedBackupKind.ordinary, .history] {
            let root = codexHome.appendingPathComponent(kind.rawValue).standardizedFileURL
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            do {
                try requireDirectory(root)
                for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                    do { items.append(try read(directory: directory, kind: kind, codexHome: codexHome)) }
                    catch { warnings.append("\(directory.lastPathComponent): \(error.localizedDescription)") }
                }
            } catch { warnings.append("\(root.path): \(error.localizedDescription)") }
        }
        return BackupInventory(items: items.sorted { $0.createdAt > $1.createdAt }, warnings: warnings)
    }

    /// Never calls removeItem; if the OS Trash operation fails there is no destructive fallback.
    public func delete(_ item: ManagedBackup, codexHome: URL) throws {
        let fresh = try read(directory: item.directory, kind: item.kind, codexHome: codexHome)
        guard fresh.manifestHash == item.manifestHash, fresh.fileNumber == item.fileNumber else {
            throw HistoryRepairError.unsafe("备份已变化，请刷新后重新确认。Backup changed; refresh and confirm again.")
        }
        try trashItem(fresh.directory)
    }

    private func requireDirectory(_ url: URL) throws {
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw HistoryRepairError.unsafe("拒绝符号链接或非目录。Symbolic links and non-directories are not allowed.")
        }
    }

    private func read(directory: URL, kind: ManagedBackupKind, codexHome: URL) throws -> ManagedBackup {
        let directory = directory.standardizedFileURL
        let root = codexHome.appendingPathComponent(kind.rawValue).standardizedFileURL
        guard directory.deletingLastPathComponent() == root else {
            throw HistoryRepairError.unsafe("只能删除当前备份目录内的一份备份。Only a direct backup under the current backup root may be deleted.")
        }
        try requireDirectory(root)
        try requireDirectory(directory)
        let manifestURL = directory.appendingPathComponent(kind == .ordinary ? "manifest.json" : "history-repair.json")
        guard try FileManager.default.attributesOfItem(atPath: manifestURL.path)[.type] as? FileAttributeType == .typeRegular else {
            throw HistoryRepairError.unsafe("备份描述文件无效。Invalid backup manifest.")
        }
        let data = try Data(contentsOf: manifestURL)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let number = (try FileManager.default.attributesOfItem(atPath: directory.path)[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        if kind == .ordinary {
            let manifest = try JSONDecoder.codexSynced.decode(BackupManifest.self, from: data)
            var record = manifest.record
            guard record.directoryName == directory.lastPathComponent,
                  URL(fileURLWithPath: record.path).standardizedFileURL == directory else {
                throw HistoryRepairError.unsafe("备份位置与记录不一致。Backup location does not match its manifest.")
            }
            record.sizeBytes = FileUtilities.directorySize(directory)
            return ManagedBackup(directory: directory, kind: kind, createdAt: record.createdAt,
                title: "\(record.mode.rawValue) · \(record.targetProvider)", backup: record, historyRecord: nil,
                manifestHash: hash, fileNumber: number)
        }
        let manifest = try JSONDecoder.codexSynced.decode(HistoryManifest.self, from: data)
        guard manifest.version == 1,
              URL(fileURLWithPath: manifest.record.directory).standardizedFileURL == directory,
              URL(fileURLWithPath: manifest.codexHome).standardizedFileURL == codexHome.standardizedFileURL else {
            throw HistoryRepairError.unsafe("修复记录位置无效。Invalid repair-record location.")
        }
        return ManagedBackup(directory: directory, kind: kind, createdAt: manifest.record.createdAt,
            title: manifest.record.title, backup: nil, historyRecord: manifest.record, manifestHash: hash, fileNumber: number)
    }
}
