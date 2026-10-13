import CryptoKit
import CoreFoundation
import Foundation

public enum HistoryRepairError: LocalizedError {
    case unsafe(String)
    case stale

    public var errorDescription: String? {
        switch self {
        case .unsafe(let reason): reason
        case .stale: "数据已变化，请重新扫描。Data changed; scan again."
        }
    }
}

struct SQLiteField: Codable, Equatable, Sendable {
    var type: Int32
    var value: String
}

struct EntrypointRow: Codable, Equatable, Sendable {
    var fields: [String: SQLiteField]
    var id: String { fields["id"]?.value ?? "" }
    var path: String { fields["rollout_path"]?.value ?? "" }
    var title: String {
        let name = fields["name"]?.value ?? ""
        return name.isEmpty ? fields["title"]?.value ?? id : name
    }
}

struct HistoryFile: Codable, Equatable, Sendable {
    var path: String
    var sha256: String
}

public struct HistoryDiagnosis: Identifiable, Sendable {
    public var id: String { row.id }
    public var title: String { row.title }
    public var currentPath: String { row.path }
    public let proposedPath: String?
    public let detail: String
    public let messageCount: Int
    public var canRepair: Bool { proposedPath != nil }
    let row: EntrypointRow
    let files: [HistoryFile]
}

public struct HistoryScan: Sendable {
    public let database: URL
    public let codexHome: URL
    public let diagnoses: [HistoryDiagnosis]
    public let warnings: [String]
}

public struct HistoryRepairRecord: Codable, Identifiable, Sendable {
    public var id: String { directory }
    public let directory: String
    public let threadID: String
    public let title: String
    public let createdAt: Date
    public let oldPath: String
    public let newPath: String
}

private struct HistoryManifest: Codable {
    var version = 1
    var record: HistoryRepairRecord
    var database: String
    var codexHome: String
    var before: EntrypointRow
    var after: EntrypointRow
    var files: [HistoryFile]
    // A durable intent record is written BEFORE commit. Current DB state determines
    // whether it was applied, interrupted, or reverted; no post-commit write is needed.
}

private struct HistoryBase: Decodable, Sendable {
    let thread_id: String
    let end_ordinal_exclusive: Int64
    let end_byte_offset: Int64
}

private struct RolloutHeader: Decodable {
    let type: String
    let ordinal: Int64?
    let payload: Payload
    struct Payload: Decodable {
        let id: String
        let history_mode: String?
        let history_base: HistoryBase?
    }
}

private struct HistoryNode {
    let url: URL
    let logicalID: String
    let physicalID: String
    let start: Int64
    let base: HistoryBase?
}

/// Deliberately separate from sidebar/provider repair: never rewrites JSONL or UI state.
public final class HistoryRepairService {
    private let isRunning: () -> Bool

    public convenience init() {
        self.init(isRunning: { Self.hasCodexWriter() })
    }

    // Injectable only inside this module (tests); the public write path always checks Codex.
    init(isRunning: @escaping () -> Bool) { self.isRunning = isRunning }

    public func scan(settings: AppSettings) throws -> HistoryScan {
        let home = CodexPathResolver.effectiveCodexHome(settings: settings)
        let config = ConfigParser.parse(url: home.appendingPathComponent("config.toml"))
        let sqlite = CodexPathResolver.effectiveSQLiteHome(settings: settings, parsedConfig: config)
        let automatic = settings.sqliteHome == nil && (config.rootValues["sqlite_home"] ?? "").isEmpty
        let directories = automatic ? [home, home.appendingPathComponent("sqlite")] : [sqlite]
        let databases = try directories.flatMap { directory -> [URL] in
            guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
        }
        // An ambiguous active database is not safe to mutate based on mtime alone.
        guard databases.count == 1, let database = databases.first else {
            throw HistoryRepairError.unsafe("需明确选择仅包含一个 state_*.sqlite 的 SQLite 目录。Select a SQLite directory containing exactly one state database.")
        }
        let rows = try SQLiteDatabase(path: database.path, readonly: true).entrypointRows()
        let roots = [home.appendingPathComponent("sessions"), home.appendingPathComponent("archived_sessions")]
        var nodes: [String: [HistoryNode]] = [:]
        var issues: [String: [String]] = [:]
        // An unparseable rollout filename cannot be assigned to a logical thread
        // by ID. Keep the warning scoped to its directory instead of making one
        // stray artifact block every conversation in the Codex home.
        var unknownByDirectory: [String: [String]] = [:]
        var warnings: [String] = []
        for url in try rolloutFiles(roots: roots) {
            if Self.isIgnoredArtifact(url) {
                continue
            }
            guard let ids = Self.ids(in: url) else {
                warnings.append("无法识别文件名 / Unknown filename: \(url.lastPathComponent)")
                unknownByDirectory[Self.directoryKey(url), default: []].append(url.lastPathComponent)
                continue
            }
            do {
                guard roots.contains(where: { Self.isInside(url, root: $0) }) else {
                    throw HistoryRepairError.unsafe("符号链接越界 / Symlink outside sessions")
                }
                guard let first = try Self.firstLine(url) else {
                    throw HistoryRepairError.unsafe("空文件 / Empty rollout")
                }
                let header = try JSONDecoder().decode(RolloutHeader.self, from: first)
                guard header.type == "session_meta", header.payload.id == ids.logical else {
                    throw HistoryRepairError.unsafe("文件 ID 与 metadata 不匹配 / ID mismatch")
                }
                guard header.payload.history_mode == "paginated", let start = header.ordinal else {
                    // Legacy files are intentionally not repairable by this service.
                    throw HistoryRepairError.unsafe("非分页或未知格式 / Unsupported history format")
                }
                nodes[ids.logical, default: []].append(HistoryNode(url: url, logicalID: ids.logical,
                    physicalID: ids.physical, start: start, base: header.payload.history_base))
            } catch {
                issues[ids.logical, default: []].append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        let globalByPhysicalID = Dictionary(grouping: nodes.values.flatMap { $0 }, by: \.physicalID)
        var diagnoses: [HistoryDiagnosis] = []
        for row in rows where row.fields["history_mode"]?.value == "paginated" {
            let group = nodes[row.id] ?? []
            do {
                if let errors = issues[row.id], !errors.isEmpty {
                    throw HistoryRepairError.unsafe(errors.joined(separator: "\n"))
                }
                let chain = try Self.chain(group, row: row, globalByPhysicalID: globalByPhysicalID)
                let checked = try Self.validate(chain)
                let leaf = chain.last!
                let unchanged = leaf.url.standardizedFileURL.path == URL(fileURLWithPath: row.path).standardizedFileURL.path
                let blocked = unknownByDirectory[Self.directoryKey(URL(fileURLWithPath: row.path))]?.isEmpty == false
                diagnoses.append(HistoryDiagnosis(proposedPath: unchanged || blocked ? nil : leaf.url.path,
                    detail: unchanged ? "入口已指向唯一末端；未验证客户端读取。Entrypoint is current; client reading not verified."
                        : blocked ? "扫描存在无法识别的文件，禁止自动修复。Unknown files block automatic repair."
                        : "发现唯一后继链，序号与字节边界一致。Unique successor chain; ordinal and byte boundaries agree.",
                    messageCount: checked.messages, row: row, files: checked.files))
            } catch {
                diagnoses.append(HistoryDiagnosis(proposedPath: nil, detail: error.localizedDescription,
                    messageCount: 0, row: row, files: []))
            }
        }
        return HistoryScan(database: database, codexHome: home, diagnoses: diagnoses, warnings: warnings)
    }

    public func repair(_ diagnosis: HistoryDiagnosis, scan: HistoryScan, settings: AppSettings) throws -> HistoryRepairRecord {
        try requireStopped()
        guard let target = diagnosis.proposedPath else { throw HistoryRepairError.stale }
        let fresh = try self.scan(settings: settings)
        guard fresh.database == scan.database, fresh.codexHome == scan.codexHome,
              let current = fresh.diagnoses.first(where: { $0.id == diagnosis.id }),
              current.row == diagnosis.row, current.files == diagnosis.files, current.proposedPath == target else {
            throw HistoryRepairError.stale
        }
        let root = backupRoot(settings: settings)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = root.appendingPathComponent(UUID().uuidString)
        try FileUtilities.ensureDirectory(directory)
        let db = try SQLiteDatabase(path: fresh.database.path, readonly: true)
        let snapshot = directory.appendingPathComponent("state-before.sqlite")
        try db.backup(to: snapshot)
        // Keep byte-for-byte copies of the chain, with original filenames, as repair evidence.
        let sources = directory.appendingPathComponent("sources")
        try FileUtilities.ensureDirectory(sources)
        for file in diagnosis.files {
            let copy = sources.appendingPathComponent(URL(fileURLWithPath: file.path).lastPathComponent)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: file.path), to: copy)
            guard try Self.hash(copy) == file.sha256 else { throw HistoryRepairError.stale }
        }
        let trialURL = directory.appendingPathComponent("state-trial.sqlite")
        try SQLiteDatabase(path: snapshot.path, readonly: true).backup(to: trialURL)
        let trial = try SQLiteDatabase(path: trialURL.path, readonly: false)
        let after = try trial.changeEntrypoint(expected: diagnosis.row, to: target) {}
        guard after.path == target else { throw HistoryRepairError.unsafe("副本试写后的对话入口不符合预期。Trial entrypoint did not match the requested path.") }
        let record = HistoryRepairRecord(directory: directory.path, threadID: diagnosis.id, title: diagnosis.title,
            createdAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)), oldPath: diagnosis.currentPath, newPath: target)
        let manifest = HistoryManifest(record: record, database: fresh.database.path, codexHome: fresh.codexHome.path,
            before: diagnosis.row, after: after, files: diagnosis.files)
        try JSONEncoder.codexSynced.encode(manifest).write(to: directory.appendingPathComponent("history-repair.json"), options: .atomic)
        // Recheck the catalogue after copying so a newly created branch cannot be missed.
        let recheck = try self.scan(settings: settings)
        guard let candidate = recheck.diagnoses.first(where: { $0.id == diagnosis.id }),
              candidate.files == diagnosis.files, candidate.row == diagnosis.row, candidate.proposedPath == target else {
            throw HistoryRepairError.stale
        }
        try requireStopped()
        let writable = try SQLiteDatabase(path: fresh.database.path, readonly: false, create: false)
        _ = try writable.changeEntrypoint(expected: diagnosis.row, to: target) {
            try self.requireStopped()
            try Self.verifyFiles(diagnosis.files)
        }
        return record
    }

    public func rollback(_ record: HistoryRepairRecord, settings: AppSettings) throws {
        try requireStopped()
        let directory = URL(fileURLWithPath: record.directory)
        guard Self.isInside(directory, root: backupRoot(settings: settings)) else { throw HistoryRepairError.stale }
        let data = try Data(contentsOf: directory.appendingPathComponent("history-repair.json"))
        let manifest = try JSONDecoder.codexSynced.decode(HistoryManifest.self, from: data)
        let fresh = try scan(settings: settings)
        guard manifest.version == 1, manifest.record == record,
              manifest.database == fresh.database.path, manifest.codexHome == fresh.codexHome.path,
              let current = fresh.diagnoses.first(where: { $0.id == record.threadID }),
              current.row == manifest.after, current.files == manifest.files else { throw HistoryRepairError.stale }
        let db = try SQLiteDatabase(path: manifest.database, readonly: false, create: false)
        _ = try db.changeEntrypoint(expected: manifest.after, to: manifest.before.path) {
            try self.requireStopped()
            try Self.verifyFiles(manifest.files)
        }
    }

    public func records(settings: AppSettings) throws -> [HistoryRepairRecord] {
        let root = backupRoot(settings: settings)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("history-repair.json")),
                  let manifest = try? JSONDecoder.codexSynced.decode(HistoryManifest.self, from: data),
                  manifest.version == 1,
                  URL(fileURLWithPath: manifest.record.directory).standardizedFileURL == dir.standardizedFileURL else { return nil }
            return manifest.record
        }.sorted { $0.createdAt > $1.createdAt }
    }

    public func backupRoot(settings: AppSettings) -> URL {
        CodexPathResolver.effectiveCodexHome(settings: settings).appendingPathComponent("history-entrypoint-backups")
    }

    private func requireStopped() throws {
        guard !isRunning() else { throw CodexRepairError.codexIsRunning }
    }

    private static func hasCodexWriter() -> Bool {
        if CodexRepairService().isCodexRunning() { return true }
        // Desktop may be closed while a CLI/app-server still owns a writer.
        // Fail closed when process discovery itself fails; never terminate anything.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let commands = String(data: data, encoding: .utf8) else { return true }
            return commands.split(separator: "\n").contains { command in
                let name = (String(command).trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent.lowercased()
                return name == "codex" || name == "codex-cli" || name == "codex-app-server"
            }
        } catch { return true }
    }

    private static func chain(_ nodes: [HistoryNode], row: EntrypointRow, globalByPhysicalID: [String: [HistoryNode]]) throws -> [HistoryNode] {
        guard !nodes.isEmpty else { throw HistoryRepairError.unsafe("找不到原始分支文件 / Missing rollout") }
        let byID = Dictionary(grouping: nodes, by: \.physicalID)
        guard byID.values.allSatisfy({ $0.count == 1 }) else {
            throw HistoryRepairError.unsafe("重复物理 ID / Duplicate physical ID")
        }
        let parents = Set(nodes.compactMap { $0.base?.thread_id })
        let leaves = nodes.filter { !parents.contains($0.physicalID) }
        guard leaves.count == 1 else {
            throw HistoryRepairError.unsafe("多个末端或分支循环，不自动选择 / Ambiguous tips or cycle")
        }
        var reversed: [HistoryNode] = []
        var visited = Set<String>()
        var cursor: HistoryNode? = leaves[0]
        while let node = cursor {
            guard visited.insert(node.physicalID).inserted else { throw HistoryRepairError.unsafe("分支循环 / Cycle") }
            reversed.append(node)
            if let base = node.base {
                let localParent = byID[base.thread_id]?.first
                let globalParents = globalByPhysicalID[base.thread_id] ?? []
                guard let parent = localParent ?? (globalParents.count == 1 ? globalParents[0] : nil) else {
                    throw HistoryRepairError.unsafe("父分支缺失 / Missing parent: \(base.thread_id)")
                }
                cursor = parent
            } else {
                guard node.start == 0 else {
                    throw HistoryRepairError.unsafe("原始根分支无法确认 / Unconfirmed root")
                }
                cursor = nil
            }
        }
        let localIDs = Set(nodes.map(\.physicalID))
        guard localIDs.isSubset(of: visited),
              nodes.contains(where: { $0.url.standardizedFileURL.path == URL(fileURLWithPath: row.path).standardizedFileURL.path }) else {
            throw HistoryRepairError.unsafe("入口不在完整的唯一分支链上 / Entrypoint not on a unique complete chain")
        }
        return reversed.reversed()
    }

    private static func validate(_ chain: [HistoryNode]) throws -> (files: [HistoryFile], messages: Int) {
        var files: [HistoryFile] = []
        var messages = 0
        for (index, node) in chain.enumerated() {
            let boundary = index + 1 < chain.count ? chain[index + 1].base : nil
            if let base = node.base, base.end_ordinal_exclusive != node.start {
                throw HistoryRepairError.unsafe("继承序号不连续 / Noncontiguous inherited ordinal")
            }
            var expected = node.start
            var boundaryFound = boundary == nil
            var endOffset: Int64 = 0
            var digest = SHA256()
            try lines(node.url) { data, offset, length in
                digest.update(data: data)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let number = json["ordinal"] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue == Double(number.int64Value), number.int64Value == expected else {
                    throw HistoryRepairError.unsafe("序号缺失、重复或乱序 / Invalid ordinal: \(node.url.lastPathComponent)")
                }
                if let boundary, expected == boundary.end_ordinal_exclusive {
                    guard offset == boundary.end_byte_offset else {
                        throw HistoryRepairError.unsafe("字节偏移不一致 / Byte boundary mismatch: \(node.url.lastPathComponent)")
                    }
                    boundaryFound = true
                }
                if boundary == nil || expected < boundary!.end_ordinal_exclusive {
                    if json["type"] as? String == "response_item", let payload = json["payload"] as? [String: Any],
                       payload["type"] as? String == "message", let role = payload["role"] as? String,
                       role == "user" || role == "assistant" { messages += 1 }
                }
                guard expected < Int64.max else { throw HistoryRepairError.unsafe("Ordinal overflow") }
                expected += 1
                endOffset = offset + length
            }
            if let boundary, boundary.end_ordinal_exclusive == expected, boundary.end_byte_offset == endOffset {
                boundaryFound = true
            }
            guard boundaryFound else { throw HistoryRepairError.unsafe("继承边界不在父文件中 / Boundary outside parent") }
            files.append(HistoryFile(path: node.url.path, sha256: digest.finalize().map { String(format: "%02x", $0) }.joined()))
        }
        return (files, messages)
    }

    private func rolloutFiles(roots: [URL]) throws -> [URL] {
        var result: [URL] = []
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            var enumerationError: Error?
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], errorHandler: { _, error in
                enumerationError = error
                return false
            }) else { throw HistoryRepairError.unsafe("无法遍历会话目录 / Cannot enumerate sessions") }
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { throw HistoryRepairError.unsafe("会话目录含符号链接，需人工检查 / Symlink requires manual review") }
                if values.isRegularFile == true, url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("rollout-") { result.append(url) }
            }
            if let enumerationError { throw enumerationError }
        }
        return result.sorted { $0.path < $1.path }
    }

    private static func ids(in url: URL) -> (logical: String, physical: String)? {
        let uuid = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        let name = url.lastPathComponent
        guard let regex = try? NSRegularExpression(pattern: "^rollout-.+-(\(uuid))(?:_(\(uuid)))?\\.jsonl$"),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let logicalRange = Range(match.range(at: 1), in: name) else { return nil }
        let logical = String(name[logicalRange])
        let physical = Range(match.range(at: 2), in: name).map { String(name[$0]) } ?? logical
        return (logical, physical)
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
    }

    private static func directoryKey(_ url: URL) -> String {
        url.deletingLastPathComponent().standardizedFileURL.path
    }

    /// Session folders occasionally contain editor leftovers and copied repair
    /// evidence. They are not rollout inputs and must not poison a scan.
    private static func isIgnoredArtifact(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasPrefix(".") ||
            name.contains(".codex-synced-") ||
            name.hasSuffix("_repaired.jsonl") ||
            name.hasSuffix(".bak.jsonl") ||
            name.hasSuffix(".tmp.jsonl")
    }

    private static func firstLine(_ url: URL) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if let index = chunk.firstIndex(of: 10) { data.append(chunk[...index]); return data }
            data.append(chunk)
            guard data.count <= 64 * 1024 * 1024 else { throw HistoryRepairError.unsafe("Metadata too large") }
        }
        return data.isEmpty ? nil : data
    }

    /// Streaming byte offsets; newline bytes remain part of the digest and offsets.
    private static func lines(_ url: URL, visit: (Data, Int64, Int64) throws -> Void) throws {
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
            guard pending.count <= 64 * 1024 * 1024 else { throw HistoryRepairError.unsafe("JSONL line too large") }
        }
        if !pending.isEmpty { try visit(pending, offset, Int64(pending.count)) }
    }

    private static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func verifyFiles(_ files: [HistoryFile]) throws {
        for file in files where try hash(URL(fileURLWithPath: file.path)) != file.sha256 { throw HistoryRepairError.stale }
    }
}

extension HistoryRepairRecord: Equatable {}
