import Foundation
import SQLite3

enum SQLiteError: LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): "无法打开 SQLite：\(message)"
        case .prepareFailed(let message): "无法准备 SQLite 查询：\(message)"
        case .stepFailed(let message): "SQLite 执行失败：\(message)"
        }
    }
}

struct PaginatedTurnRow: Equatable, Sendable {
    let threadID: String
    let turnID: String
    let rolloutOrdinal: Int64
    let rolloutByteOffset: Int64
    let rolloutEndOrdinal: Int64?
    let rolloutEndByteOffset: Int64?
}

struct PaginatedProjectionRow: Equatable, Sendable {
    let threadID: String
    let nextRolloutByteOffset: Int64
    let nextRolloutOrdinal: Int64
}

final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String, readonly: Bool, create: Bool = true) throws {
        let flags = readonly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0))
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            handle = nil
            throw SQLiteError.openFailed(message)
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    // SQLite's backup API includes committed WAL pages. Never copy a live .sqlite alone.
    func backup(to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw SQLiteError.stepFailed("Backup destination already exists")
        }
        let destination = try SQLiteDatabase(path: url.path, readonly: false)
        guard let backup = sqlite3_backup_init(destination.handle, "main", handle, "main") else {
            throw SQLiteError.stepFailed(destination.errorMessage)
        }
        var result: Int32 = SQLITE_OK
        var retries = 0
        let deadline = Date().addingTimeInterval(30)
        repeat {
            result = sqlite3_backup_step(backup, 256)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                retries += 1
                sqlite3_sleep(20)
            }
        } while Date() < deadline && (result == SQLITE_OK || ((result == SQLITE_BUSY || result == SQLITE_LOCKED) && retries < 50))
        let finish = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finish == SQLITE_OK else {
            throw SQLiteError.stepFailed("SQLite backup did not complete")
        }
        try destination.checkIntegrity()
    }

    func checkIntegrity() throws {
        guard try stringRows("PRAGMA integrity_check") == [["ok"]] else {
            throw SQLiteError.stepFailed("SQLite integrity check failed")
        }
    }

    /// Preserve every column (including NULL and storage type), not only known metadata.
    func entrypointRows() throws -> [EntrypointRow] {
        guard try tableColumns("threads").isSuperset(of: ["id", "rollout_path", "title", "history_mode"]) else {
            throw HistoryRepairError.unsafe("Unsupported threads schema / 不支持的 threads 结构")
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT * FROM threads ORDER BY id", -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(statement) }
        var rows: [EntrypointRow] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            var fields: [String: SQLiteField] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                let type = sqlite3_column_type(statement, index)
                let value: String
                if type == SQLITE_BLOB {
                    let count = Int(sqlite3_column_bytes(statement, index))
                    value = sqlite3_column_blob(statement, index).map { Data(bytes: $0, count: count).base64EncodedString() } ?? ""
                } else if type == SQLITE_TEXT, let bytes = sqlite3_column_text(statement, index) {
                    let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
                    guard let decoded = String(data: data, encoding: .utf8) else {
                        throw HistoryRepairError.unsafe("Non-UTF8 SQLite text requires manual review")
                    }
                    value = decoded
                } else {
                    value = text(statement, index)
                }
                fields[name] = SQLiteField(type: type, value: value)
            }
            rows.append(EntrypointRow(fields: fields))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw SQLiteError.stepFailed(errorMessage) }
        return rows
    }

    /// Compare-and-swap in one transaction; a rollback never replaces an entire database.
    func changeEntrypoint(expected: EntrypointRow, to path: String, validate: () throws -> Void) throws -> EntrypointRow {
        try execute("BEGIN IMMEDIATE")
        do {
            guard try stringRows("SELECT name FROM sqlite_master WHERE type = 'trigger'").isEmpty else {
                throw HistoryRepairError.unsafe("Database has triggers; manual review required / 数据库存在触发器，需人工检查")
            }
            guard try entrypointRows().first(where: { $0.id == expected.id }) == expected else {
                throw HistoryRepairError.stale
            }
            try validate()
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "UPDATE threads SET rollout_path = ? WHERE id = ? AND rollout_path = ?", -1, &statement, nil) == SQLITE_OK else {
                throw SQLiteError.prepareFailed(errorMessage)
            }
            defer { sqlite3_finalize(statement) }
            bind(path, to: statement, index: 1)
            bind(expected.id, to: statement, index: 2)
            bind(expected.path, to: statement, index: 3)
            guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(handle) == 1 else {
                throw SQLiteError.stepFailed("Entrypoint update failed")
            }
            var desired = expected
            desired.fields["rollout_path"] = SQLiteField(type: SQLITE_TEXT, value: path)
            guard try entrypointRows().first(where: { $0.id == expected.id }) == desired else {
                throw HistoryRepairError.unsafe("Metadata changed unexpectedly / 元数据校验失败")
            }
            try validate()
            try checkIntegrity()
            try execute("COMMIT")
            return desired
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func stringRows(_ sql: String) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(statement) }
        var result: [[String]] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(statement)).map { text(statement, $0) })
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw SQLiteError.stepFailed(errorMessage) }
        return result
    }

    func queryThreads() throws -> [ThreadRow] {
        let columns = try tableColumns("threads")
        let updatedAtMsExpression = columns.contains("updated_at_ms") ? "updated_at_ms" : "NULL"
        let createdAtExpression = columns.contains("created_at") ? "created_at" : "0"
        let createdAtMsExpression = columns.contains("created_at_ms") ? "created_at_ms" : "NULL"
        let recencyAtExpression = columns.contains("recency_at") ? "recency_at" : "0"
        let recencyAtMsExpression = columns.contains("recency_at_ms") ? "recency_at_ms" : "NULL"
        let sourceExpression = columns.contains("source") ? "source" : "''"
        let firstUserExpression = columns.contains("first_user_message") ? "first_user_message" : "''"
        let previewExpression = columns.contains("preview") ? "preview" : "''"
        let titleExpression = columns.contains("name") ? "COALESCE(NULLIF(name, ''), title)" : "title"
        let sql = """
        SELECT id, rollout_path, \(titleExpression), model_provider, has_user_event, cwd, thread_source, archived, updated_at,
               \(updatedAtMsExpression) AS updated_at_ms,
               \(sourceExpression) AS source,
               \(firstUserExpression) AS first_user_message,
               \(previewExpression) AS preview,
               \(createdAtExpression) AS created_at,
               \(createdAtMsExpression) AS created_at_ms,
               \(recencyAtExpression) AS recency_at,
               \(recencyAtMsExpression) AS recency_at_ms
        FROM threads
        ORDER BY COALESCE(NULLIF(\(updatedAtMsExpression), 0), updated_at * 1000) DESC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(statement) }

        var rows: [ThreadRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(ThreadRow(
                id: text(statement, 0),
                rolloutPath: text(statement, 1),
                title: text(statement, 2),
                modelProvider: text(statement, 3),
                hasUserEvent: sqlite3_column_int(statement, 4) != 0,
                cwd: text(statement, 5),
                source: text(statement, 10),
                threadSource: nullableText(statement, 6),
                archived: sqlite3_column_int(statement, 7) != 0,
                updatedAt: sqlite3_column_int64(statement, 8),
                updatedAtMs: nullableInt64(statement, 9),
                firstUserMessage: text(statement, 11),
                preview: text(statement, 12),
                createdAt: sqlite3_column_int64(statement, 13),
                createdAtMs: nullableInt64(statement, 14),
                recencyAt: sqlite3_column_int64(statement, 15),
                recencyAtMs: nullableInt64(statement, 16)
            ))
        }
        return rows
    }

    func updateProviders(_ repairs: [ProviderRepair]) throws {
        guard !repairs.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let sql = "UPDATE threads SET model_provider = ? WHERE id = ?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SQLiteError.prepareFailed(errorMessage)
            }
            defer { sqlite3_finalize(statement) }

            for repair in repairs {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(repair.targetProvider, to: statement, index: 1)
                bind(repair.thread.id, to: statement, index: 2)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw SQLiteError.stepFailed(errorMessage)
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func updateProvidersCompareAndSwap(_ repairs: [ProviderRepair]) throws {
        guard !repairs.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let sql = "UPDATE threads SET model_provider = ? WHERE id = ? AND model_provider = ?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SQLiteError.prepareFailed(errorMessage)
            }
            defer { sqlite3_finalize(statement) }
            for repair in repairs {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(repair.targetProvider, to: statement, index: 1)
                bind(repair.thread.id, to: statement, index: 2)
                bind(repair.thread.modelProvider, to: statement, index: 3)
                guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(handle) == 1 else {
                    throw HistoryRepairError.stale
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func paginatedTurnRows(threadID: String) throws -> [PaginatedTurnRow] {
        guard try tableColumns("thread_turns").isSuperset(of: ["thread_id", "turn_id", "rollout_ordinal", "rollout_byte_offset", "rollout_end_ordinal", "rollout_end_byte_offset"]) else {
            throw HistoryRepairError.unsafe("thread_turns schema is missing rollout offsets / thread_turns 缺少分页偏移字段")
        }
        var statement: OpaquePointer?
        let sql = "SELECT thread_id, turn_id, rollout_ordinal, rollout_byte_offset, rollout_end_ordinal, rollout_end_byte_offset FROM thread_turns WHERE thread_id = ? ORDER BY rollout_ordinal, turn_id"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(statement) }
        bind(threadID, to: statement, index: 1)
        var rows: [PaginatedTurnRow] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            rows.append(PaginatedTurnRow(
                threadID: text(statement, 0),
                turnID: text(statement, 1),
                rolloutOrdinal: sqlite3_column_int64(statement, 2),
                rolloutByteOffset: sqlite3_column_int64(statement, 3),
                rolloutEndOrdinal: nullableInt64(statement, 4),
                rolloutEndByteOffset: nullableInt64(statement, 5)
            ))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw SQLiteError.stepFailed(errorMessage) }
        return rows
    }

    func paginatedProjectionRow(threadID: String) throws -> PaginatedProjectionRow? {
        guard try tableColumns("thread_history_projection_state").isSuperset(of: ["thread_id", "next_rollout_byte_offset", "next_rollout_ordinal"]) else {
            throw HistoryRepairError.unsafe("projection state schema is missing rollout offsets / projection state 缺少分页偏移字段")
        }
        var statement: OpaquePointer?
        let sql = "SELECT thread_id, next_rollout_byte_offset, next_rollout_ordinal FROM thread_history_projection_state WHERE thread_id = ?"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(statement) }
        bind(threadID, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return PaginatedProjectionRow(threadID: text(statement, 0), nextRolloutByteOffset: sqlite3_column_int64(statement, 1), nextRolloutOrdinal: sqlite3_column_int64(statement, 2))
    }

    func updatePaginatedTurnOffsets(_ repairs: [PaginatedTurnOffsetRepair]) throws {
        guard !repairs.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let sql = """
            UPDATE thread_turns
            SET rollout_byte_offset = ?, rollout_end_byte_offset = ?
            WHERE thread_id = ? AND turn_id = ? AND rollout_byte_offset = ?
              AND ((rollout_end_byte_offset IS NULL AND ? IS NULL) OR rollout_end_byte_offset = ?)
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SQLiteError.prepareFailed(errorMessage)
            }
            defer { sqlite3_finalize(statement) }
            for repair in repairs {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_int64(statement, 1, repair.targetStartOffset)
                bindOptional(repair.targetEndOffset, to: statement, index: 2)
                bind(repair.threadID, to: statement, index: 3)
                bind(repair.turnID, to: statement, index: 4)
                sqlite3_bind_int64(statement, 5, repair.currentStartOffset)
                bindOptional(repair.currentEndOffset, to: statement, index: 6)
                bindOptional(repair.currentEndOffset, to: statement, index: 7)
                guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(handle) == 1 else {
                    throw HistoryRepairError.stale
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func updatePaginatedProjectionOffset(_ repair: PaginatedProjectionOffsetRepair) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            let sql = "UPDATE thread_history_projection_state SET next_rollout_byte_offset = ? WHERE thread_id = ? AND next_rollout_byte_offset = ?"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SQLiteError.prepareFailed(errorMessage)
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, repair.targetOffset)
            bind(repair.threadID, to: statement, index: 2)
            sqlite3_bind_int64(statement, 3, repair.currentOffset)
            guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(handle) == 1 else {
                throw HistoryRepairError.stale
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func updateTimestamps(_ repairs: [TimestampRepair]) throws {
        guard !repairs.isEmpty else { return }
        let columns = try tableColumns("threads")

        try execute("BEGIN IMMEDIATE")
        do {
            for repair in repairs {
                var assignments = ["updated_at = ?"]
                if columns.contains("updated_at_ms") {
                    assignments.append("updated_at_ms = ?")
                }
                if repair.targetCreatedAtMs != nil, columns.contains("created_at") {
                    assignments.append("created_at = ?")
                    if columns.contains("created_at_ms") {
                        assignments.append("created_at_ms = ?")
                    }
                }
                let sql = "UPDATE threads SET \(assignments.joined(separator: ", ")) WHERE id = ?"
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw SQLiteError.prepareFailed(errorMessage)
                }

                var index: Int32 = 1
                sqlite3_bind_int64(statement, index, repair.targetUpdatedAtMs / 1000)
                index += 1
                if columns.contains("updated_at_ms") {
                    sqlite3_bind_int64(statement, index, repair.targetUpdatedAtMs)
                    index += 1
                }
                if let createdAtMs = repair.targetCreatedAtMs, columns.contains("created_at") {
                    sqlite3_bind_int64(statement, index, createdAtMs / 1000)
                    index += 1
                    if columns.contains("created_at_ms") {
                        sqlite3_bind_int64(statement, index, createdAtMs)
                        index += 1
                    }
                }
                bind(repair.threadID, to: statement, index: index)
                let result = sqlite3_step(statement)
                sqlite3_finalize(statement)
                guard result == SQLITE_DONE else {
                    throw SQLiteError.stepFailed(errorMessage)
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func updateTitles(_ repairs: [TitleRepair]) throws {
        guard !repairs.isEmpty else { return }
        let columns = try tableColumns("threads")
        try execute("BEGIN IMMEDIATE")
        do {
            let sql = columns.contains("name")
                ? "UPDATE threads SET title = ?, name = ? WHERE id = ?"
                : "UPDATE threads SET title = ? WHERE id = ?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SQLiteError.prepareFailed(errorMessage)
            }
            defer { sqlite3_finalize(statement) }

            for repair in repairs {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(repair.targetTitle, to: statement, index: 1)
                if columns.contains("name") {
                    bind(repair.targetTitle, to: statement, index: 2)
                    bind(repair.threadID, to: statement, index: 3)
                } else {
                    bind(repair.threadID, to: statement, index: 2)
                }
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw SQLiteError.stepFailed(errorMessage)
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func updateCompatibility(threadIDs: [String]) throws {
        guard !threadIDs.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let sql = """
            UPDATE threads
            SET has_user_event = CASE WHEN has_user_event = 0 THEN 1 ELSE has_user_event END,
                cwd = CASE WHEN cwd = '' THEN '~' ELSE cwd END,
                thread_source = CASE WHEN thread_source IS NULL OR thread_source = '' THEN 'user' ELSE thread_source END
            WHERE id = ?
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SQLiteError.prepareFailed(errorMessage)
            }
            defer { sqlite3_finalize(statement) }

            for id in threadIDs {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(id, to: statement, index: 1)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw SQLiteError.stepFailed(errorMessage)
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.stepFailed(errorMessage)
        }
    }

    private var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }

    private func tableColumns(_ table: String) throws -> Set<String> {
        let sql = "PRAGMA table_info(\(table))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = nullableText(statement, 1) {
                columns.insert(name)
            }
        }
        return columns
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        nullableText(statement, index) ?? ""
    }

    private func nullableText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private func nullableInt64(_ statement: OpaquePointer?, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    private func bind(_ value: String, to statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bindOptional(_ value: Int64?, to statement: OpaquePointer?, index: Int32) {
        if let value {
            sqlite3_bind_int64(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
