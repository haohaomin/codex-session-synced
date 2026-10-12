import Foundation

enum RolloutRepairer {
    // Only rewrites the first session_meta line; message bodies stay untouched.
    static func makeRepair(url: URL, targetProvider: String) -> RolloutRepair? {
        guard let firstLine = firstLine(url: url) else { return nil }
        guard let data = firstLine.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "session_meta",
              var payload = object["payload"] as? [String: Any] else {
            return nil
        }

        // Descendants store byte offsets into parents. Even metadata rewrites can
        // invalidate those offsets; paginated files must remain byte-for-byte intact.
        guard payload["history_mode"] as? String != "paginated",
              payload["history_base"] == nil, object["ordinal"] == nil else { return nil }

        let current = payload["model_provider"] as? String
        guard current != targetProvider else { return nil }
        payload["model_provider"] = targetProvider
        object["payload"] = payload

        guard let repairedData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let repairedLine = String(data: repairedData, encoding: .utf8) else {
            return nil
        }

        let sessionID = payload["id"] as? String ?? url.deletingPathExtension().lastPathComponent
        return RolloutRepair(
            id: url.path,
            url: url,
            sessionID: sessionID,
            currentProvider: current,
            targetProvider: targetProvider,
            originalFirstLine: firstLine,
            repairedFirstLine: repairedLine
        )
    }

    static func apply(_ repair: RolloutRepair) throws {
        try replaceFirstLine(url: repair.url, with: repair.repairedFirstLine)
    }

    static func restore(url: URL, firstLine: String) throws {
        try replaceFirstLine(url: url, with: firstLine)
    }

    private static func replaceFirstLine(url: URL, with firstLine: String) throws {
        let fm = FileManager.default
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }

        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).codex-synced-\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: temp)
        do {
            try output.write(contentsOf: Data((firstLine + "\n").utf8))
            var foundNewline = false
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                if foundNewline {
                    try output.write(contentsOf: chunk)
                    continue
                }
                guard let newline = chunk.firstIndex(of: UInt8(ascii: "\n")) else {
                    continue
                }
                foundNewline = true
                let suffixStart = chunk.index(after: newline)
                if suffixStart < chunk.endIndex {
                    try output.write(contentsOf: chunk[suffixStart...])
                }
            }
            try output.close()
            if let permissions = try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] {
                try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
            }
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? output.close()
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    private static func firstLine(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var line = Data()
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            } catch {
                return nil
            }
            guard !chunk.isEmpty else { break }
            if let newline = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                line.append(contentsOf: chunk[..<newline])
                break
            }
            line.append(chunk)
        }
        if line.last == UInt8(ascii: "\r") {
            line.removeLast()
        }
        return String(data: line, encoding: .utf8)
    }
}
