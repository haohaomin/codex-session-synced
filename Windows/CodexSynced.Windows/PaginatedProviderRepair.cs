using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace CodexSynced.Windows;

internal sealed record PaginatedRolloutRepair(
    string Path,
    string LogicalId,
    string PhysicalId,
    string OriginalFirstLine,
    string RepairedFirstLine,
    long OriginalByteLength,
    long RepairedByteLength)
{
    public long ByteDelta => RepairedByteLength - OriginalByteLength;
}

internal sealed record PaginatedTurnOffsetRepair(
    string ThreadId,
    string TurnId,
    long CurrentStartOffset,
    long TargetStartOffset,
    long? CurrentEndOffset,
    long? TargetEndOffset);

internal sealed record PaginatedProjectionOffsetRepair(
    string ThreadId,
    long CurrentOffset,
    long TargetOffset);

internal sealed record PaginatedTurnRow(
    string ThreadId,
    string TurnId,
    long RolloutOrdinal,
    long RolloutByteOffset,
    long? RolloutEndOrdinal,
    long? RolloutEndOffset);

internal readonly record struct PaginatedProjectionRow(long NextOffset, long NextOrdinal);

internal sealed record PaginatedProviderRepair(
    string ThreadId,
    string Title,
    string TargetProvider,
    string CurrentSQLiteProvider,
    string StateDatabase,
    string HistoryDatabase,
    List<PaginatedRolloutRepair> RolloutRepairs,
    List<PaginatedTurnOffsetRepair> TurnOffsetRepairs,
    List<PaginatedProjectionOffsetRepair> ProjectionOffsetRepairs)
{
    public bool IsMeaningful => RolloutRepairs.Count > 0 || TurnOffsetRepairs.Count > 0 || ProjectionOffsetRepairs.Count > 0;

    // Records compare List<T> fields by reference. A fresh read-only scan creates
    // new lists, so compare the repair plan structurally when validating a preview.
    public bool Matches(PaginatedProviderRepair other)
        => string.Equals(ThreadId, other.ThreadId, StringComparison.OrdinalIgnoreCase)
           && string.Equals(Title, other.Title, StringComparison.Ordinal)
           && string.Equals(TargetProvider, other.TargetProvider, StringComparison.Ordinal)
           && string.Equals(CurrentSQLiteProvider, other.CurrentSQLiteProvider, StringComparison.Ordinal)
           && string.Equals(StateDatabase, other.StateDatabase, StringComparison.OrdinalIgnoreCase)
           && string.Equals(HistoryDatabase, other.HistoryDatabase, StringComparison.OrdinalIgnoreCase)
           && RolloutRepairs.SequenceEqual(other.RolloutRepairs)
           && TurnOffsetRepairs.SequenceEqual(other.TurnOffsetRepairs)
           && ProjectionOffsetRepairs.SequenceEqual(other.ProjectionOffsetRepairs);
}

internal sealed record PaginatedProviderScan(
    List<PaginatedProviderRepair> Repairs,
    List<PaginatedProviderWarning> Warnings,
    List<string> Diagnostics);

internal sealed class PaginatedRepairBackup
{
    private sealed record Manifest(string StateDatabase, string HistoryDatabase, List<BackupFile> Rollouts);

    private PaginatedRepairBackup(string directory, string stateSnapshot, string historySnapshot, List<BackupFile> rollouts)
    {
        DirectoryPath = directory;
        StateSnapshot = stateSnapshot;
        HistorySnapshot = historySnapshot;
        Rollouts = rollouts;
    }

    public string DirectoryPath { get; }
    public string StateSnapshot { get; }
    public string HistorySnapshot { get; }
    public List<BackupFile> Rollouts { get; }

    public static PaginatedRepairBackup Create(string codexHome, string stateDatabase, string historyDatabase, IEnumerable<PaginatedRolloutRepair> repairs)
    {
        var root = Path.Combine(codexHome, "codex-synced-backups", "paginated");
        Directory.CreateDirectory(root);
        var directory = Path.Combine(root, DateTime.UtcNow.ToString("yyyyMMdd-HHmmssfff") + "-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var stateSnapshot = Path.Combine(directory, "state-before.sqlite");
        var historySnapshot = Path.Combine(directory, "history-before.sqlite");
        using (var state = new SqliteDatabase(stateDatabase, true)) state.BackupTo(stateSnapshot);
        using (var history = new SqliteDatabase(historyDatabase, true)) history.BackupTo(historySnapshot);
        var rollouts = new List<BackupFile>();
        var index = 0;
        foreach (var repair in repairs)
        {
            if (rollouts.Any(item => string.Equals(item.OriginalPath, repair.Path, StringComparison.OrdinalIgnoreCase)))
                continue;
            var relative = Path.Combine("rollouts", $"{index++}.jsonl");
            var destination = Path.Combine(directory, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            File.Copy(repair.Path, destination, false);
            rollouts.Add(new BackupFile(repair.Path, relative));
        }
        File.WriteAllText(Path.Combine(directory, "manifest.json"), JsonSerializer.Serialize(new Manifest(stateDatabase, historyDatabase, rollouts), JsonOptions.Pretty));
        return new(directory, stateSnapshot, historySnapshot, rollouts);
    }

    public string CreateTrialRoot()
    {
        var root = Path.Combine(DirectoryPath, "trial");
        Directory.CreateDirectory(root);
        return root;
    }

    public void Restore()
    {
        foreach (var item in Rollouts)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(item.OriginalPath)!);
            File.Copy(Path.Combine(DirectoryPath, item.BackupRelativePath), item.OriginalPath, true);
        }
        var manifestPath = Path.Combine(DirectoryPath, "manifest.json");
        var manifest = JsonSerializer.Deserialize<Manifest>(File.ReadAllText(manifestPath), JsonOptions.Pretty)
            ?? throw new InvalidOperationException("分页备份清单损坏。");
        RestoreDatabase(StateSnapshot, manifest.StateDatabase);
        RestoreDatabase(HistorySnapshot, manifest.HistoryDatabase);
    }

    private static void RestoreDatabase(string snapshot, string target)
    {
        DeleteSQLiteSidecars(target);
        File.Copy(snapshot, target, true);
    }

    private static void DeleteSQLiteSidecars(string path)
    {
        foreach (var suffix in new[] { "-wal", "-shm" })
        {
            var sidecar = path + suffix;
            if (File.Exists(sidecar))
                File.Delete(sidecar);
        }
    }
}

internal static class PaginatedProviderPlanner
{
    private sealed record Base(string ThreadId, long EndOrdinal, long EndOffset);
    private sealed record Boundary(long Ordinal, long Start, long End);
    private sealed record Node(
        string Path,
        string LogicalId,
        string PhysicalId,
        long Start,
        string? Provider,
        Base? HistoryBase,
        string FirstLine,
        long FirstLineLength,
        long FileLength,
        int NewlineLength,
        List<Boundary> Boundaries);

    private static readonly Regex RolloutName = new(
        "^rollout-.+-(?<logical>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})(?:_(?<physical>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}))?\\.jsonl$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    public static PaginatedProviderScan Scan(string codexHome, string sqliteHome, List<ThreadRow> threads, string targetProvider, string? stateDatabase)
    {
        if (string.IsNullOrWhiteSpace(targetProvider) || string.IsNullOrWhiteSpace(stateDatabase))
            return new([], [], []);

        var candidates = Directory.Exists(sqliteHome)
            ? Directory.EnumerateFiles(sqliteHome, "thread_history_*.sqlite", SearchOption.TopDirectoryOnly).OrderBy(path => path, StringComparer.OrdinalIgnoreCase).ToList()
            : [];
        var paginatedCandidates = threads.Where(thread => thread.RolloutPath.EndsWith(".jsonl", StringComparison.OrdinalIgnoreCase) && File.Exists(thread.RolloutPath)).ToList();
        if (candidates.Count != 1)
        {
            if (paginatedCandidates.Count == 0)
                return new([], [], []);
            var reason = candidates.Count == 0
                ? "未找到 thread_history_*.sqlite，分页 Provider 修复需人工确认。Missing thread_history_*.sqlite; paginated Provider repair requires manual review."
                : "发现多个 thread_history_*.sqlite，无法确认活动历史库，分页 Provider 修复需人工确认。Multiple thread_history_*.sqlite files were found; the active history database is ambiguous.";
            return new([], paginatedCandidates.Select(thread => new PaginatedProviderWarning(thread.Id, thread.Title, thread.RolloutPath, thread.ModelProvider, targetProvider)).ToList(), [reason]);
        }

        try
        {
            var nodes = LoadNodes(codexHome);
            var byPhysical = nodes.GroupBy(node => node.PhysicalId, StringComparer.OrdinalIgnoreCase).ToDictionary(group => group.Key, group => group.ToList(), StringComparer.OrdinalIgnoreCase);
            var duplicate = byPhysical.FirstOrDefault(item => item.Value.Count > 1);
            if (duplicate.Value is { Count: > 1 })
                return new([], [], [$"跨文件重复物理 ID：{duplicate.Key} / Duplicate physical ID across rollout files"]);

            using var history = new SqliteDatabase(candidates[0], true);
            var repairs = new List<PaginatedProviderRepair>();
            var warnings = new List<PaginatedProviderWarning>();
            var diagnostics = new List<string>();
            foreach (var thread in threads.Where(thread => !string.IsNullOrWhiteSpace(thread.RolloutPath)))
            {
                var first = nodes.FirstOrDefault(node => SamePath(node.Path, thread.RolloutPath));
                if (first is null || first.HistoryBase is null && !IsPaginated(first))
                    continue;
                if (!IsPaginated(first))
                    continue;
                try
                {
                    var chain = BuildLineage(thread, nodes, byPhysical);
                    var plan = MakePlan(thread, chain, targetProvider, stateDatabase, candidates[0], history);
                    if (plan.IsMeaningful)
                        repairs.Add(plan);
                    else if (chain.Any(node => !string.Equals(node.Provider, targetProvider, StringComparison.Ordinal)))
                        warnings.Add(new PaginatedProviderWarning(thread.Id, thread.Title, thread.RolloutPath, chain.LastOrDefault()?.Provider ?? "", targetProvider));
                }
                catch (Exception error)
                {
                    diagnostics.Add($"{(string.IsNullOrWhiteSpace(thread.Title) ? thread.Id : thread.Title)}：{error.Message}");
                }
            }
            return new(repairs, warnings, diagnostics);
        }
        catch (Exception error)
        {
            return new([], [], [error.Message]);
        }
    }

    public static void ApplyRolloutRepair(PaginatedRolloutRepair repair, string? pathOverride = null)
    {
        var path = pathOverride ?? repair.Path;
        if (!File.Exists(path))
            throw new InvalidOperationException($"找不到 rollout：{path}");
        var before = File.ReadAllBytes(path);
        var first = ReadFirstLineBytes(before, out var newlineStart, out var newlineLength);
        var current = Encoding.UTF8.GetString(first);
        if (!string.Equals(current, repair.OriginalFirstLine, StringComparison.Ordinal))
            throw new InvalidOperationException($"rollout 首行已变化，拒绝覆盖：{path}");
        var firstBytes = Encoding.UTF8.GetBytes(repair.RepairedFirstLine);
        var originalBodyHash = SHA256.HashData(before.AsSpan(newlineStart + newlineLength));
        using var output = new MemoryStream(before.Length + firstBytes.Length - first.Length);
        output.Write(firstBytes);
        output.Write(before, newlineStart, newlineLength);
        output.Write(before, newlineStart + newlineLength, before.Length - newlineStart - newlineLength);
        var temp = path + ".codex-synced-paginated.tmp";
        File.WriteAllBytes(temp, output.ToArray());
        File.Move(temp, path, true);
        var after = File.ReadAllBytes(path);
        var repairedBodyStart = firstBytes.Length + newlineLength;
        if (!SHA256.HashData(after.AsSpan(repairedBodyStart)).AsSpan().SequenceEqual(originalBodyHash))
            throw new InvalidOperationException($"rollout 正文哈希校验失败：{path}");
    }

    private static List<Node> LoadNodes(string codexHome)
    {
        var nodes = new List<Node>();
        foreach (var rootName in new[] { "sessions", "archived_sessions" })
        {
            var root = Path.Combine(codexHome, rootName);
            if (!Directory.Exists(root))
                continue;
            foreach (var path in Directory.EnumerateFiles(root, "rollout-*.jsonl", SearchOption.AllDirectories).OrderBy(path => path, StringComparer.OrdinalIgnoreCase))
            {
                if (IsIgnoredArtifact(path) || !TryIds(path, out var logical, out var physical))
                    continue;
                var node = ParseNode(path, logical, physical);
                if (node is not null)
                    nodes.Add(node);
            }
        }
        return nodes;
    }

    private static Node? ParseNode(string path, string logical, string physical)
    {
        var lines = ReadLines(path);
        if (lines.Count == 0)
            return null;
        var first = lines[0];
        JsonObject? root;
        try { root = JsonNode.Parse(Encoding.UTF8.GetString(first.Data))?.AsObject(); } catch { return null; }
        if (root?["type"]?.GetValue<string>() != "session_meta" || root["payload"] is not JsonObject payload || payload["id"]?.GetValue<string>() != logical)
            return null;
        var mode = payload["history_mode"]?.GetValue<string>();
        var start = TryInt64(root["ordinal"]);
        if (mode != "paginated" || start is null)
            return null;
        var boundaries = new List<Boundary>();
        long? expected = start;
        foreach (var line in lines)
        {
            JsonNode? parsed;
            try { parsed = JsonNode.Parse(Encoding.UTF8.GetString(line.Data)); } catch { throw new InvalidOperationException($"非法 JSON：{Path.GetFileName(path)}"); }
            var objectNode = parsed?.AsObject() ?? throw new InvalidOperationException($"非法 JSON：{Path.GetFileName(path)}");
            var ordinal = TryInt64(objectNode["ordinal"]);
            if (ordinal is null || expected is null || ordinal.Value != expected.Value)
                throw new InvalidOperationException($"分页序号不连续：{Path.GetFileName(path)}");
            boundaries.Add(new Boundary(ordinal.Value, line.Start, line.End));
            expected = ordinal.Value == long.MaxValue ? null : ordinal.Value + 1;
        }
        Base? historyBase = null;
        if (payload["history_base"] is JsonObject rawBase)
        {
            var threadId = rawBase["thread_id"]?.GetValue<string>();
            var endOrdinal = TryInt64(rawBase["end_ordinal_exclusive"]);
            var endOffset = TryInt64(rawBase["end_byte_offset"]);
            if (threadId is null || endOrdinal is null || endOffset is null)
                throw new InvalidOperationException($"history_base 缺失或非法：{Path.GetFileName(path)}");
            historyBase = new Base(threadId, endOrdinal.Value, endOffset.Value);
        }
        var newlineLength = first.NewlineLength;
        var firstLine = Encoding.UTF8.GetString(first.Data);
        var provider = payload["model_provider"]?.GetValue<string>();
        return new Node(path, logical, physical, start.Value, provider, historyBase, firstLine,
            first.Data.LongLength + newlineLength, lines[^1].End, newlineLength, boundaries);
    }

    private static List<Node> BuildLineage(ThreadRow thread, List<Node> nodes, Dictionary<string, List<Node>> byPhysical)
    {
        var local = nodes.Where(node => string.Equals(node.LogicalId, thread.Id, StringComparison.OrdinalIgnoreCase)).ToList();
        if (local.Count == 0)
            throw new InvalidOperationException("找不到逻辑会话的 rollout / Missing logical rollout");
        if (local.GroupBy(node => node.PhysicalId, StringComparer.OrdinalIgnoreCase).Any(group => group.Count() > 1))
            throw new InvalidOperationException("重复物理 ID / Duplicate physical ID");
        var parents = local.Where(node => node.HistoryBase is not null).Select(node => node.HistoryBase!.ThreadId).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var leaves = local.Where(node => !parents.Contains(node.PhysicalId)).ToList();
        if (leaves.Count != 1)
            throw new InvalidOperationException("多个末端或分支循环 / Ambiguous tips or cycle");
        var reversed = new List<Node>();
        var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        Node? cursor = leaves[0];
        while (cursor is not null)
        {
            if (!visited.Add(cursor.PhysicalId))
                throw new InvalidOperationException("分支循环 / Cycle");
            reversed.Add(cursor);
            if (cursor.HistoryBase is { } baseInfo)
            {
                var localParent = local.Where(node => string.Equals(node.PhysicalId, baseInfo.ThreadId, StringComparison.OrdinalIgnoreCase)).ToList();
                var globalParent = byPhysical.TryGetValue(baseInfo.ThreadId, out var parentList) ? parentList : [];
                cursor = localParent.Count == 1 ? localParent[0] : globalParent.Count == 1 ? globalParent[0] : throw new InvalidOperationException($"父分支缺失或不唯一：{baseInfo.ThreadId}");
            }
            else
            {
                if (cursor.Start != 0)
                    throw new InvalidOperationException("原始根分支无法确认 / Unconfirmed root");
                cursor = null;
            }
        }
        if (local.Any(node => !visited.Contains(node.PhysicalId)) || !visited.Any(id => nodes.Any(node => SamePath(node.Path, thread.RolloutPath) && node.PhysicalId == id)))
            throw new InvalidOperationException("入口不在完整分支链上 / Entrypoint is not on a complete chain");
        var chain = reversed.AsEnumerable().Reverse().ToList();
        ValidateBoundaries(chain);
        return chain;
    }

    private static PaginatedProviderRepair MakePlan(ThreadRow thread, List<Node> chain, string targetProvider, string stateDatabase, string historyDatabase, SqliteDatabase history)
    {
        if (!chain.Any(node => string.Equals(node.LogicalId, thread.Id, StringComparison.OrdinalIgnoreCase) && !string.Equals(node.Provider, targetProvider, StringComparison.Ordinal)))
            return new(thread.Id, thread.Title, targetProvider, thread.ModelProvider, stateDatabase, historyDatabase, [], [], []);
        var deltas = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        var rolloutRepairs = new List<PaginatedRolloutRepair>();
        foreach (var node in chain)
        {
            var original = JsonNode.Parse(node.FirstLine)?.AsObject() ?? throw new InvalidOperationException("无法解析 session_meta");
            var payload = original["payload"]?.AsObject() ?? throw new InvalidOperationException("session_meta payload 缺失");
            var changed = false;
            if (string.Equals(node.LogicalId, thread.Id, StringComparison.OrdinalIgnoreCase) && !string.Equals(payload["model_provider"]?.GetValue<string>(), targetProvider, StringComparison.Ordinal))
            {
                payload["model_provider"] = targetProvider;
                changed = true;
            }
            if (payload["history_base"] is JsonObject baseObject && baseObject["thread_id"]?.GetValue<string>() is { } parentId && deltas.TryGetValue(parentId, out var parentDelta) && parentDelta != 0)
            {
                var oldOffset = TryInt64(baseObject["end_byte_offset"]) ?? throw new InvalidOperationException("history_base 偏移缺失");
                var next = oldOffset + parentDelta;
                if (next < 0)
                    throw new InvalidOperationException("history_base 偏移溢出");
                baseObject["end_byte_offset"] = next;
                changed = true;
            }
            var repaired = changed ? original.ToJsonString(new JsonSerializerOptions { WriteIndented = false }) : node.FirstLine;
            var newLength = Encoding.UTF8.GetByteCount(repaired) + node.NewlineLength;
            var delta = newLength - node.FirstLineLength;
            deltas[node.PhysicalId] = delta;
            if (changed)
                rolloutRepairs.Add(new(node.Path, node.LogicalId, node.PhysicalId, node.FirstLine, repaired, node.FirstLineLength, newLength));
        }
        var turnRepairs = new List<PaginatedTurnOffsetRepair>();
        foreach (var row in history.PaginatedTurnRows(thread.Id))
        {
            var start = MapOffset(row.RolloutOrdinal, row.RolloutByteOffset, chain, deltas) ?? throw new InvalidOperationException($"无法定位 turn 起始偏移：{row.TurnId}");
            long? end = null;
            if (row.RolloutEndOrdinal is not null && row.RolloutEndOffset is not null)
                end = MapOffset(row.RolloutEndOrdinal.Value, row.RolloutEndOffset.Value, chain, deltas) ?? throw new InvalidOperationException($"无法定位 turn 结束偏移：{row.TurnId}");
            else if (row.RolloutEndOffset is not null)
                throw new InvalidOperationException($"turn 结束序号缺失：{row.TurnId}");
            if (start != row.RolloutByteOffset || end != row.RolloutEndOffset)
                turnRepairs.Add(new(thread.Id, row.TurnId, row.RolloutByteOffset, start, row.RolloutEndOffset, end));
        }
        var projections = new List<PaginatedProjectionOffsetRepair>();
        var projection = history.PaginatedProjectionRow(thread.Id);
        if (projection is not null)
        {
            var mapped = MapOffset(projection.Value.NextOrdinal, projection.Value.NextOffset, chain, deltas) ?? throw new InvalidOperationException("无法定位 projection 偏移");
            if (mapped != projection.Value.NextOffset)
                projections.Add(new(thread.Id, projection.Value.NextOffset, mapped));
        }
        return new(thread.Id, thread.Title, targetProvider, thread.ModelProvider, stateDatabase, historyDatabase, rolloutRepairs, turnRepairs, projections);
    }

    private static void ValidateBoundaries(List<Node> chain)
    {
        for (var index = 0; index < chain.Count; index++)
        {
            var node = chain[index];
            if (node.HistoryBase is { } baseInfo)
            {
                if (baseInfo.EndOrdinal != node.Start)
                    throw new InvalidOperationException("继承序号不连续 / Noncontiguous inherited ordinal");
                var parent = chain.FirstOrDefault(candidate => string.Equals(candidate.PhysicalId, baseInfo.ThreadId, StringComparison.OrdinalIgnoreCase));
                if (parent is null || OffsetForOrdinal(baseInfo.EndOrdinal, parent) != baseInfo.EndOffset)
                    throw new InvalidOperationException("字节边界不一致 / Byte boundary mismatch");
            }
            else if (node.Start != 0)
                throw new InvalidOperationException("原始根分支无法确认 / Unconfirmed root");
            if (index + 1 < chain.Count && chain[index + 1].HistoryBase is { } nextBase)
            {
                if (!string.Equals(nextBase.ThreadId, node.PhysicalId, StringComparison.OrdinalIgnoreCase) || OffsetForOrdinal(nextBase.EndOrdinal, node) != nextBase.EndOffset)
                    throw new InvalidOperationException("后继边界不一致 / Successor boundary mismatch");
            }
        }
    }

    private static long? MapOffset(long ordinal, long offset, List<Node> chain, Dictionary<string, long> deltas)
    {
        var node = NodeForBoundary(ordinal, offset, chain);
        if (node is null || offset < 0 || offset > node.FileLength)
            return null;
        return offset >= node.FirstLineLength ? offset + deltas.GetValueOrDefault(node.PhysicalId) : offset;
    }

    private static Node? NodeForBoundary(long ordinal, long offset, List<Node> chain)
    {
        for (var index = 0; index < chain.Count; index++)
        {
            var node = chain[index];
            var nextStart = index + 1 < chain.Count ? chain[index + 1].Start : long.MaxValue;
            if (ordinal >= node.Start && ordinal < nextStart)
                return node;
            if (ordinal == nextStart && offset == node.FileLength)
                return node;
        }
        return null;
    }

    private static long? OffsetForOrdinal(long ordinal, Node node)
    {
        var boundary = node.Boundaries.FirstOrDefault(item => item.Ordinal == ordinal);
        if (boundary is not null)
            return boundary.Start;
        return ordinal == (node.Boundaries.LastOrDefault()?.Ordinal ?? -1) + 1 ? node.FileLength : null;
    }

    private sealed record Line(byte[] Data, long Start, long End, int NewlineLength);

    private static List<Line> ReadLines(string path)
    {
        byte[] bytes;
        using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        using (var memory = new MemoryStream())
        {
            stream.CopyTo(memory);
            bytes = memory.ToArray();
        }
        var lines = new List<Line>();
        var start = 0;
        for (var index = 0; index < bytes.Length; index++)
        {
            if (bytes[index] != (byte)'\n')
                continue;
            var newline = index > start && bytes[index - 1] == (byte)'\r' ? 2 : 1;
            var length = index - start - (newline == 2 ? 1 : 0);
            lines.Add(new(bytes[start..(start + length)], start, index + 1, newline));
            start = index + 1;
        }
        if (start < bytes.Length)
            lines.Add(new(bytes[start..], start, bytes.Length, 0));
        return lines;
    }

    private static byte[] ReadFirstLineBytes(byte[] bytes, out int newlineStart, out int newlineLength)
    {
        var newline = Array.IndexOf(bytes, (byte)'\n');
        if (newline < 0)
            throw new InvalidOperationException("session_meta 没有换行");
        newlineLength = newline > 0 && bytes[newline - 1] == (byte)'\r' ? 2 : 1;
        newlineStart = newline - (newlineLength == 2 ? 1 : 0);
        return bytes[..newlineStart];
    }

    private static bool TryIds(string path, out string logical, out string physical)
    {
        logical = physical = "";
        var match = RolloutName.Match(Path.GetFileName(path));
        if (!match.Success)
            return false;
        logical = match.Groups["logical"].Value;
        physical = match.Groups["physical"].Success ? match.Groups["physical"].Value : logical;
        return true;
    }

    private static bool IsIgnoredArtifact(string path)
    {
        var name = Path.GetFileName(path).ToLowerInvariant();
        return name.StartsWith('.') || name.Contains(".codex-synced-") || name.EndsWith("_repaired.jsonl") || name.EndsWith(".bak.jsonl") || name.EndsWith(".tmp.jsonl");
    }

    private static bool IsPaginated(Node node) => node.HistoryBase is not null || node.Start != 0 || node.Boundaries.Any(boundary => boundary.Ordinal >= 0);
    private static long? TryInt64(JsonNode? node) => node is JsonValue value && value.TryGetValue<long>(out var number) ? number : null;
    private static bool SamePath(string left, string right) => string.Equals(Path.GetFullPath(left), Path.GetFullPath(right), StringComparison.OrdinalIgnoreCase);
}
