import Foundation

enum SidebarRepairPlanner {
    private static let sidebarTitleLimit = 80

    struct RolloutInfo {
        var provider: String?
        var historyMode: String?
        var firstTimestampMs: Int64?
        var lastTimestampMs: Int64?
    }

    static func rolloutInfoByPath(for threads: [ThreadRow]) -> [String: RolloutInfo] {
        var result: [String: RolloutInfo] = [:]
        for path in Set(threads.map(\.rolloutPath)).filter({ !$0.isEmpty }) {
            result[path] = inspectRollout(path: path)
        }
        return result
    }

    static func providerRepairs(threads: [ThreadRow], rollouts: [String: RolloutInfo]) -> [ProviderRepair] {
        threads.compactMap { thread in
            guard let provider = rollouts[thread.rolloutPath]?.provider,
                  !provider.isEmpty,
                  provider != thread.modelProvider else {
                return nil
            }
            return ProviderRepair(thread: thread, targetProvider: provider)
        }
    }

    static func providerAlignmentRepairs(threads: [ThreadRow], targetProvider: String) -> [ProviderRepair] {
        guard !targetProvider.isEmpty else { return [] }
        return providerAlignmentThreads(threads)
            .filter { $0.modelProvider != targetProvider }
            .map { ProviderRepair(thread: $0, targetProvider: targetProvider) }
    }

    static func rolloutProviderAlignmentRepairs(threads: [ThreadRow], targetProvider: String) -> [RolloutRepair] {
        guard !targetProvider.isEmpty else { return [] }
        var seen = Set<String>()
        return providerAlignmentThreads(threads).compactMap { thread in
            guard seen.insert(thread.rolloutPath).inserted else { return nil }
            return RolloutRepairer.makeRepair(url: URL(fileURLWithPath: thread.rolloutPath), targetProvider: targetProvider)
        }
    }

    static func paginatedProviderWarnings(threads: [ThreadRow], rollouts: [String: RolloutInfo], targetProvider: String) -> [PaginatedProviderWarning] {
        guard !targetProvider.isEmpty else { return [] }
        return providerAlignmentThreads(threads).compactMap { thread in
            guard let info = rollouts[thread.rolloutPath],
                  info.historyMode == "paginated",
                  let provider = info.provider,
                  !provider.isEmpty,
                  provider != targetProvider else {
                return nil
            }
            return PaginatedProviderWarning(
                threadID: thread.id,
                title: thread.title,
                rolloutPath: thread.rolloutPath,
                currentProvider: provider,
                targetProvider: targetProvider
            )
        }
    }

    static func timestampRepairs(threads: [ThreadRow], rollouts: [String: RolloutInfo]) -> [TimestampRepair] {
        threads.compactMap { thread in
            guard let info = rollouts[thread.rolloutPath] else {
                return nil
            }
            let currentUpdatedAtMs = thread.effectiveUpdatedAtMs
            let targetUpdatedAtMs = info.lastTimestampMs ?? currentUpdatedAtMs
            let updatedChanged = abs(currentUpdatedAtMs - targetUpdatedAtMs) > 1000

            let currentCreatedAtMs = thread.effectiveCreatedAtMs
            let targetCreatedAtMs: Int64?
            if currentCreatedAtMs > targetUpdatedAtMs {
                targetCreatedAtMs = [info.firstTimestampMs, thread.effectiveRecencyAtMs]
                    .compactMap { $0 }
                    .filter { $0 > 0 && $0 <= targetUpdatedAtMs }
                    .min() ?? targetUpdatedAtMs
            } else {
                targetCreatedAtMs = nil
            }

            guard updatedChanged || targetCreatedAtMs != nil else {
                return nil
            }
            return TimestampRepair(
                threadID: thread.id,
                title: thread.title,
                currentUpdatedAtMs: currentUpdatedAtMs,
                targetUpdatedAtMs: targetUpdatedAtMs,
                currentCreatedAtMs: currentCreatedAtMs,
                targetCreatedAtMs: targetCreatedAtMs
            )
        }
    }

    static func titleRepairs(threads: [ThreadRow]) -> [TitleRepair] {
        threads
            .filter { sidebarSourceKind($0.source) != nil && rolloutExists($0.rolloutPath) }
            .sorted { ($0.effectiveUpdatedAtMs, $0.id) < ($1.effectiveUpdatedAtMs, $1.id) }
            .compactMap { thread in
                let title = normalizeTitleText(thread.title)
                let first = normalizeTitleText(thread.firstUserMessage)
                let corrupted = looksCorruptedTitle(title)
                guard title.isEmpty || title == first || corrupted else {
                    return nil
                }
                let seed = title.isEmpty || corrupted
                    ? (thread.preview.isEmpty ? thread.firstUserMessage : thread.preview)
                    : thread.title
                let next = shortenSidebarTitle(seed, cwd: thread.cwd, firstUserMessage: thread.firstUserMessage)
                guard !next.isEmpty, next != thread.title else {
                    return nil
                }
                return TitleRepair(threadID: thread.id, currentTitle: thread.title, targetTitle: next)
            }
    }

    static func rolloutMtimeRepairs(threads: [ThreadRow], rollouts: [String: RolloutInfo]) -> [RolloutMtimeRepair] {
        threads.compactMap { thread in
            guard !thread.archived,
                  resumeSourceKind(thread.source) != nil,
                  let target = rollouts[thread.rolloutPath]?.lastTimestampMs,
                  let current = rolloutMtimeMs(path: thread.rolloutPath),
                  abs(current - target) > 1000 else {
                return nil
            }
            return RolloutMtimeRepair(
                threadID: thread.id,
                title: thread.title,
                rolloutPath: thread.rolloutPath,
                currentMtimeMs: current,
                targetMtimeMs: target
            )
        }
    }

    static func indexRepairs(codexHome: URL, threads: [ThreadRow]) -> [IndexRepair] {
        let desired = resumeInventory(threads: threads)
        let current = loadIndexEntries(codexHome.appendingPathComponent("session_index.jsonl"))
        guard current != desired else {
            return []
        }
        return desired
    }

    static func projectedThreads(threads: [ThreadRow], titleRepairs: [TitleRepair], timestampRepairs: [TimestampRepair]) -> [ThreadRow] {
        let titleByID = Dictionary(uniqueKeysWithValues: titleRepairs.map { ($0.threadID, $0.targetTitle) })
        let timestampByID = Dictionary(uniqueKeysWithValues: timestampRepairs.map { ($0.threadID, $0.targetUpdatedAtMs) })
        let createdAtByID = Dictionary(uniqueKeysWithValues: timestampRepairs.compactMap { repair in
            repair.targetCreatedAtMs.map { (repair.threadID, $0) }
        })
        return threads.map { thread in
            var next = thread
            if let title = titleByID[thread.id] {
                next.title = title
            }
            if let timestamp = timestampByID[thread.id] {
                next.updatedAt = timestamp / 1000
                next.updatedAtMs = timestamp
            }
            if let timestamp = createdAtByID[thread.id] {
                next.createdAt = timestamp / 1000
                next.createdAtMs = timestamp
            }
            return next
        }
    }

    static func rebuildSessionIndex(_ entries: [IndexRepair], codexHome: URL) throws {
        let indexURL = codexHome.appendingPathComponent("session_index.jsonl")
        try FileUtilities.ensureDirectory(indexURL.deletingLastPathComponent())
        let lines = entries.map { entry -> String in
            let object = [
                "id": entry.threadID,
                "thread_name": entry.title,
                "updated_at": isoFromMs(entry.updatedAtMs)
            ]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return String(data: data, encoding: .utf8) ?? ""
        }
        try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: indexURL, atomically: true, encoding: .utf8)
    }

    static func applyRolloutMtimes(_ repairs: [RolloutMtimeRepair]) throws {
        for repair in repairs {
            let date = Date(timeIntervalSince1970: TimeInterval(repair.targetMtimeMs) / 1000)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: repair.rolloutPath)
        }
    }

    static func restoreRolloutMtimes(_ items: [BackupManifest.MtimeItem]) throws {
        for item in items {
            let date = Date(timeIntervalSince1970: TimeInterval(item.modifiedAtMs) / 1000)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: item.originalPath)
        }
    }

    static func globalStateRepair(codexHome: URL, threads: [ThreadRow]) -> GlobalStateRepair? {
        let url = codexHome.appendingPathComponent(".codex-global-state.json")
        guard let data = try? Data(contentsOf: url),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        var changes: [String] = []

        if let selected = object["selected-remote-host-id"] as? String,
           selected.hasPrefix("remote-control:") {
            object["selected-remote-host-id"] = "local"
            changes.append("selected-remote-host-id -> local")
        }

        if var auto = object["remote-connection-auto-connect-by-host-id"] as? [String: Any] {
            for key in auto.keys where key.hasPrefix("remote-control:") {
                auto.removeValue(forKey: key)
                changes.append("removed remote-control auto-connect entry")
            }
            object["remote-connection-auto-connect-by-host-id"] = auto
        }

        if let added = object["added-remote-control-env-ids"] as? [Any] {
            let local = object["electron-local-remote-control-environment-id"] as? String
            let filtered = added.compactMap { $0 as? String }.filter { $0 == local }
            if filtered.count != added.count {
                object["added-remote-control-env-ids"] = filtered
                changes.append("removed stale remote-control env ids")
            }
        }

        let saved = (object["electron-saved-workspace-roots"] as? [Any])?.compactMap { $0 as? String } ?? []
        let savedSet = Set(saved)
        var order = (object["project-order"] as? [Any])?.compactMap { $0 as? String } ?? []
        var orderSet = Set(order)

        for root in localProjectRoots(threads: threads) where savedSet.contains(root) && !orderSet.contains(root) {
            order.append(root)
            orderSet.insert(root)
            changes.append("added project-order \(root)")
        }
        object["project-order"] = order

        guard !changes.isEmpty,
              let repairedData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let repairedJSON = String(data: repairedData, encoding: .utf8) else {
            return nil
        }
        return GlobalStateRepair(changes: changes, repairedJSON: repairedJSON + "\n")
    }

    static func applyGlobalStateRepair(_ repair: GlobalStateRepair, codexHome: URL) throws {
        let url = codexHome.appendingPathComponent(".codex-global-state.json")
        try repair.repairedJSON.write(to: url, atomically: true, encoding: .utf8)
    }

    static func resumeSourceKind(_ source: String) -> String? {
        if source == "vscode" || source == "cli" || source == "exec" {
            return source
        }
        if source == "subagent:thread_spawn" || source.contains("thread_spawn") {
            return "subagent:thread_spawn"
        }
        return nil
    }

    private static func sidebarSourceKind(_ source: String) -> String? {
        if source == "vscode" || source == "cli" || source == "exec" {
            return source
        }
        return nil
    }

    private static func localProjectRoots(threads: [ThreadRow]) -> [String] {
        var seen = Set<String>()
        var roots: [String] = []
        for thread in visibleResumeThreads(threads) {
            guard !thread.cwd.isEmpty, !seen.contains(thread.cwd) else {
                continue
            }
            seen.insert(thread.cwd)
            roots.append(thread.cwd)
        }
        return roots
    }

    private static func resumeInventory(threads: [ThreadRow]) -> [IndexRepair] {
        threads
            .filter { rolloutExists($0.rolloutPath) }
            .sorted { ($0.effectiveUpdatedAtMs, $0.id) < ($1.effectiveUpdatedAtMs, $1.id) }
            .map { IndexRepair(threadID: $0.id, title: $0.title, updatedAtMs: $0.effectiveUpdatedAtMs) }
    }

    private static func providerAlignmentThreads(_ threads: [ThreadRow]) -> [ThreadRow] {
        threads
            .filter { sidebarSourceKind($0.source) != nil && rolloutExists($0.rolloutPath) }
            .sorted { ($0.effectiveUpdatedAtMs, $0.id) < ($1.effectiveUpdatedAtMs, $1.id) }
    }

    private static func visibleResumeThreads(_ threads: [ThreadRow]) -> [ThreadRow] {
        threads
            .filter { !$0.archived && resumeSourceKind($0.source) != nil && rolloutExists($0.rolloutPath) }
            .sorted { ($0.effectiveUpdatedAtMs, $0.id) < ($1.effectiveUpdatedAtMs, $1.id) }
    }

    private static func loadIndexEntries(_ url: URL) -> [IndexRepair] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        var seen = Set<String>()
        var entries: [IndexRepair] = []
        for line in content.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String,
                  !seen.contains(id) else {
                return []
            }
            seen.insert(id)
            let title = object["thread_name"] as? String ?? ""
            let updatedAtMs = parseTimestampMs(object["updated_at"] as? String) ?? 0
            entries.append(IndexRepair(threadID: id, title: title, updatedAtMs: updatedAtMs))
        }
        return entries
    }

    private static func inspectRollout(path: String) -> RolloutInfo {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return RolloutInfo()
        }
        var provider: String?
        var historyMode: String?
        var firstTimestampMs: Int64?
        var lastTimestampMs: Int64?
        for line in content.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if provider == nil,
               let payload = object["payload"] as? [String: Any],
               let value = payload["model_provider"] as? String {
                provider = value
            }
            if historyMode == nil,
               let payload = object["payload"] as? [String: Any],
               let value = payload["history_mode"] as? String {
                historyMode = value
            }
            if let timestamp = object["timestamp"] as? String,
               let parsed = parseTimestampMs(timestamp) {
                if firstTimestampMs == nil {
                    firstTimestampMs = parsed
                }
                lastTimestampMs = parsed
            }
        }
        return RolloutInfo(provider: provider, historyMode: historyMode, firstTimestampMs: firstTimestampMs, lastTimestampMs: lastTimestampMs)
    }

    private static func rolloutExists(_ path: String) -> Bool {
        !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    private static func rolloutMtimeMs(path: String) -> Int64? {
        guard !path.isEmpty,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attributes[.modificationDate] as? Date else {
            return nil
        }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private static func normalizeTitleText(_ value: String) -> String {
        var text = value
        text = text.replacingOccurrences(of: #"<image\b[^>]*>.*?</image>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<appshot\b[^>]*>.*?</appshot>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"\[([^\]]{1,120})\]\([^)]+\)"#, with: "$1", options: [.regularExpression])
        return text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksCorruptedTitle(_ value: String) -> Bool {
        let markers = [
            "to=functions.",
            "to be plain",
            "need plain text",
            "not xml",
            "wait there is extra",
            "'}]}",
            "}】"
        ]
        return markers.contains { value.range(of: $0, options: .caseInsensitive) != nil }
    }

    private static func shortenSidebarTitle(_ value: String, cwd: String, firstUserMessage: String) -> String {
        var text = normalizeTitleText(value)
        if text.isEmpty {
            text = "Codex thread"
        }
        if let end = text.firstIndex(where: { "。！？!?".contains($0) }) {
            text = String(text[...end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.count > sidebarTitleLimit {
            text = String(text.prefix(sidebarTitleLimit - 3)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
        }
        let first = normalizeTitleText(firstUserMessage)
        if text == first {
            let project = URL(fileURLWithPath: cwd).lastPathComponent.isEmpty ? "conversation" : URL(fileURLWithPath: cwd).lastPathComponent
            text = "\(text) - \(project)"
            if text.count > sidebarTitleLimit {
                text = String(text.prefix(sidebarTitleLimit - 3)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
            }
        }
        return text
    }

    private static func parseTimestampMs(_ value: String?) -> Int64? {
        guard let value, !value.isEmpty else {
            return nil
        }
        let formatterWithFraction = ISO8601DateFormatter()
        formatterWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatterWithFraction.date(from: value) ?? formatter.date(from: value) else {
            return nil
        }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private static func isoFromMs(_ value: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(value) / 1000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: date)
    }
}
