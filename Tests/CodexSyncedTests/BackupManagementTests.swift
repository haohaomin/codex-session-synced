import Foundation
import Testing
@testable import CodexSyncedCore

struct BackupManagementTests {
    private func fixture() throws -> (URL, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("backup-delete-test-\(UUID())").standardizedFileURL
        let directory = home.appendingPathComponent("codex-synced-backups/lightweight-fixture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = RepairSummary(targetProvider: "custom", sqliteProviderUpdates: 1, sqliteCompatibilityUpdates: 0, rolloutUpdates: 0, indexInsertions: 0, repairedAt: date)
        let record = BackupRecord(directoryName: directory.lastPathComponent, createdAt: date, mode: .lightweight, targetProvider: "custom", summary: summary, sizeBytes: 0, path: directory.path)
        let manifest = BackupManifest(record: record, files: [], sqliteSnapshots: [], rolloutFirstLines: [], rolloutMtimes: [])
        try JSONEncoder.codexSynced.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
        try Data("untouched live messages".utf8).write(to: home.appendingPathComponent("live.jsonl"))
        return (home, directory)
    }

    @Test func inventoryIsReadOnlyAndDeleteMovesOnlyConfirmedBackup() throws {
        let (home, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let bytes = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let trash = home.appendingPathComponent("test-trash")
        let manager = BackupManagementService(trashItem: { try FileManager.default.moveItem(at: $0, to: trash) })
        let item = try #require(manager.inventory(codexHome: home).items.first)
        #expect(FileManager.default.fileExists(atPath: directory.path)) // Opening/cancelling a preview does nothing.
        #expect(try Data(contentsOf: directory.appendingPathComponent("manifest.json")) == bytes)
        try manager.delete(item, codexHome: home)
        #expect(manager.inventory(codexHome: home).items.isEmpty)
        #expect(try Data(contentsOf: trash.appendingPathComponent("manifest.json")) == bytes)
        #expect(try String(contentsOf: home.appendingPathComponent("live.jsonl"), encoding: .utf8) == "untouched live messages")
        try FileManager.default.moveItem(at: trash, to: directory)
        #expect(manager.inventory(codexHome: home).items.count == 1)
    }

    @Test func rejectsStaleManifestAndChangedHome() throws {
        let (home, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = BackupManagementService(trashItem: { _ in Issue.record("Unsafe delete reached Trash") })
        let item = try #require(manager.inventory(codexHome: home).items.first)
        #expect(throws: (any Error).self) { try manager.delete(item, codexHome: home.appendingPathComponent("other")) }
        let manifest = directory.appendingPathComponent("manifest.json")
        var data = try Data(contentsOf: manifest)
        data.append(10)
        try data.write(to: manifest)
        #expect(throws: (any Error).self) { try manager.delete(item, codexHome: home) }
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func trashFailureHasNoPermanentDeletionFallback() throws {
        let (home, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = BackupManagementService(trashItem: { _ in throw CocoaError(.fileWriteNoPermission) })
        let item = try #require(manager.inventory(codexHome: home).items.first)
        #expect(throws: (any Error).self) { try manager.delete(item, codexHome: home) }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path))
    }

    @Test func rejectsRootDirectoryForgedManifestAndSymlinks() throws {
        let (home, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = BackupManagementService(trashItem: { _ in Issue.record("Unsafe delete reached Trash") })
        let item = try #require(manager.inventory(codexHome: home).items.first)
        let root = directory.deletingLastPathComponent()
        let forged = ManagedBackup(directory: root, kind: .ordinary, createdAt: item.createdAt, title: item.title,
            backup: item.backup, historyRecord: nil, manifestHash: item.manifestHash, fileNumber: item.fileNumber)
        #expect(throws: (any Error).self) { try manager.delete(forged, codexHome: home) }
        let destination = home.appendingPathComponent("outside")
        try FileManager.default.moveItem(at: directory, to: destination)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: destination)
        #expect(manager.inventory(codexHome: home).items.isEmpty)
        #expect(!manager.inventory(codexHome: home).warnings.isEmpty)
        #expect(throws: (any Error).self) { try manager.delete(item, codexHome: home) }
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func symlinkedManifestAndRootAreNeverListed() throws {
        let (home, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let manifest = directory.appendingPathComponent("manifest.json")
        let outside = home.appendingPathComponent("outside.json")
        try FileManager.default.moveItem(at: manifest, to: outside)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: outside)
        let manager = BackupManagementService()
        #expect(manager.inventory(codexHome: home).items.isEmpty)
        let root = directory.deletingLastPathComponent()
        let moved = home.appendingPathComponent("moved-root")
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: moved)
        #expect(manager.inventory(codexHome: home).items.isEmpty)
    }
}
