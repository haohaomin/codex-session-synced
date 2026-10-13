import Foundation
import SQLite3
import Testing
@testable import CodexSyncedCore

struct CodexSyncedCoreTests {
    @Test func rootModelProviderIgnoresNestedMCPProvider() throws {
        let directory = try makeTempDirectory()
        let config = directory.appendingPathComponent("config.toml")
        try """
        model = "gpt-5.5"

        [mcp_servers.example]
        model_provider = "openai_http"
        """.write(to: config, atomically: true, encoding: .utf8)

        let parsed = ConfigParser.parse(url: config)

        #expect(parsed.rootValues["model_provider"] == nil)
    }

    @Test func rootModelProviderReadsCustomProvider() throws {
        let directory = try makeTempDirectory()
        let config = directory.appendingPathComponent("config.toml")
        try """
        model_provider = "custom"

        [mcp_servers.example]
        model_provider = "openai_http"
        """.write(to: config, atomically: true, encoding: .utf8)

        let parsed = ConfigParser.parse(url: config)

        #expect(parsed.rootValues["model_provider"] == "custom")
    }

    @Test func sqliteHomePrefersNestedDirectoryWhenPresent() throws {
        let directory = try makeTempDirectory()
        let nested = directory.appendingPathComponent("sqlite")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("state_5.sqlite"))

        let settings = AppSettings(
            language: .zh,
            codexHome: directory,
            sqliteHome: nil,
            defaultBackupMode: .lightweight,
            lightweightLimit: 5,
            fullLimit: 3,
            openCodexAfterRepair: false
        )
        let parsed = ParsedConfig(rootValues: [:], providerSections: [:])

        #expect(CodexPathResolver.effectiveSQLiteHome(settings: settings, parsedConfig: parsed).path == nested.standardizedFileURL.path)
    }

    @Test func sqliteHomeChoosesNewestActiveDatabaseAcrossRootAndNested() throws {
        let directory = try makeTempDirectory()
        let nested = directory.appendingPathComponent("sqlite")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let rootState = directory.appendingPathComponent("state_5.sqlite")
        let nestedState = nested.appendingPathComponent("state_5.sqlite")
        try Data().write(to: rootState)
        try Data().write(to: nestedState)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: rootState.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 20)], ofItemAtPath: nestedState.path)

        let settings = AppSettings(
            language: .zh,
            codexHome: directory,
            sqliteHome: nil,
            defaultBackupMode: .lightweight,
            lightweightLimit: 5,
            fullLimit: 3,
            openCodexAfterRepair: false
        )
        let parsed = ParsedConfig(rootValues: [:], providerSections: [:])
        #expect(CodexPathResolver.effectiveSQLiteHome(settings: settings, parsedConfig: parsed).path == nested.path)

        let rootWal = URL(fileURLWithPath: rootState.path + "-wal")
        try Data().write(to: rootWal)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 30)], ofItemAtPath: rootWal.path)
        #expect(CodexPathResolver.effectiveSQLiteHome(settings: settings, parsedConfig: parsed).path == directory.path)
    }

    @Test func rolloutRepairOnlyChangesSessionMetaProvider() throws {
        let directory = try makeTempDirectory()
        let rollout = directory.appendingPathComponent("rollout-test.jsonl")
        try """
        {"type":"session_meta","payload":{"id":"abc","model_provider":"openai","cwd":"/tmp"}}
        {"type":"user_message","payload":{"text":"keep me"}}
        """.write(to: rollout, atomically: true, encoding: .utf8)

        guard let repair = RolloutRepairer.makeRepair(url: rollout, targetProvider: "custom") else {
            Issue.record("Expected rollout repair")
            return
        }
        try RolloutRepairer.apply(repair)
        let content = try String(contentsOf: rollout, encoding: .utf8)

        #expect(content.contains("\"model_provider\":\"custom\""))
        #expect(content.contains("\"text\":\"keep me\""))
    }

    @Test func rolloutRepairReadsLargeSessionMetaLine() throws {
        let directory = try makeTempDirectory()
        let rollout = directory.appendingPathComponent("rollout-large.jsonl")
        let instructions = String(repeating: "x", count: 160 * 1024)
        try """
        {"type":"session_meta","payload":{"id":"large","model_provider":"custom","base_instructions":{"text":"\(instructions)"}}}
        {"type":"user_message","payload":{"text":"keep me"}}
        """.write(to: rollout, atomically: true, encoding: .utf8)

        guard let repair = RolloutRepairer.makeRepair(url: rollout, targetProvider: "openai") else {
            Issue.record("Expected rollout repair for session metadata larger than 128 KB")
            return
        }
        try RolloutRepairer.apply(repair)
        let content = try String(contentsOf: rollout, encoding: .utf8)

        #expect(content.contains("\"model_provider\":\"openai\""))
        #expect(content.contains("\"text\":\"keep me\""))
    }

    @Test func rolloutRepairDoesNotDecodePastFirstLine() throws {
        let directory = try makeTempDirectory()
        let rollout = directory.appendingPathComponent("rollout-utf8-boundary.jsonl")
        let sessionMeta = #"{"type":"session_meta","payload":{"id":"utf8","model_provider":"custom"}}"#
        let prefixSize = sessionMeta.utf8.count + 1
        let secondLine = String(repeating: "x", count: 128 * 1024 - prefixSize - 1) + "你"
        try "\(sessionMeta)\n\(secondLine)\n".write(to: rollout, atomically: true, encoding: .utf8)

        let repair = RolloutRepairer.makeRepair(url: rollout, targetProvider: "openai")

        #expect(repair != nil)
    }

    @Test func sidebarProviderRepairUsesRolloutAsSourceOfTruth() throws {
        let directory = try makeTempDirectory()
        let rollout = directory.appendingPathComponent("rollout-provider.jsonl")
        try """
        {"timestamp":"2026-06-01T10:00:00.000Z","type":"session_meta","payload":{"id":"provider-test","model_provider":"openai","cwd":"\(directory.path)"}}
        """.write(to: rollout, atomically: true, encoding: .utf8)

        let thread = makeThread(
            id: "provider-test",
            rollout: rollout,
            title: "Provider test",
            provider: "custom",
            cwd: directory.path,
            firstUserMessage: "Provider test"
        )
        let info = SidebarRepairPlanner.rolloutInfoByPath(for: [thread])
        let repairs = SidebarRepairPlanner.providerRepairs(threads: [thread], rollouts: info)

        #expect(repairs.count == 1)
        #expect(repairs.first?.targetProvider == "openai")
    }

    @Test func providerAlignmentTargetsActiveProviderForSQLiteAndRollout() throws {
        let directory = try makeTempDirectory()
        let rollout = directory.appendingPathComponent("rollout-provider-align.jsonl")
        try """
        {"timestamp":"2026-06-01T10:00:00.000Z","type":"session_meta","payload":{"id":"provider-align","model_provider":"openai","cwd":"\(directory.path)"}}
        {"timestamp":"2026-06-01T10:01:00.000Z","type":"user_message","payload":{"text":"keep me"}}
        """.write(to: rollout, atomically: true, encoding: .utf8)

        let thread = makeThread(
            id: "provider-align",
            rollout: rollout,
            title: "Provider align",
            provider: "openai",
            cwd: directory.path,
            firstUserMessage: "Provider align",
            archived: true
        )
        let sqliteRepairs = SidebarRepairPlanner.providerAlignmentRepairs(threads: [thread], targetProvider: "custom")
        let rolloutRepairs = SidebarRepairPlanner.rolloutProviderAlignmentRepairs(threads: [thread], targetProvider: "custom")

        #expect(sqliteRepairs.count == 1)
        #expect(sqliteRepairs.first?.targetProvider == "custom")
        #expect(rolloutRepairs.count == 1)
        #expect(rolloutRepairs.first?.currentProvider == "openai")
        #expect(rolloutRepairs.first?.targetProvider == "custom")

        try RolloutRepairer.apply(rolloutRepairs[0])
        let content = try String(contentsOf: rollout, encoding: .utf8)
        #expect(content.contains("\"model_provider\":\"custom\""))
        #expect(content.contains("\"text\":\"keep me\""))
    }

    @Test func paginatedProviderMismatchIsReportedWithoutRolloutRewrite() throws {
        let directory = try makeTempDirectory()
        let rollout = directory.appendingPathComponent("rollout-paginated-provider.jsonl")
        try """
        {"ordinal":0,"type":"session_meta","payload":{"id":"paginated-provider","history_mode":"paginated","model_provider":"openai"}}
        {"ordinal":1,"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"keep me"}]}}
        """.write(to: rollout, atomically: true, encoding: .utf8)

        let thread = makeThread(
            id: "paginated-provider",
            rollout: rollout,
            title: "Paginated provider",
            provider: "custom",
            cwd: directory.path,
            firstUserMessage: "keep me"
        )
        let info = SidebarRepairPlanner.rolloutInfoByPath(for: [thread])
        let warnings = SidebarRepairPlanner.paginatedProviderWarnings(
            threads: [thread],
            rollouts: info,
            targetProvider: "custom"
        )

        #expect(warnings.count == 1)
        #expect(warnings.first?.currentProvider == "openai")
        #expect(warnings.first?.targetProvider == "custom")
        #expect(RolloutRepairer.makeRepair(url: rollout, targetProvider: "custom") == nil)
    }

    @Test func paginatedProviderPlannerRecalculatesDescendantAndHistoryOffsets() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = directory.appendingPathComponent("sessions/2026/10/14")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let history = directory.appendingPathComponent("thread_history_1.sqlite")
        let state = directory.appendingPathComponent("state_1.sqlite")
        let logical = "00000000-0000-0000-0000-000000000101"
        let branch = "00000000-0000-0000-0000-000000000102"
        let root = sessions.appendingPathComponent("rollout-2026-10-14T00-00-00-\(logical).jsonl")
        let child = sessions.appendingPathComponent("rollout-2026-10-14T00-01-00-\(logical)_\(branch).jsonl")
        let rootMeta = "{\"ordinal\":0,\"type\":\"session_meta\",\"payload\":{\"id\":\"\(logical)\",\"history_mode\":\"paginated\",\"model_provider\":\"openai\"}}\n"
        let rootMessage = "{\"ordinal\":1,\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"root\"}]}}\n"
        let childMeta = "{\"ordinal\":2,\"type\":\"session_meta\",\"payload\":{\"id\":\"\(logical)\",\"history_mode\":\"paginated\",\"history_base\":{\"thread_id\":\"\(logical)\",\"end_ordinal_exclusive\":2,\"end_byte_offset\":\(rootMeta.utf8.count + rootMessage.utf8.count)},\"model_provider\":\"openai\"}}\n"
        let childMessage = "{\"ordinal\":3,\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"child\"}]}}\n"
        #expect((try? JSONSerialization.jsonObject(with: Data(rootMeta.utf8))) != nil)
        #expect((try? JSONSerialization.jsonObject(with: Data(childMeta.utf8))) != nil)
        try (rootMeta + rootMessage).write(to: root, atomically: true, encoding: .utf8)
        try (childMeta + childMessage).write(to: child, atomically: true, encoding: .utf8)
        var handle: OpaquePointer?
        #expect(sqlite3_open(state.path, &handle) == SQLITE_OK)
        #expect(sqlite3_exec(handle, "CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT, model_provider TEXT, history_mode TEXT, title TEXT); INSERT INTO threads VALUES('\(logical)','\(root.path)','custom','paginated','planner');", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        #expect(sqlite3_open(history.path, &handle) == SQLITE_OK)
        let turnStart = Int64(rootMeta.utf8.count)
        let boundary = Int64((rootMeta + rootMessage).utf8.count)
        #expect(sqlite3_exec(handle, "CREATE TABLE thread_turns(thread_id TEXT, turn_id TEXT, rollout_ordinal INTEGER, rollout_byte_offset INTEGER, rollout_end_ordinal INTEGER, rollout_end_byte_offset INTEGER, PRIMARY KEY(thread_id,turn_id)); INSERT INTO thread_turns VALUES('\(logical)','turn-1',1,\(turnStart),2,\(boundary)); CREATE TABLE thread_history_projection_state(thread_id TEXT PRIMARY KEY, next_rollout_byte_offset INTEGER, next_rollout_ordinal INTEGER); INSERT INTO thread_history_projection_state VALUES('\(logical)',\(boundary),2);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        let settings = AppSettings(language: .en, codexHome: directory, sqliteHome: directory, defaultBackupMode: .lightweight, lightweightLimit: 5, fullLimit: 3, openCodexAfterRepair: false)
        let thread = ThreadRow(id: logical, rolloutPath: root.path, title: "planner", modelProvider: "custom", hasUserEvent: true, cwd: directory.path, source: "vscode", threadSource: "user", archived: false, updatedAt: 1, updatedAtMs: 1000, firstUserMessage: "root", preview: "root")
        let targetProvider = String(repeating: "x", count: 56) // openai -> target is an exact 50-byte header delta.
        let result = PaginatedProviderRepairService().scan(settings: settings, threads: [thread], targetProvider: targetProvider, stateDatabase: state)
        if result.repairs.isEmpty { print("planner warnings: \(result.warnings.joined(separator: " | "))") }
        #expect(result.repairs.count == 1)
        let repair = try #require(result.repairs.first)
        #expect(result.warnings.isEmpty)
        #expect(repair.rolloutRepairs.count == 2)
        #expect(repair.turnOffsetRepairs.count == 1)
        #expect(repair.projectionOffsetRepairs.count == 1)
        #expect(repair.turnOffsetRepairs[0].targetStartOffset - repair.turnOffsetRepairs[0].currentStartOffset == 50)
        #expect(repair.projectionOffsetRepairs[0].targetOffset - repair.projectionOffsetRepairs[0].currentOffset == 50)
        #expect(repair.turnOffsetRepairs[0].targetStartOffset > repair.turnOffsetRepairs[0].currentStartOffset)
        #expect(repair.projectionOffsetRepairs[0].targetOffset > repair.projectionOffsetRepairs[0].currentOffset)

        let rootBytes = try Data(contentsOf: root)
        let childBytes = try Data(contentsOf: child)
        try PaginatedProviderRepairService().applyRollouts(repair)
        let currentRoot = try Data(contentsOf: root)
        let currentChild = try Data(contentsOf: child)
        let rootSuffix = rootBytes[(rootBytes.firstIndex(of: 10)! + 1)...]
        let currentRootSuffix = currentRoot[(currentRoot.firstIndex(of: 10)! + 1)...]
        let childSuffix = childBytes[(childBytes.firstIndex(of: 10)! + 1)...]
        let currentChildSuffix = currentChild[(currentChild.firstIndex(of: 10)! + 1)...]
        #expect(Data(currentRootSuffix) == Data(rootSuffix))
        #expect(Data(currentChildSuffix) == Data(childSuffix))
        let childHeader = try JSONSerialization.jsonObject(with: Data((try String(contentsOf: child, encoding: .utf8)).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)[0].utf8)) as? [String: Any]
        let payload = childHeader?["payload"] as? [String: Any]
        let base = payload?["history_base"] as? [String: Any]
        #expect((base?["end_byte_offset"] as? NSNumber)?.int64Value == repair.turnOffsetRepairs[0].targetEndOffset)
    }

    @Test func paginatedProviderRepairUpdatesRolloutsAndSQLiteOffsetsWithBackup() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = directory.appendingPathComponent("sessions/2026/10/14")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try "model_provider = \"custom-long\"\n".write(to: directory.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let history = directory.appendingPathComponent("thread_history_1.sqlite")
        let state = directory.appendingPathComponent("state_1.sqlite")
        let logical = "00000000-0000-0000-0000-000000000111"
        let branch = "00000000-0000-0000-0000-000000000112"
        let root = sessions.appendingPathComponent("rollout-2026-10-14T00-00-00-\(logical).jsonl")
        let child = sessions.appendingPathComponent("rollout-2026-10-14T00-01-00-\(logical)_\(branch).jsonl")
        let rootMeta = "{\"ordinal\":0,\"type\":\"session_meta\",\"payload\":{\"id\":\"\(logical)\",\"history_mode\":\"paginated\",\"model_provider\":\"openai\"}}\n"
        let rootMessage = "{\"ordinal\":1,\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"root\"}]}}\n"
        let childMeta = "{\"ordinal\":2,\"type\":\"session_meta\",\"payload\":{\"id\":\"\(logical)\",\"history_mode\":\"paginated\",\"history_base\":{\"thread_id\":\"\(logical)\",\"end_ordinal_exclusive\":2,\"end_byte_offset\":\(rootMeta.utf8.count + rootMessage.utf8.count)},\"model_provider\":\"openai\"}}\n"
        let childMessage = "{\"ordinal\":3,\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"child\"}]}}\n"
        try (rootMeta + rootMessage).write(to: root, atomically: true, encoding: .utf8)
        try (childMeta + childMessage).write(to: child, atomically: true, encoding: .utf8)
        let originalRootBytes = try Data(contentsOf: root)
        let originalChildBytes = try Data(contentsOf: child)
        let turnStart = Int64(rootMeta.utf8.count)
        let boundary = Int64((rootMeta + rootMessage).utf8.count)

        var handle: OpaquePointer?
        #expect(sqlite3_open(state.path, &handle) == SQLITE_OK)
        let stateSQL = """
        CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT, model_provider TEXT, history_mode TEXT, title TEXT, has_user_event INTEGER, cwd TEXT, thread_source TEXT, archived INTEGER, updated_at INTEGER, first_user_message TEXT, preview TEXT, created_at INTEGER, created_at_ms INTEGER, updated_at_ms INTEGER, recency_at INTEGER, recency_at_ms INTEGER);
        INSERT INTO threads VALUES('\(logical)','\(root.path)','custom','paginated','repair',1,'\(directory.path)','user',0,1,'root','root',1,1000,1000,1,1000);
        """
        #expect(sqlite3_exec(handle, stateSQL, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        #expect(sqlite3_open(history.path, &handle) == SQLITE_OK)
        let historySQL = """
        CREATE TABLE thread_turns(thread_id TEXT, turn_id TEXT, rollout_ordinal INTEGER, rollout_byte_offset INTEGER, rollout_end_ordinal INTEGER, rollout_end_byte_offset INTEGER, PRIMARY KEY(thread_id,turn_id));
        INSERT INTO thread_turns VALUES('\(logical)','turn-1',1,\(turnStart),2,\(boundary));
        CREATE TABLE thread_history_projection_state(thread_id TEXT PRIMARY KEY, next_rollout_byte_offset INTEGER, next_rollout_ordinal INTEGER);
        INSERT INTO thread_history_projection_state VALUES('\(logical)',\(boundary),2);
        """
        #expect(sqlite3_exec(handle, historySQL, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        let settings = AppSettings(language: .en, codexHome: directory, sqliteHome: directory, defaultBackupMode: .lightweight, lightweightLimit: 5, fullLimit: 3, openCodexAfterRepair: false)
        let thread = ThreadRow(id: logical, rolloutPath: root.path, title: "repair", modelProvider: "custom", hasUserEvent: true, cwd: directory.path, source: "vscode", threadSource: "user", archived: false, updatedAt: 1, updatedAtMs: 1000, firstUserMessage: "root", preview: "root")
        let planner = PaginatedProviderRepairService()
        let plan = try #require(planner.scan(settings: settings, threads: [thread], targetProvider: "custom-long", stateDatabase: state).repairs.first)
        let scan = ScanResult(providerInfo: ProviderInfo(provider: "custom-long", authLabel: "Custom", configURL: directory.appendingPathComponent("config.toml")), stateDatabase: StateDatabase(url: state, modifiedAt: Date()), threads: [thread], sqliteProviderUpdates: [], sqliteCompatibilityUpdates: [], rolloutRepairs: [], indexRepairs: [], sqliteTimestampRepairs: [], sqliteTitleRepairs: [], rolloutMtimeRepairs: [], paginatedProviderRepairs: [plan], globalStateRepair: nil, backups: [], codexHome: directory, sqliteHome: directory, lastRepairAt: nil)
        let backup = try CodexRepairService(isRunning: { false }).repairPaginated(plan, scan: scan, settings: settings, mode: .lightweight)
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try SQLiteDatabase(path: state.path, readonly: true).queryThreads().first?.modelProvider == "custom-long")
        #expect(try SQLiteDatabase(path: history.path, readonly: true).paginatedTurnRows(threadID: logical).first?.rolloutByteOffset == plan.turnOffsetRepairs.first?.targetStartOffset)
        #expect(try SQLiteDatabase(path: history.path, readonly: true).paginatedProjectionRow(threadID: logical)?.nextRolloutByteOffset == plan.projectionOffsetRepairs.first?.targetOffset)
        let verified = PaginatedProviderRepairService().scan(settings: settings, threads: [ThreadRow(id: logical, rolloutPath: root.path, title: "repair", modelProvider: "custom-long", hasUserEvent: true, cwd: directory.path, source: "vscode", threadSource: "user", archived: false, updatedAt: 1, updatedAtMs: 1000, firstUserMessage: "root", preview: "root")], targetProvider: "custom-long", stateDatabase: state)
        #expect(verified.repairs.isEmpty)

        // The same manifest must be sufficient to restore both databases and every
        // rewritten paginated header without replacing unrelated files wholesale.
        try CodexRepairService(isRunning: { false }).restore(backup: backup)
        #expect(try SQLiteDatabase(path: state.path, readonly: true).queryThreads().first?.modelProvider == "custom")
        #expect(try SQLiteDatabase(path: history.path, readonly: true).paginatedTurnRows(threadID: logical).first?.rolloutByteOffset == turnStart)
        #expect(try Data(contentsOf: root) == originalRootBytes)
        #expect(try Data(contentsOf: child) == originalChildBytes)
    }

    @Test func titleRepairRemovesToolSyntaxAndUsesConversationPreview() throws {
        let directory = try makeTempDirectory()
        let rollout = directory.appendingPathComponent("rollout-title.jsonl")
        try #"{"type":"session_meta","payload":{"id":"title","model_provider":"custom"}}"#
            .appending("\n")
            .write(to: rollout, atomically: true, encoding: .utf8)
        let thread = makeThread(
            id: "title",
            rollout: rollout,
            title: "查看OS agent'}】 }]}} to=functions.exec",
            provider: "custom",
            cwd: directory.path,
            firstUserMessage: "读取os的agent",
            preview: "读取os的agent"
        )

        let repairs = SidebarRepairPlanner.titleRepairs(threads: [thread])

        #expect(repairs.count == 1)
        #expect(repairs.first?.targetTitle.contains("functions.exec") == false)
        #expect(repairs.first?.targetTitle.hasPrefix("读取os的agent") == true)
    }

    @Test func lightweightBackupStoresConsistentSnapshotsForSQLiteDatabases() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("state_5.sqlite")
        var handle: OpaquePointer?
        #expect(sqlite3_open(state.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, "CREATE TABLE threads(id TEXT, rollout_path TEXT, title TEXT, model_provider TEXT, has_user_event INTEGER, cwd TEXT, thread_source TEXT, archived INTEGER, updated_at INTEGER); INSERT INTO threads VALUES('id','/tmp/rollout.jsonl','title','custom',1,'/tmp','user',0,1);", nil, nil, nil) == SQLITE_OK)

        let now = Date()
        let scan = ScanResult(
            providerInfo: ProviderInfo(provider: "custom", authLabel: "Custom", configURL: directory.appendingPathComponent("config.toml")),
            stateDatabase: StateDatabase(url: state, modifiedAt: now),
            threads: [], sqliteProviderUpdates: [], sqliteCompatibilityUpdates: [], rolloutRepairs: [], indexRepairs: [],
            sqliteTimestampRepairs: [], sqliteTitleRepairs: [], rolloutMtimeRepairs: [], globalStateRepair: nil,
            backups: [], codexHome: directory, sqliteHome: directory, lastRepairAt: nil
        )
        let record = try CodexRepairService().createBackup(
            scan: scan,
            settings: AppSettings(language: .en, codexHome: directory, sqliteHome: directory, defaultBackupMode: .lightweight, lightweightLimit: 5, fullLimit: 3, openCodexAfterRepair: false),
            mode: .lightweight
        )
        let manifestData = try Data(contentsOf: URL(fileURLWithPath: record.path).appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder.codexSynced.decode(BackupManifest.self, from: manifestData)
        let snapshot = try #require(manifest.sqliteSnapshots?.first)
        let snapshotURL = URL(fileURLWithPath: record.path).appendingPathComponent(snapshot.backupRelativePath)
        try SQLiteDatabase(path: snapshotURL.path, readonly: true).checkIntegrity()
        #expect(manifest.files.map { URL(fileURLWithPath: $0.originalPath).standardizedFileURL.path }.contains(state.standardizedFileURL.path))
    }

    @Test func timestampRepairCorrectsCreatedAtAheadOfConversation() throws {
        let directory = try makeTempDirectory()
        let rollout = directory.appendingPathComponent("rollout-created-at.jsonl")
        try """
        {"timestamp":"2026-06-27T07:27:02.000Z","type":"session_meta","payload":{"id":"created-at","model_provider":"custom"}}
        {"timestamp":"2026-06-27T07:27:25.000Z","type":"event_msg","payload":{"message":"done"}}
        """.write(to: rollout, atomically: true, encoding: .utf8)
        let firstMs: Int64 = 1_782_545_222_000
        let updatedMs: Int64 = 1_782_545_245_000
        let thread = makeThread(
            id: "created-at",
            rollout: rollout,
            title: "Created at",
            provider: "custom",
            cwd: directory.path,
            updatedAt: updatedMs / 1000,
            updatedAtMs: updatedMs,
            firstUserMessage: "Created at",
            createdAt: (firstMs + 28_800_000) / 1000,
            createdAtMs: firstMs + 28_800_000,
            recencyAt: firstMs / 1000,
            recencyAtMs: firstMs
        )
        let info = SidebarRepairPlanner.rolloutInfoByPath(for: [thread])

        let repairs = SidebarRepairPlanner.timestampRepairs(threads: [thread], rollouts: info)

        #expect(repairs.count == 1)
        #expect(repairs.first?.targetCreatedAtMs == firstMs)
        #expect(repairs.first?.targetUpdatedAtMs == updatedMs)
    }

    @Test func rebuiltIndexKeepsArchivedAndInternalThreadRecords() throws {
        let directory = try makeTempDirectory()
        let archivedRollout = directory.appendingPathComponent("archived.jsonl")
        let internalRollout = directory.appendingPathComponent("internal.jsonl")
        try "{}\n".write(to: archivedRollout, atomically: true, encoding: .utf8)
        try "{}\n".write(to: internalRollout, atomically: true, encoding: .utf8)
        let archived = makeThread(
            id: "archived",
            rollout: archivedRollout,
            title: "Archived",
            provider: "custom",
            cwd: directory.path,
            firstUserMessage: "Archived",
            archived: true
        )
        let internalThread = makeThread(
            id: "internal",
            rollout: internalRollout,
            title: "Internal",
            provider: "custom",
            cwd: directory.path,
            firstUserMessage: "Internal",
            source: #"{"subagent":{"other":"guardian"}}"#
        )

        let repairs = SidebarRepairPlanner.indexRepairs(codexHome: directory, threads: [archived, internalThread])

        #expect(Set(repairs.map(\.threadID)) == ["archived", "internal"])
    }

    @Test func sidebarPlannerDetectsDesktopSummaryRepairs() throws {
        let directory = try makeTempDirectory()
        let project = directory.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let rollout = directory.appendingPathComponent("rollout-sidebar.jsonl")
        try """
        {"timestamp":"2026-06-01T10:00:00.000Z","type":"session_meta","payload":{"id":"sidebar-test","model_provider":"openai","cwd":"\(project.path)"}}
        {"timestamp":"2026-06-01T10:05:00.000Z","type":"event_msg","payload":{"message":"done"}}
        """.write(to: rollout, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: rollout.path)
        try #"{"selected-remote-host-id":"remote-control:bad","electron-saved-workspace-roots":["\#(project.path)"],"project-order":[],"remote-connection-auto-connect-by-host-id":{"remote-control:bad":true},"added-remote-control-env-ids":["stale"],"electron-local-remote-control-environment-id":"local"}"#
            .write(to: directory.appendingPathComponent(".codex-global-state.json"), atomically: true, encoding: .utf8)
        try #"{"id":"sidebar-test","thread_name":"old","updated_at":"2026-06-01T10:00:00.000Z"}"#
            .appending("\n")
            .write(to: directory.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

        let firstMessage = "为什么我的codex左侧的聊天历史有好多都不见了"
        let thread = makeThread(
            id: "sidebar-test",
            rollout: rollout,
            title: firstMessage,
            provider: "openai",
            cwd: project.path,
            updatedAt: 1,
            updatedAtMs: 1000,
            firstUserMessage: firstMessage
        )
        let info = SidebarRepairPlanner.rolloutInfoByPath(for: [thread])
        let titleRepairs = SidebarRepairPlanner.titleRepairs(threads: [thread])
        let timestampRepairs = SidebarRepairPlanner.timestampRepairs(threads: [thread], rollouts: info)
        let mtimeRepairs = SidebarRepairPlanner.rolloutMtimeRepairs(threads: [thread], rollouts: info)
        let projected = SidebarRepairPlanner.projectedThreads(threads: [thread], titleRepairs: titleRepairs, timestampRepairs: timestampRepairs)
        let indexRepairs = SidebarRepairPlanner.indexRepairs(codexHome: directory, threads: projected)
        let globalRepair = SidebarRepairPlanner.globalStateRepair(codexHome: directory, threads: projected)

        #expect(titleRepairs.count == 1)
        #expect(titleRepairs.first?.targetTitle.hasSuffix(" - Project") == true)
        #expect(timestampRepairs.count == 1)
        #expect(mtimeRepairs.count == 1)
        #expect(indexRepairs.count == 1)
        #expect(indexRepairs.first?.title == titleRepairs.first?.targetTitle)
        #expect(globalRepair?.changes.isEmpty == false)
    }

    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeThread(
        id: String,
        rollout: URL,
        title: String,
        provider: String,
        cwd: String,
        updatedAt: Int64 = 1,
        updatedAtMs: Int64? = 1000,
        firstUserMessage: String,
        preview: String = "",
        source: String = "vscode",
        archived: Bool = false,
        createdAt: Int64 = 0,
        createdAtMs: Int64? = nil,
        recencyAt: Int64 = 0,
        recencyAtMs: Int64? = nil
    ) -> ThreadRow {
        ThreadRow(
            id: id,
            rolloutPath: rollout.path,
            title: title,
            modelProvider: provider,
            hasUserEvent: true,
            cwd: cwd,
            source: source,
            threadSource: "user",
            archived: archived,
            updatedAt: updatedAt,
            updatedAtMs: updatedAtMs,
            firstUserMessage: firstUserMessage,
            preview: preview,
            createdAt: createdAt,
            createdAtMs: createdAtMs,
            recencyAt: recencyAt,
            recencyAtMs: recencyAtMs
        )
    }
}
