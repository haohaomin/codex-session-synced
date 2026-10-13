import CoreFoundation
import Foundation

public struct PaginatedProviderScan: Sendable {
    public var repairs: [PaginatedProviderRepair]
    public var warnings: [String]

    public init(repairs: [PaginatedProviderRepair], warnings: [String]) {
        self.repairs = repairs
        self.warnings = warnings
    }
}

/// Computes a complete paginated Provider rewrite without touching disk. The
/// planner is intentionally conservative: every lineage file and every offset
/// must be explainable before a repair is offered to the UI.
public final class PaginatedProviderRepairService {
    public init() {}

    public func scan(settings: AppSettings, threads: [ThreadRow], targetProvider: String, stateDatabase: URL?) -> PaginatedProviderScan {
        guard !targetProvider.isEmpty, let stateDatabase else {
            return PaginatedProviderScan(repairs: [], warnings: [])
        }
        let home = CodexPathResolver.effectiveCodexHome(settings: settings)
        let sqliteHome = CodexPathResolver.effectiveSQLiteHome(settings: settings, parsedConfig: ConfigParser.parse(url: home.appendingPathComponent("config.toml")))
        let historyDatabases = historyDatabases(in: sqliteHome)
        guard historyDatabases.count == 1, let historyDatabase = historyDatabases.first else {
            let candidates = threads.filter { $0.rolloutPath.isEmpty == false && $0.modelProvider != targetProvider && $0.rolloutPath.hasSuffix(".jsonl") }
            guard !candidates.isEmpty else { return PaginatedProviderScan(repairs: [], warnings: []) }
            let message = historyDatabases.isEmpty
                ? "未找到 thread_history_*.sqlite，分页 Provider 修复需人工确认。Missing thread history database; paginated Provider repair requires manual review."
                : "发现多个 thread_history_*.sqlite，无法确认活动历史库，分页 Provider 修复需人工确认。Multiple thread history databases were found; paginated Provider repair requires manual review."
            return PaginatedProviderScan(repairs: [], warnings: [message])
        }

        do {
            let nodes = try loadNodes(home: home)
            let global = Dictionary(grouping: nodes, by: \.physicalID)
            if let duplicate = global.first(where: { $0.value.count > 1 }) {
                throw HistoryRepairError.unsafe("跨文件重复物理 ID：\(duplicate.key) / Duplicate physical ID across rollout files")
            }
            let db = try SQLiteDatabase(path: historyDatabase.path, readonly: true)
            var repairs: [PaginatedProviderRepair] = []
            var warnings: [String] = []
            for thread in threads where !thread.rolloutPath.isEmpty {
                guard let first = try? firstNode(for: thread, nodes: nodes) else {
                    warnings.append("\(thread.id)：找不到可解析的 rollout / No parseable rollout")
                    continue
                }
                guard first.historyMode == "paginated" else { continue }
                do {
                    let chain = try lineage(for: thread, nodes: nodes, global: global)
                    let plan = try makePlan(thread: thread, chain: chain, targetProvider: targetProvider, historyDatabase: historyDatabase, stateDatabase: stateDatabase, historyDB: db)
                    if plan.isMeaningful { repairs.append(plan) }
                } catch {
                    warnings.append("\(thread.title.isEmpty ? thread.id : thread.title)：\(error.localizedDescription)")
                }
            }
            return PaginatedProviderScan(repairs: repairs, warnings: warnings)
        } catch {
            return PaginatedProviderScan(repairs: [], warnings: [error.localizedDescription])
        }
    }

    public func applyRollouts(_ repair: PaginatedProviderRepair) throws {
        for file in repair.rolloutRepairs {
            try replaceFirstLine(url: file.url, expected: file.originalFirstLine, with: file.repairedFirstLine)
        }
    }

    public func restoreRollouts(_ repair: PaginatedProviderRepair) throws {
        for file in repair.rolloutRepairs {
            try replaceFirstLine(url: file.url, expected: nil, with: file.originalFirstLine)
        }
    }

    private struct Base: Sendable {
        var threadID: String
        var endOrdinal: Int64
        var endOffset: Int64
    }

    private struct Boundary: Sendable {
        var ordinal: Int64
        var start: Int64
        var end: Int64
    }

    private struct Node: Sendable {
        var url: URL
        var logicalID: String
        var physicalID: String
        var start: Int64
        var historyMode: String?
        var provider: String?
        var base: Base?
        var firstLine: String
        var firstLineLength: Int64
        var fileLength: Int64
        var boundaries: [Boundary]
    }

    private func historyDatabases(in home: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.lastPathComponent.hasPrefix("thread_history_") && $0.pathExtension == "sqlite" }
            .map(\.standardizedFileURL)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func loadNodes(home: URL) throws -> [Node] {
        let roots = [home.appendingPathComponent("sessions"), home.appendingPathComponent("archived_sessions")]
        let urls = try rolloutFiles(roots: roots)
        var nodes: [Node] = []
        for url in urls where !isIgnoredArtifact(url) {
            guard let ids = ids(in: url) else { continue }
            guard let node = try parseNode(url: url, ids: ids) else { continue }
            nodes.append(node)
        }
        return nodes
    }

    private func parseNode(url: URL, ids: (logical: String, physical: String)) throws -> Node? {
        let metadataData = try firstLineData(url)
        guard let metadataData,
              let metadataObject = try JSONSerialization.jsonObject(with: metadataData) as? [String: Any],
              metadataObject["type"] as? String == "session_meta",
              let metadataPayload = metadataObject["payload"] as? [String: Any],
              metadataPayload["id"] as? String == ids.logical else {
            return nil
        }
        guard metadataPayload["history_mode"] as? String == "paginated",
              let metadataOrdinal = int64(metadataObject["ordinal"]) else {
            return nil
        }
        let firstLine = String(decoding: metadataData.dropLast(metadataData.last == 10 ? (metadataData.dropLast().last == 13 ? 2 : 1) : 0), as: UTF8.self)
        let firstLineLength = Int64(metadataData.count)
        var boundaries: [Boundary] = []
        var expected: Int64? = metadataOrdinal
        var fileLength: Int64 = 0
        try lines(url) { data, offset, length in
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ordinalNumber = object["ordinal"] as? NSNumber,
                  CFGetTypeID(ordinalNumber) != CFBooleanGetTypeID(),
                  ordinalNumber.doubleValue == Double(ordinalNumber.int64Value) else {
                throw HistoryRepairError.unsafe("序号缺失或非法 / Missing or invalid ordinal: \(url.lastPathComponent)")
            }
            let ordinal = ordinalNumber.int64Value
            guard expected == ordinal else {
                throw HistoryRepairError.unsafe("分页序号不连续 / Noncontiguous ordinal: \(url.lastPathComponent)")
            }
            boundaries.append(Boundary(ordinal: ordinal, start: offset, end: offset + length))
            expected = ordinal == Int64.max ? nil : ordinal + 1
            fileLength = offset + length
        }
        guard let data = firstLine.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return nil }
        let base: Base?
        if let raw = payload["history_base"] as? [String: Any],
           let threadID = raw["thread_id"] as? String,
           let endOrdinal = int64(raw["end_ordinal_exclusive"]),
           let endOffset = int64(raw["end_byte_offset"]) {
            base = Base(threadID: threadID, endOrdinal: endOrdinal, endOffset: endOffset)
        } else {
            base = nil
        }
        return Node(url: url, logicalID: ids.logical, physicalID: ids.physical, start: boundaries.first?.ordinal ?? 0,
            historyMode: payload["history_mode"] as? String, provider: payload["model_provider"] as? String,
            base: base, firstLine: firstLine, firstLineLength: firstLineLength, fileLength: fileLength, boundaries: boundaries)
    }

    private func firstNode(for thread: ThreadRow, nodes: [Node]) throws -> Node {
        guard let node = nodes.first(where: { $0.url.standardizedFileURL.path == URL(fileURLWithPath: thread.rolloutPath).standardizedFileURL.path }) else {
            throw HistoryRepairError.unsafe("找不到 rollout / Missing rollout")
        }
        return node
    }

    private func lineage(for thread: ThreadRow, nodes: [Node], global: [String: [Node]]) throws -> [Node] {
        let local = nodes.filter { $0.logicalID == thread.id }
        guard !local.isEmpty else { throw HistoryRepairError.unsafe("找不到逻辑会话的 rollout / Missing logical rollout") }
        let localByPhysical = Dictionary(grouping: local, by: \.physicalID)
        guard localByPhysical.values.allSatisfy({ $0.count == 1 }) else { throw HistoryRepairError.unsafe("重复物理 ID / Duplicate physical ID") }
        let parents = Set(local.compactMap { $0.base?.threadID })
        let leaves = local.filter { !parents.contains($0.physicalID) }
        guard leaves.count == 1 else { throw HistoryRepairError.unsafe("多个末端或分支循环 / Ambiguous tips or cycle") }
        var reversed: [Node] = []
        var visited = Set<String>()
        var cursor: Node? = leaves[0]
        while let node = cursor {
            guard visited.insert(node.physicalID).inserted else { throw HistoryRepairError.unsafe("分支循环 / Cycle") }
            reversed.append(node)
            if let base = node.base {
                let localParent = localByPhysical[base.threadID]?.first
                let globalParents = global[base.threadID] ?? []
                guard let parent = localParent ?? (globalParents.count == 1 ? globalParents[0] : nil) else {
                    throw HistoryRepairError.unsafe("父分支缺失 / Missing parent: \(base.threadID)")
                }
                cursor = parent
            } else {
                guard node.start == 0 else { throw HistoryRepairError.unsafe("原始根分支无法确认 / Unconfirmed root") }
                cursor = nil
            }
        }
        let localIDs = Set(local.map(\.physicalID))
        guard localIDs.isSubset(of: visited), local.contains(where: { $0.url.standardizedFileURL.path == URL(fileURLWithPath: thread.rolloutPath).standardizedFileURL.path }) else {
            throw HistoryRepairError.unsafe("入口不在完整分支链上 / Entrypoint is not on a complete chain")
        }
        let chain = reversed.reversed()
        try validateBoundaries(Array(chain))
        return Array(chain)
    }

    private func makePlan(thread: ThreadRow, chain: [Node], targetProvider: String, historyDatabase: URL, stateDatabase: URL, historyDB: SQLiteDatabase) throws -> PaginatedProviderRepair {
        guard chain.contains(where: { $0.logicalID == thread.id && $0.provider != targetProvider }) else {
            return PaginatedProviderRepair(threadID: thread.id, title: thread.title, targetProvider: targetProvider, currentSQLiteProvider: thread.modelProvider, stateDatabase: stateDatabase, historyDatabase: historyDatabase, rolloutRepairs: [], turnOffsetRepairs: [], projectionOffsetRepairs: [])
        }

        var deltas: [String: Int64] = [:]
        var rolloutRepairs: [PaginatedRolloutRepair] = []
        for node in chain {
            guard let data = node.firstLine.data(using: .utf8), var object = try JSONSerialization.jsonObject(with: data) as? [String: Any], var payload = object["payload"] as? [String: Any] else {
                throw HistoryRepairError.unsafe("无法解析 session_meta / Invalid session metadata")
            }
            var changed = false
            if node.logicalID == thread.id, payload["model_provider"] as? String != targetProvider {
                payload["model_provider"] = targetProvider
                changed = true
            }
            if var rawBase = payload["history_base"] as? [String: Any], let parentDelta = deltas[rawBase["thread_id"] as? String ?? ""], parentDelta != 0 {
                guard let oldOffset = int64(rawBase["end_byte_offset"]) else { throw HistoryRepairError.unsafe("history_base 偏移缺失 / Missing history_base offset") }
                let next = oldOffset + parentDelta
                guard next >= 0 else { throw HistoryRepairError.unsafe("history_base 偏移溢出 / Negative history_base offset") }
                rawBase["end_byte_offset"] = next
                payload["history_base"] = rawBase
                changed = true
            }
            object["payload"] = payload
            let repairedLine = changed ? try sortedJSONString(object) : node.firstLine
            let oldLength = node.firstLineLength
            let newLength = Int64(repairedLine.utf8.count + newlineLength(url: node.url))
            let delta = newLength - oldLength
            deltas[node.physicalID] = delta
            if changed {
                rolloutRepairs.append(PaginatedRolloutRepair(url: node.url, originalFirstLine: node.firstLine, repairedFirstLine: repairedLine, originalByteLength: oldLength, repairedByteLength: newLength, logicalID: node.logicalID, physicalID: node.physicalID))
            }
        }

        let turns = try historyDB.paginatedTurnRows(threadID: thread.id)
        let turnRepairs = try turns.compactMap { row -> PaginatedTurnOffsetRepair? in
            guard let start = mapOffset(ordinal: row.rolloutOrdinal, offset: row.rolloutByteOffset, chain: chain, deltas: deltas) else {
                throw HistoryRepairError.unsafe("无法定位 turn 起始偏移 / Cannot map turn start offset")
            }
            let end: Int64?
            if let ordinal = row.rolloutEndOrdinal, let offset = row.rolloutEndByteOffset {
                guard let mapped = mapOffset(ordinal: ordinal, offset: offset, chain: chain, deltas: deltas) else {
                    throw HistoryRepairError.unsafe("无法定位 turn 结束偏移 / Cannot map turn end offset")
                }
                end = mapped
            } else if row.rolloutEndByteOffset != nil {
                throw HistoryRepairError.unsafe("turn 结束序号缺失，无法安全重算偏移 / Missing turn end ordinal")
            } else {
                end = nil
            }
            guard start != row.rolloutByteOffset || end != row.rolloutEndByteOffset else { return nil }
            return PaginatedTurnOffsetRepair(threadID: row.threadID, turnID: row.turnID, currentStartOffset: row.rolloutByteOffset, targetStartOffset: start, currentEndOffset: row.rolloutEndByteOffset, targetEndOffset: end)
        }

        var projectionRepairs: [PaginatedProjectionOffsetRepair] = []
        if let projection = try historyDB.paginatedProjectionRow(threadID: thread.id),
           let mapped = mapOffset(ordinal: projection.nextRolloutOrdinal, offset: projection.nextRolloutByteOffset, chain: chain, deltas: deltas), mapped != projection.nextRolloutByteOffset {
            projectionRepairs.append(PaginatedProjectionOffsetRepair(threadID: thread.id, currentOffset: projection.nextRolloutByteOffset, targetOffset: mapped))
        }
        return PaginatedProviderRepair(threadID: thread.id, title: thread.title, targetProvider: targetProvider, currentSQLiteProvider: thread.modelProvider, stateDatabase: stateDatabase.standardizedFileURL, historyDatabase: historyDatabase.standardizedFileURL, rolloutRepairs: rolloutRepairs, turnOffsetRepairs: turnRepairs, projectionOffsetRepairs: projectionRepairs)
    }

    private func validateBoundaries(_ chain: [Node]) throws {
        for (index, node) in chain.enumerated() {
            if let base = node.base {
                guard base.endOrdinal == node.start else { throw HistoryRepairError.unsafe("继承序号不连续 / Noncontiguous inherited ordinal") }
                guard let parent = chain.first(where: { $0.physicalID == base.threadID }), offsetForOrdinal(base.endOrdinal, in: parent) == base.endOffset else {
                    throw HistoryRepairError.unsafe("字节边界不一致 / Byte boundary mismatch")
                }
            } else if node.start != 0 {
                throw HistoryRepairError.unsafe("原始根分支无法确认 / Unconfirmed root")
            }
            if index + 1 < chain.count, let nextBase = chain[index + 1].base {
                guard nextBase.threadID == node.physicalID, offsetForOrdinal(nextBase.endOrdinal, in: node) == nextBase.endOffset else {
                    throw HistoryRepairError.unsafe("后继边界不一致 / Successor boundary mismatch")
                }
            }
        }
    }

    private func mapOffset(ordinal: Int64, offset: Int64, chain: [Node], deltas: [String: Int64]) -> Int64? {
        guard let node = nodeForBoundary(ordinal: ordinal, offset: offset, chain: chain), offset >= 0, offset <= node.fileLength else { return nil }
        let delta = deltas[node.physicalID] ?? 0
        return offset >= node.firstLineLength ? offset + delta : offset
    }

    private func nodeForBoundary(ordinal: Int64, offset: Int64, chain: [Node]) -> Node? {
        for (index, node) in chain.enumerated() {
            let nextStart = index + 1 < chain.count ? chain[index + 1].start : Int64.max
            if ordinal >= node.start && ordinal < nextStart { return node }
            if ordinal == nextStart, offset == node.fileLength { return node }
        }
        return nil
    }

    private func offsetForOrdinal(_ ordinal: Int64, in node: Node) -> Int64? {
        if let boundary = node.boundaries.first(where: { $0.ordinal == ordinal }) { return boundary.start }
        guard ordinal == (node.boundaries.last?.ordinal ?? -1) + 1 else { return nil }
        return node.fileLength
    }

    private func sortedJSONString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let result = String(data: data, encoding: .utf8) else { throw HistoryRepairError.unsafe("无法编码 session_meta / Cannot encode session metadata") }
        return result
    }

    private func replaceFirstLine(url: URL, expected: String?, with line: String) throws {
        let fm = FileManager.default
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).codex-synced-\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: temp)
        do {
            let first = try input.read(upToCount: 1024 * 1024) ?? Data()
            guard let newline = first.firstIndex(of: 10) else { throw HistoryRepairError.unsafe("session_meta 没有换行 / Missing session metadata newline") }
            let newlineData: Data = newline > first.startIndex && first[newline - 1] == 13 ? Data([13, 10]) : Data([10])
            if let expected {
                let currentData = first[..<newline]
                let current = String(decoding: currentData.last == 13 ? currentData.dropLast() : currentData, as: UTF8.self)
                guard current == expected else {
                    throw HistoryRepairError.stale
                }
            }
            try output.write(contentsOf: Data(line.utf8))
            try output.write(contentsOf: newlineData)
            let suffixStart = first.index(after: newline)
            if suffixStart < first.endIndex { try output.write(contentsOf: first[suffixStart...]) }
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty { try output.write(contentsOf: chunk) }
            try output.close()
            if let permissions = try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path) }
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? output.close()
            try? fm.removeItem(at: temp)
            throw error
        }
    }


    private func lines(_ url: URL, visit: (Data, Int64, Int64) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data()
        var offset: Int64 = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            var start = pending.startIndex
            while let end = pending[start...].firstIndex(of: 10) {
                let next = pending.index(after: end)
                let line = Data(pending[start..<next])
                try visit(line, offset, Int64(line.count))
                offset += Int64(line.count)
                start = next
            }
            pending = Data(pending[start...])
        }
        if !pending.isEmpty { try visit(pending, offset, Int64(pending.count)) }
    }

    private func firstLineData(_ url: URL) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            data.append(chunk)
            if let newline = data.firstIndex(of: 10) {
                return Data(data[...newline])
            }
            guard data.count <= 64 * 1024 * 1024 else {
                throw HistoryRepairError.unsafe("session_meta 过大 / Metadata line too large")
            }
        }
        return data.isEmpty ? nil : data
    }

    private func rolloutFiles(roots: [URL]) throws -> [URL] {
        var result: [URL] = []
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { continue }
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { throw HistoryRepairError.unsafe("会话目录含符号链接，需人工检查 / Symlink requires manual review") }
                if values.isRegularFile == true, url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("rollout-") { result.append(url) }
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    private func ids(in url: URL) -> (logical: String, physical: String)? {
        let uuid = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        let name = url.lastPathComponent
        guard let regex = try? NSRegularExpression(pattern: "^rollout-.+-(\(uuid))(?:_(\(uuid)))?\\.jsonl$"),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let logicalRange = Range(match.range(at: 1), in: name) else { return nil }
        let logical = String(name[logicalRange])
        let physical = Range(match.range(at: 2), in: name).map { String(name[$0]) } ?? logical
        return (logical, physical)
    }

    private func isIgnoredArtifact(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasPrefix(".") || name.contains(".codex-synced-") || name.hasSuffix("_repaired.jsonl") || name.hasSuffix(".bak.jsonl") || name.hasSuffix(".tmp.jsonl")
    }

    private func int64(_ value: Any?) -> Int64? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue == Double(value.int64Value) else { return nil }
        return value.int64Value
    }

    private func newlineLength(url: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url), let data = try? handle.read(upToCount: 1024 * 1024) ?? Data() else { return 1 }
        try? handle.close()
        guard let newline = data.firstIndex(of: 10) else { return 1 }
        return newline > data.startIndex && data[newline - 1] == 13 ? 2 : 1
    }
}
