using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace CodexSynced.Windows;

internal sealed record HistoryFile(string Path, string Sha256);
internal sealed record HistoryEntrypointRow(string Id, string RolloutPath, string Title, string HistoryMode);

internal sealed record HistoryDiagnosis(
    string Id,
    string Title,
    string CurrentPath,
    string? ProposedPath,
    string Detail,
    int MessageCount,
    List<HistoryFile> Files)
{
    public bool CanRepair => !string.IsNullOrWhiteSpace(ProposedPath);
}

internal sealed record HistoryScanResult(
    string Database,
    string CodexHome,
    List<HistoryDiagnosis> Diagnoses,
    List<string> Warnings);

internal sealed record HistoryRepairRecord(
    string Directory,
    string ThreadId,
    string Title,
    DateTime CreatedAt,
    string OldPath,
    string NewPath);

internal sealed class HistoryEntrypointService
{
    private sealed record Base(string ThreadId, long EndOrdinal, long EndOffset);
    private sealed record Boundary(long Ordinal, long Start, long End);
    private sealed record Node(string Path, string LogicalId, string PhysicalId, long Start, Base? HistoryBase, List<Boundary> Boundaries, string FirstLine, long FileLength);
    private sealed record Row(string Id, string Path, string Title, string HistoryMode);
    private sealed record Manifest(int Version, HistoryRepairRecord Record, string Database, string CodexHome, Row Before, Row After, List<HistoryFile> Files);
    private static readonly Regex RolloutName = new("^rollout-.+-(?<logical>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})(?:_(?<physical>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}))?\\.jsonl$", RegexOptions.Compiled | RegexOptions.CultureInvariant);

    public HistoryScanResult Scan(AppSettings settings)
    {
        var codexHome = Path.GetFullPath(settings.CodexHome);
        var configuredSQLite = settings.SqliteHome;
        if (string.IsNullOrWhiteSpace(configuredSQLite))
        {
            var parsed = ConfigParser.Parse(Path.Combine(codexHome, "config.toml"));
            if (parsed.Root.TryGetValue("sqlite_home", out var configured))
                configuredSQLite = ExpandPath(configured);
        }
        var sqliteHome = ResolveSQLiteHome(codexHome, configuredSQLite);
        var databases = Directory.Exists(sqliteHome)
            ? Directory.EnumerateFiles(sqliteHome, "state_*.sqlite", SearchOption.TopDirectoryOnly).ToList()
            : [];
        if (databases.Count != 1)
            throw new InvalidOperationException("对话修复要求明确选择仅包含一个 state_*.sqlite 的 SQLite 目录。");
        using var db = new SqliteDatabase(databases[0], true);
        var rows = db.QueryHistoryEntrypointRows().Where(row => row.HistoryMode.Equals("paginated", StringComparison.OrdinalIgnoreCase)).Select(row => new Row(row.Id, row.RolloutPath, row.Title, row.HistoryMode)).ToList();
        var warnings = new List<string>();
        var nodes = LoadNodes(codexHome, warnings);
        var global = nodes.GroupBy(node => node.PhysicalId, StringComparer.OrdinalIgnoreCase).ToDictionary(group => group.Key, group => group.ToList(), StringComparer.OrdinalIgnoreCase);
        var duplicate = global.FirstOrDefault(item => item.Value.Count > 1);
        if (duplicate.Value is { Count: > 1 })
            warnings.Add($"跨文件重复物理 ID：{duplicate.Key} / Duplicate physical ID across rollout files");
        var diagnoses = new List<HistoryDiagnosis>();
        foreach (var row in rows)
        {
            try
            {
                var local = nodes.Where(node => node.LogicalId.Equals(row.Id, StringComparison.OrdinalIgnoreCase)).ToList();
                var chain = BuildChain(local, row, global);
                var validation = Validate(chain);
                var leaf = chain[^1];
                var unchanged = SamePath(leaf.Path, row.Path);
                diagnoses.Add(new(row.Id, row.Title, row.Path, unchanged ? null : leaf.Path,
                    unchanged ? "入口已指向唯一末端；客户端读取仍需人工验收。Entrypoint is current; client reading still requires manual verification." : "发现唯一后继链，序号与字节边界一致。Unique successor chain; ordinal and byte boundaries agree.", validation.Messages, validation.Files));
            }
            catch (Exception error)
            {
                diagnoses.Add(new(row.Id, row.Title, row.Path, null, error.Message, 0, []));
            }
        }
        return new(databases[0], codexHome, diagnoses, warnings);
    }

    public HistoryRepairRecord Repair(HistoryScanResult scan, HistoryDiagnosis diagnosis, AppSettings settings, bool ignoreCodexRunning = false)
    {
        if (!ignoreCodexRunning && RepairService.IsCodexRunning())
            throw new InvalidOperationException("检测到 Codex 正在运行。请先退出 Codex，再修复对话入口。");
        if (!diagnosis.CanRepair || diagnosis.ProposedPath is null)
            throw new InvalidOperationException("该对话没有可安全修复的唯一后继入口。");
        var fresh = Scan(settings);
        var current = fresh.Diagnoses.FirstOrDefault(item => item.Id.Equals(diagnosis.Id, StringComparison.OrdinalIgnoreCase));
        if (current is null || !SameDiagnosis(current, diagnosis))
            throw new InvalidOperationException("对话修复预览已过期，请重新扫描。");
        var root = Path.Combine(scan.CodexHome, "history-entrypoint-backups");
        Directory.CreateDirectory(root);
        var directory = Path.Combine(root, DateTime.UtcNow.ToString("yyyyMMdd-HHmmssfff") + "-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var snapshot = Path.Combine(directory, "state-before.sqlite");
        using (var db = new SqliteDatabase(scan.Database, true)) db.BackupTo(snapshot);
        var copied = new List<HistoryFile>();
        var index = 0;
        foreach (var file in diagnosis.Files)
        {
            var relative = Path.Combine("sources", $"{index++}.jsonl");
            var destination = Path.Combine(directory, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            File.Copy(file.Path, destination, false);
            var hash = Hash(file.Path);
            if (!hash.Equals(file.Sha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("分支文件在备份时发生变化，拒绝修复。");
            copied.Add(file with { Path = file.Path });
        }
        var record = new HistoryRepairRecord(directory, diagnosis.Id, diagnosis.Title, DateTime.UtcNow, diagnosis.CurrentPath, diagnosis.ProposedPath);
        var before = new Row(diagnosis.Id, diagnosis.CurrentPath, diagnosis.Title, "paginated");
        var after = before with { Path = diagnosis.ProposedPath };
        var manifest = new Manifest(1, record, scan.Database, scan.CodexHome, before, after, diagnosis.Files);
        File.WriteAllText(Path.Combine(directory, "history-repair.json"), JsonSerializer.Serialize(manifest, JsonOptions.Pretty));
        var trial = Path.Combine(directory, "state-trial.sqlite");
        File.Copy(snapshot, trial, true);
        using (var trialDb = new SqliteDatabase(trial, false))
            trialDb.ChangeEntrypoint(diagnosis.Id, diagnosis.CurrentPath, diagnosis.ProposedPath);
        var recheck = Scan(settings);
        var recheckDiagnosis = recheck.Diagnoses.FirstOrDefault(item => item.Id.Equals(diagnosis.Id, StringComparison.OrdinalIgnoreCase));
        if (recheckDiagnosis is null || !SameDiagnosis(recheckDiagnosis, diagnosis))
            throw new InvalidOperationException("分支文件或状态在提交前发生变化，拒绝修复。");
        try
        {
            using var db = new SqliteDatabase(scan.Database, false);
            db.ChangeEntrypoint(diagnosis.Id, diagnosis.CurrentPath, diagnosis.ProposedPath);
            return record;
        }
        catch
        {
            RestoreSnapshot(snapshot, scan.Database);
            throw;
        }
    }

    public List<HistoryRepairRecord> Records(AppSettings settings)
    {
        var root = Path.Combine(Path.GetFullPath(settings.CodexHome), "history-entrypoint-backups");
        if (!Directory.Exists(root))
            return [];
        return Directory.EnumerateDirectories(root).Select(directory =>
        {
            try
            {
                var manifest = JsonSerializer.Deserialize<Manifest>(File.ReadAllText(Path.Combine(directory, "history-repair.json")), JsonOptions.Pretty);
                return manifest?.Record;
            }
            catch { return null; }
        }).Where(record => record is not null).Select(record => record!).OrderByDescending(record => record.CreatedAt).ToList();
    }

    public void Rollback(HistoryRepairRecord record, AppSettings settings, bool ignoreCodexRunning = false)
    {
        if (!ignoreCodexRunning && RepairService.IsCodexRunning())
            throw new InvalidOperationException("检测到 Codex 正在运行。请先退出 Codex，再撤销入口修复。");
        var root = Path.Combine(Path.GetFullPath(settings.CodexHome), "history-entrypoint-backups");
        var directory = Path.GetFullPath(record.Directory);
        if (!directory.StartsWith(Path.GetFullPath(root) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("修复记录不在当前 Codex Home 下。");
        var manifest = JsonSerializer.Deserialize<Manifest>(File.ReadAllText(Path.Combine(directory, "history-repair.json")), JsonOptions.Pretty)
            ?? throw new InvalidOperationException("修复记录损坏。");
        var scan = Scan(settings);
        var current = scan.Diagnoses.FirstOrDefault(item => item.Id.Equals(record.ThreadId, StringComparison.OrdinalIgnoreCase));
        if (current is null || !SamePath(current.CurrentPath, manifest.After.Path) || !current.Files.SequenceEqual(manifest.Files))
            throw new InvalidOperationException("目标记录或分支文件已变化，拒绝覆盖新消息。");
        using var db = new SqliteDatabase(manifest.Database, false);
        db.ChangeEntrypoint(record.ThreadId, manifest.After.Path, manifest.Before.Path);
    }

    private static bool SameDiagnosis(HistoryDiagnosis left, HistoryDiagnosis right) =>
        left.Id.Equals(right.Id, StringComparison.OrdinalIgnoreCase) &&
        SamePath(left.CurrentPath, right.CurrentPath) &&
        string.Equals(left.ProposedPath, right.ProposedPath, StringComparison.OrdinalIgnoreCase) &&
        left.Files.SequenceEqual(right.Files);

    private static List<Node> LoadNodes(string codexHome, List<string> warnings)
    {
        var result = new List<Node>();
        foreach (var rootName in new[] { "sessions", "archived_sessions" })
        {
            var root = Path.Combine(codexHome, rootName);
            if (!Directory.Exists(root)) continue;
            foreach (var path in Directory.EnumerateFiles(root, "rollout-*.jsonl", SearchOption.AllDirectories))
            {
                if (IsIgnored(path)) continue;
                if (!TryIds(path, out var logical, out var physical))
                {
                    warnings.Add($"无法识别文件名 / Unknown filename: {Path.GetFileName(path)}");
                    continue;
                }
                try
                {
                    var node = ParseNode(path, logical, physical);
                    if (node is not null) result.Add(node);
                }
                catch (Exception error) { warnings.Add($"{Path.GetFileName(path)}: {error.Message}"); }
            }
        }
        return result;
    }

    private static Node? ParseNode(string path, string logical, string physical)
    {
        var lines = ReadLines(path);
        if (lines.Count == 0) return null;
        var root = JsonNode.Parse(Encoding.UTF8.GetString(lines[0].Data))?.AsObject();
        if (root?["type"]?.GetValue<string>() != "session_meta" || root["payload"] is not JsonObject payload || payload["id"]?.GetValue<string>() != logical || payload["history_mode"]?.GetValue<string>() != "paginated") return null;
        var start = Int64(root["ordinal"]) ?? throw new InvalidOperationException("分页入口序号缺失。");
        var boundaries = new List<Boundary>();
        long expected = start;
        foreach (var line in lines)
        {
            var objectNode = JsonNode.Parse(Encoding.UTF8.GetString(line.Data))?.AsObject() ?? throw new InvalidOperationException("非法 JSON");
            var ordinal = Int64(objectNode["ordinal"]) ?? throw new InvalidOperationException("分页序号缺失");
            if (ordinal != expected) throw new InvalidOperationException("分页序号不连续");
            boundaries.Add(new(ordinal, line.Start, line.End));
            expected++;
        }
        Base? historyBase = null;
        if (payload["history_base"] is JsonObject raw)
        {
            var id = raw["thread_id"]?.GetValue<string>() ?? throw new InvalidOperationException("history_base.thread_id 缺失");
            historyBase = new Base(id, Int64(raw["end_ordinal_exclusive"]) ?? throw new InvalidOperationException("history_base 序号缺失"), Int64(raw["end_byte_offset"]) ?? throw new InvalidOperationException("history_base 偏移缺失"));
        }
        return new(path, logical, physical, start, historyBase, boundaries, Encoding.UTF8.GetString(lines[0].Data), lines[^1].End);
    }

    private static List<Node> BuildChain(List<Node> local, Row row, Dictionary<string, List<Node>> global)
    {
        if (local.Count == 0) throw new InvalidOperationException("找不到原始分支文件 / Missing rollout");
        if (local.GroupBy(node => node.PhysicalId, StringComparer.OrdinalIgnoreCase).Any(group => group.Count() > 1)) throw new InvalidOperationException("重复物理 ID / Duplicate physical ID");
        var parents = local.Where(node => node.HistoryBase is not null).Select(node => node.HistoryBase!.ThreadId).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var leaves = local.Where(node => !parents.Contains(node.PhysicalId)).ToList();
        if (leaves.Count != 1) throw new InvalidOperationException("多个末端或分支循环，不自动选择 / Ambiguous tips or cycle");
        var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var reversed = new List<Node>();
        Node? cursor = leaves[0];
        while (cursor is not null)
        {
            if (!visited.Add(cursor.PhysicalId)) throw new InvalidOperationException("分支循环 / Cycle");
            reversed.Add(cursor);
            if (cursor.HistoryBase is { } baseInfo)
            {
                var localParent = local.Where(node => node.PhysicalId.Equals(baseInfo.ThreadId, StringComparison.OrdinalIgnoreCase)).ToList();
                var globalParent = global.TryGetValue(baseInfo.ThreadId, out var list) ? list : [];
                cursor = localParent.Count == 1 ? localParent[0] : globalParent.Count == 1 ? globalParent[0] : throw new InvalidOperationException($"父分支缺失：{baseInfo.ThreadId}");
            }
            else { if (cursor.Start != 0) throw new InvalidOperationException("原始根分支无法确认"); cursor = null; }
        }
        if (local.Any(node => !visited.Contains(node.PhysicalId)) || !visited.Any(id => local.Any(node => node.PhysicalId == id && SamePath(node.Path, row.Path)))) throw new InvalidOperationException("入口不在完整分支链上");
        var chain = reversed.AsEnumerable().Reverse().ToList();
        for (var index = 0; index < chain.Count; index++)
        {
            var node = chain[index];
            if (node.HistoryBase is { } baseInfo)
            {
                var parent = chain.FirstOrDefault(item => item.PhysicalId.Equals(baseInfo.ThreadId, StringComparison.OrdinalIgnoreCase));
                if (baseInfo.EndOrdinal != node.Start || parent is null || OffsetForOrdinal(baseInfo.EndOrdinal, parent) != baseInfo.EndOffset) throw new InvalidOperationException("字节边界不一致 / Byte boundary mismatch");
            }
            if (index + 1 < chain.Count && chain[index + 1].HistoryBase is { } next && (!next.ThreadId.Equals(node.PhysicalId, StringComparison.OrdinalIgnoreCase) || OffsetForOrdinal(next.EndOrdinal, node) != next.EndOffset)) throw new InvalidOperationException("后继边界不一致");
        }
        return chain;
    }

    private static (List<HistoryFile> Files, int Messages) Validate(List<Node> chain)
    {
        var files = new List<HistoryFile>();
        var messages = 0;
        for (var index = 0; index < chain.Count; index++)
        {
            var boundary = index + 1 < chain.Count ? chain[index + 1].HistoryBase : null;
            var expected = chain[index].Start;
            foreach (var line in ReadLines(chain[index].Path))
            {
                var objectNode = JsonNode.Parse(Encoding.UTF8.GetString(line.Data))?.AsObject() ?? throw new InvalidOperationException("非法 JSON");
                var ordinal = Int64(objectNode["ordinal"]) ?? throw new InvalidOperationException("分页序号缺失");
                if (ordinal != expected) throw new InvalidOperationException("序号缺失、重复或乱序");
                if (boundary is not null && ordinal == boundary.EndOrdinal && line.Start != boundary.EndOffset) throw new InvalidOperationException("字节边界不一致");
                if ((boundary is null || ordinal < boundary.EndOrdinal) && objectNode["type"]?.GetValue<string>() == "response_item" && objectNode["payload"] is JsonObject payload && payload["type"]?.GetValue<string>() == "message" && (payload["role"]?.GetValue<string>() is "user" or "assistant")) messages++;
                expected++;
            }
            if (boundary is not null && (boundary.EndOrdinal != expected || OffsetForOrdinal(boundary.EndOrdinal, chain[index]) != boundary.EndOffset)) throw new InvalidOperationException("继承边界不在父文件中");
            files.Add(new HistoryFile(chain[index].Path, Hash(chain[index].Path)));
        }
        return (files, messages);
    }

    private static long? OffsetForOrdinal(long ordinal, Node node)
    {
        var found = node.Boundaries.FirstOrDefault(item => item.Ordinal == ordinal);
        return found is not null ? found.Start : ordinal == (node.Boundaries.LastOrDefault()?.Ordinal ?? -1) + 1 ? node.FileLength : null;
    }

    private sealed record Line(byte[] Data, long Start, long End);
    private static List<Line> ReadLines(string path)
    {
        byte[] bytes;
        using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        using (var memory = new MemoryStream())
        {
            stream.CopyTo(memory);
            bytes = memory.ToArray();
        }
        var result = new List<Line>();
        var start = 0;
        for (var i = 0; i < bytes.Length; i++) if (bytes[i] == (byte)'\n') { var end = i + 1; var dataEnd = i > start && bytes[i - 1] == (byte)'\r' ? i - 1 : i; result.Add(new(bytes[start..dataEnd], start, end)); start = end; }
        if (start < bytes.Length) result.Add(new(bytes[start..], start, bytes.Length));
        return result;
    }
    private static long? Int64(JsonNode? node) => node is JsonValue value && value.TryGetValue<long>(out var number) ? number : null;
    private static string Hash(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }
    private static bool TryIds(string path, out string logical, out string physical) { logical = physical = ""; var match = RolloutName.Match(Path.GetFileName(path)); if (!match.Success) return false; logical = match.Groups["logical"].Value; physical = match.Groups["physical"].Success ? match.Groups["physical"].Value : logical; return true; }
    private static bool IsIgnored(string path) { var name = Path.GetFileName(path).ToLowerInvariant(); return name.StartsWith('.') || name.Contains(".codex-synced-") || name.EndsWith("_repaired.jsonl") || name.EndsWith(".bak.jsonl") || name.EndsWith(".tmp.jsonl"); }
    private static bool SamePath(string left, string right) => string.Equals(Path.GetFullPath(left), Path.GetFullPath(right), StringComparison.OrdinalIgnoreCase);
    private static void RestoreSnapshot(string snapshot, string target) { foreach (var sidecar in new[] { target + "-wal", target + "-shm" }) if (File.Exists(sidecar)) File.Delete(sidecar); File.Copy(snapshot, target, true); }

    private static string ResolveSQLiteHome(string codexHome, string? configured)
    {
        if (!string.IsNullOrWhiteSpace(configured)) return Path.GetFullPath(configured);
        var candidates = new[] { codexHome, Path.Combine(codexHome, "sqlite") }.Where(Directory.Exists).Select(path => new { Path = path, Latest = Directory.EnumerateFiles(path, "state_*.sqlite").Select(File.GetLastWriteTimeUtc).DefaultIfEmpty(DateTime.MinValue).Max() }).Where(item => item.Latest != DateTime.MinValue).OrderByDescending(item => item.Latest).ToList();
        return candidates.FirstOrDefault()?.Path ?? codexHome;
    }

    private static string ExpandPath(string path)
    {
        if (path == "~") return Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (path.StartsWith("~/", StringComparison.Ordinal) || path.StartsWith("~\\", StringComparison.Ordinal)) return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), path[2..]);
        return Environment.ExpandEnvironmentVariables(path);
    }
}
