import Foundation
import SQLite3
import Testing
@testable import CodexSyncedCore

struct HistoryRepairTests {
    @Test func scanIsReadOnlyAndExcludesSupersededMessages() throws {
        let f = try Fixture()
        defer { f.clean() }
        let before = try f.rows()
        let scan = try f.service.scan(settings: f.settings)
        let item = try #require(scan.diagnoses.first)
        #expect(item.canRepair)
        #expect(item.proposedPath.map { URL(fileURLWithPath: $0).standardizedFileURL } == f.child.standardizedFileURL)
        #expect(item.messageCount == 3) // retained user + replacement user + assistant
        #expect(try f.rows() == before)
        #expect(!FileManager.default.fileExists(atPath: f.service.backupRoot(settings: f.settings).path))
    }

    @Test func repairAndRollbackPreserveAllMetadataAndBytes() throws {
        let f = try Fixture()
        defer { f.clean() }
        let before = try f.rows()
        let rootBytes = try Data(contentsOf: f.original)
        let childBytes = try Data(contentsOf: f.child)
        let (scan, item) = try f.preview()
        let record = try f.service.repair(item, scan: scan, settings: f.settings)
        let after = try #require(f.rows().first)
        var expected = try #require(before.first)
        expected.fields["rollout_path"] = SQLiteField(type: SQLITE_TEXT, value: record.newPath)
        #expect(after == expected)
        #expect(try Data(contentsOf: f.original) == rootBytes)
        #expect(try Data(contentsOf: f.child) == childBytes)
        let snapshot = URL(fileURLWithPath: record.directory).appendingPathComponent("state-before.sqlite")
        #expect(try SQLiteDatabase(path: snapshot.path, readonly: true).entrypointRows() == before)
        #expect(try f.service.records(settings: f.settings).count == 1)
        #expect(try f.service.scan(settings: f.settings).diagnoses.first?.canRepair == false)
        try f.service.rollback(record, settings: f.settings)
        #expect(try f.rows() == before)
    }

    @Test func rejectsAmbiguousTipsInsteadOfChoosingNewest() throws {
        let f = try Fixture()
        defer { f.clean() }
        try Data(contentsOf: f.child).write(to: f.extraBranch())
        let result = try f.service.scan(settings: f.settings)
        #expect(result.diagnoses.first?.canRepair == false)
        #expect(result.diagnoses.first?.detail.contains("Ambiguous") == true)
    }

    @Test func byteOffsetMismatchIsDiagnosticOnly() throws {
        let f = try Fixture(offsetDelta: 50)
        defer { f.clean() }
        let result = try f.service.scan(settings: f.settings)
        #expect(result.diagnoses.first?.canRepair == false)
        #expect(result.diagnoses.first?.detail.contains("Byte boundary mismatch") == true)
    }

    @Test func rejectsDuplicateOrdinalsAndMalformedJSON() throws {
        for suffix in ["{\"ordinal\":4}\n", "not json\n"] {
            let f = try Fixture()
            defer { f.clean() }
            try f.append(suffix)
            #expect(try f.service.scan(settings: f.settings).diagnoses.first?.canRepair == false)
        }
    }

    @Test func missingParentAndCycleAreBlocked() throws {
        for parent in ["00000000-0000-0000-0000-000000000009", Fixture.branchID] {
            let f = try Fixture(parentID: parent)
            defer { f.clean() }
            #expect(try f.service.scan(settings: f.settings).diagnoses.first?.canRepair == false)
        }
    }

    @Test func missingOriginalIsBlocked() throws {
        let f = try Fixture()
        defer { f.clean() }
        try FileManager.default.removeItem(at: f.original)
        #expect(try f.service.scan(settings: f.settings).diagnoses.first?.canRepair == false)
    }

    @Test func staleMetadataPreventsRepair() throws {
        let f = try Fixture()
        defer { f.clean() }
        let (scan, item) = try f.preview()
        try f.sql("UPDATE threads SET project_id = 'new-project'")
        #expect(throws: HistoryRepairError.self) { try f.service.repair(item, scan: scan, settings: f.settings) }
        #expect(try f.rows().first?.path == f.original.path)
    }

    @Test func changedFileOrNewBranchPreventsRepair() throws {
        for addBranch in [false, true] {
            let f = try Fixture()
            defer { f.clean() }
            let (scan, item) = try f.preview()
            if addBranch { try Data(contentsOf: f.child).write(to: f.extraBranch()) }
            else { try f.append("{\"ordinal\":5,\"type\":\"event_msg\",\"payload\":{}}\n") }
            #expect(throws: HistoryRepairError.self) { try f.service.repair(item, scan: scan, settings: f.settings) }
            #expect(try f.rows().first?.path == f.original.path)
        }
    }

    @Test func rollbackNeverOverwritesNewActivity() throws {
        for change in 0..<3 {
            let f = try Fixture()
            defer { f.clean() }
            let (scan, item) = try f.preview()
            let record = try f.service.repair(item, scan: scan, settings: f.settings)
            switch change {
            case 0: try f.sql("UPDATE threads SET updated_at = 999")
            case 1: try f.append("{\"ordinal\":5,\"type\":\"event_msg\",\"payload\":{}}\n")
            default: try Data(contentsOf: f.child).write(to: f.extraBranch())
            }
            #expect(throws: HistoryRepairError.self) { try f.service.rollback(record, settings: f.settings) }
            #expect(try f.rows().first?.path == record.newPath)
        }
    }

    @Test func runningCodexPreventsBackupAndWrite() throws {
        let f = try Fixture()
        defer { f.clean() }
        let (scan, item) = try f.preview()
        let running = HistoryRepairService(isRunning: { true })
        #expect(throws: CodexRepairError.self) { try running.repair(item, scan: scan, settings: f.settings) }
        #expect(!FileManager.default.fileExists(atPath: running.backupRoot(settings: f.settings).path))
        #expect(try f.rows().first?.path == f.original.path)
    }

    @Test func failedPostWriteCheckRollsBackTransaction() throws {
        let f = try Fixture()
        defer { f.clean() }
        let db = try SQLiteDatabase(path: f.db.path, readonly: false)
        let row = try #require(db.entrypointRows().first)
        var count = 0
        #expect(throws: HistoryRepairError.self) {
            try db.changeEntrypoint(expected: row, to: f.child.path) {
                count += 1
                if count == 2 { throw HistoryRepairError.stale }
            }
        }
        #expect(try f.rows().first == row)
    }

    @Test func backupIncludesUncheckpointedWAL() throws {
        let f = try Fixture()
        defer { f.clean() }
        var writer: OpaquePointer?
        #expect(sqlite3_open(f.db.path, &writer) == SQLITE_OK)
        defer { sqlite3_close(writer) }
        #expect(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; UPDATE threads SET title='WAL title';", nil, nil, nil) == SQLITE_OK)
        let destination = f.home.appendingPathComponent("snapshot.sqlite")
        try SQLiteDatabase(path: f.db.path, readonly: true).backup(to: destination)
        let backup = try SQLiteDatabase(path: destination.path, readonly: true)
        #expect(try backup.entrypointRows().first?.title == "WAL title")
        try backup.checkIntegrity()
    }

    @Test func multipleDatabasesAndSymlinksFailClosed() throws {
        let f = try Fixture()
        defer { f.clean() }
        let other = f.home.appendingPathComponent("state_6.sqlite")
        try Data().write(to: other)
        #expect(throws: HistoryRepairError.self) { try f.service.scan(settings: f.settings) }
        try FileManager.default.removeItem(at: other)
        try FileManager.default.createSymbolicLink(at: f.extraBranch(), withDestinationURL: f.child)
        #expect(throws: HistoryRepairError.self) { try f.service.scan(settings: f.settings) }
    }

    @Test func unknownRolloutNamesBlockRepairs() throws {
        let f = try Fixture()
        defer { f.clean() }
        try Data().write(to: f.original.deletingLastPathComponent().appendingPathComponent("rollout-unknown.jsonl"))
        let scan = try f.service.scan(settings: f.settings)
        #expect(!scan.warnings.isEmpty)
        #expect(scan.diagnoses.first?.canRepair == false)
    }

    @Test func automaticDiscoveryDoesNotGuessBetweenRootAndNestedDatabases() throws {
        let f = try Fixture()
        defer { f.clean() }
        let nested = f.home.appendingPathComponent("sqlite")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("state_5.sqlite"))
        var settings = f.settings
        settings.sqliteHome = nil
        #expect(throws: HistoryRepairError.self) { try f.service.scan(settings: settings) }
        #expect(try f.service.scan(settings: f.settings).diagnoses.first?.canRepair == true)
    }

    @Test func triggersAreNotAllowedToCauseIncidentalWrites() throws {
        let f = try Fixture()
        defer { f.clean() }
        try f.sql("CREATE TRIGGER unexpected AFTER UPDATE ON threads BEGIN UPDATE threads SET title='bad'; END")
        let (scan, item) = try f.preview()
        #expect(throws: HistoryRepairError.self) { try f.service.repair(item, scan: scan, settings: f.settings) }
        #expect(try f.rows().first?.path == f.original.path)
    }

    @Test func sidebarProviderRepairNeverRewritesPaginatedHeaders() throws {
        let f = try Fixture()
        defer { f.clean() }
        #expect(RolloutRepairer.makeRepair(url: f.original, targetProvider: "custom") == nil)
        #expect(RolloutRepairer.makeRepair(url: f.child, targetProvider: "custom") == nil)
    }

    @Test func multilevelInheritanceUsesPhysicalParentID() throws {
        let f = try Fixture()
        defer { f.clean() }
        let child = try Data(contentsOf: f.child)
        let prefix = child.split(separator: 10).prefix(2).reduce(0) { $0 + $1.count + 1 }
        try """
        {"ordinal":4,"type":"session_meta","payload":{"id":"\(Fixture.threadID)","history_mode":"paginated","history_base":{"thread_id":"\(Fixture.branchID)","end_ordinal_exclusive":4,"end_byte_offset":\(prefix)}}}
        {"ordinal":5,"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"replacement answer"}]}}

        """.write(to: f.extraBranch(), atomically: true, encoding: .utf8)
        let (_, item) = try f.preview()
        #expect(item.messageCount == 3)
        #expect(item.files.count == 3)
        #expect(item.proposedPath.map { URL(fileURLWithPath: $0).lastPathComponent } == f.extraBranch().lastPathComponent)
    }

    @Test func endOfFileAndCRLFBoundariesAreByteAccurate() throws {
        let f = try Fixture()
        defer { f.clean() }
        let original = try String(contentsOf: f.original, encoding: .utf8)
        let root = original.split(separator: "\n").prefix(2).joined(separator: "\r\n") + "\r\n"
        try root.write(to: f.original, atomically: true, encoding: .utf8)
        var lines = try String(contentsOf: f.child, encoding: .utf8).split(separator: "\n").map(String.init)
        var header = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        var payload = try #require(header["payload"] as? [String: Any])
        var base = try #require(payload["history_base"] as? [String: Any])
        base["end_byte_offset"] = root.utf8.count
        payload["history_base"] = base
        header["payload"] = payload
        lines[0] = String(decoding: try JSONSerialization.data(withJSONObject: header), as: UTF8.self)
        try lines.joined(separator: "\r\n").write(to: f.child, atomically: true, encoding: .utf8)
        let (_, item) = try f.preview()
        #expect(item.messageCount == 3)
    }

    @Test func rollbackPreservesChangesToOtherThreads() throws {
        let f = try Fixture()
        defer { f.clean() }
        let (scan, item) = try f.preview()
        let record = try f.service.repair(item, scan: scan, settings: f.settings)
        try f.sql("INSERT INTO threads(id,rollout_path,title,history_mode) VALUES('other','/new/path','new conversation','legacy')")
        try f.service.rollback(record, settings: f.settings)
        #expect(try f.rows().first(where: { $0.id == "other" })?.title == "new conversation")
        #expect(try f.rows().first(where: { $0.id == Fixture.threadID })?.path == f.original.path)
    }

    private final class Fixture {
        static let threadID = "00000000-0000-0000-0000-000000000001"
        static let branchID = "00000000-0000-0000-0000-000000000002"
        let home: URL
        let db: URL
        let original: URL
        let child: URL
        let settings: AppSettings
        let service = HistoryRepairService(isRunning: { false })

        init(offsetDelta: Int = 0, parentID: String = threadID) throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("history-repair-test-\(UUID().uuidString)").standardizedFileURL
            let sessions = home.appendingPathComponent("sessions/2026/10/12")
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            db = home.appendingPathComponent("state_5.sqlite")
            original = sessions.appendingPathComponent("rollout-2026-10-12T00-00-00-\(Self.threadID).jsonl")
            child = sessions.appendingPathComponent("rollout-2026-10-12T00-01-00-\(Self.threadID)_\(Self.branchID).jsonl")
            settings = AppSettings(language: .zh, codexHome: home, sqliteHome: home, defaultBackupMode: .lightweight,
                lightweightLimit: 5, fullLimit: 3, openCodexAfterRepair: false)
            let rootPrefix = """
            {"ordinal":0,"type":"session_meta","payload":{"id":"\(Self.threadID)","history_mode":"paginated","model_provider":"openai"}}
            {"ordinal":1,"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"保留这条 🌲"}]}}

            """
            try (rootPrefix + "{\"ordinal\":2,\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[]}}\n").write(to: original, atomically: true, encoding: .utf8)
            try """
            {"ordinal":2,"type":"session_meta","payload":{"id":"\(Self.threadID)","history_mode":"paginated","history_base":{"thread_id":"\(parentID)","end_ordinal_exclusive":2,"end_byte_offset":\(rootPrefix.utf8.count + offsetDelta)}}}
            {"ordinal":3,"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"替换"}]}}
            {"ordinal":4,"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"答复"}]}}

            """.write(to: child, atomically: true, encoding: .utf8)
            try sql("""
            CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, title TEXT, name TEXT, history_mode TEXT, project_id TEXT, thread_section_id TEXT, cwd TEXT, archived INTEGER, updated_at INTEGER, extra BLOB);
            INSERT INTO threads VALUES('\(Self.threadID)', '\(original.path)', 'fixture', NULL, 'paginated', 'project-kept', NULL, '/project/original', 1, 123, X'0001FF');
            """)
        }

        func sql(_ sql: String) throws {
            var handle: OpaquePointer?
            guard sqlite3_open(db.path, &handle) == SQLITE_OK else { throw HistoryRepairError.unsafe("fixture open") }
            defer { sqlite3_close(handle) }
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                throw HistoryRepairError.unsafe(String(cString: sqlite3_errmsg(handle)))
            }
        }

        func rows() throws -> [EntrypointRow] { try SQLiteDatabase(path: db.path, readonly: true).entrypointRows() }
        func preview() throws -> (HistoryScan, HistoryDiagnosis) {
            let scan = try service.scan(settings: settings)
            return (scan, try #require(scan.diagnoses.first { $0.canRepair }))
        }
        func extraBranch() -> URL {
            child.deletingLastPathComponent().appendingPathComponent("rollout-2026-10-12T00-02-00-\(Self.threadID)_00000000-0000-0000-0000-000000000003.jsonl")
        }
        func append(_ text: String) throws {
            let handle = try FileHandle(forWritingTo: child)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        }
        func clean() {
            if ProcessInfo.processInfo.environment["CODEX_SYNCED_KEEP_TEST_FIXTURES"] == "1" {
                print("Isolated UI fixture: \(home.path)")
            } else {
                try? FileManager.default.removeItem(at: home)
            }
        }
    }
}
