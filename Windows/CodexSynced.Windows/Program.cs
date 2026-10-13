using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace CodexSynced.Windows;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            if (args.Contains("--self-test", StringComparer.OrdinalIgnoreCase))
                return SelfTest.Run();

            if (args.Contains("--scan", StringComparer.OrdinalIgnoreCase))
            {
                var settings = AppSettings.Load();
                var homeIndex = Array.FindIndex(args, value => value.Equals("--codex-home", StringComparison.OrdinalIgnoreCase));
                if (homeIndex >= 0 && homeIndex + 1 < args.Length)
                    settings.CodexHome = args[homeIndex + 1];
                var scan = new RepairService().Scan(settings);
                Console.WriteLine(JsonSerializer.Serialize(scan.ToSummary(), JsonOptions.Pretty));
                return 0;
            }

            ApplicationConfiguration.Initialize();
            Application.Run(new MainForm());
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex);
            if (!args.Contains("--scan", StringComparer.OrdinalIgnoreCase) &&
                !args.Contains("--self-test", StringComparer.OrdinalIgnoreCase))
                MessageBox.Show(ex.Message, "Codex Synced", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}

internal static class JsonOptions
{
    public static readonly JsonSerializerOptions Pretty = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };
}

internal enum BackupMode
{
    Lightweight,
    Full
}

internal sealed class AppSettings
{
    public string CodexHome { get; set; } = "";
    public string? SqliteHome { get; set; }
    public BackupMode DefaultBackupMode { get; set; } = BackupMode.Lightweight;
    public int LightweightLimit { get; set; } = 5;
    public int FullLimit { get; set; } = 3;
    public bool OpenCodexAfterRepair { get; set; } = true;
    public bool AlignProvidersForVisibility { get; set; } = true;

    public static string SettingsPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Codex Synced", "settings.json");

    public static AppSettings Load()
    {
        AppSettings settings;
        try
        {
            settings = File.Exists(SettingsPath)
                ? JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(SettingsPath), JsonOptions.Pretty) ?? new()
                : new();
        }
        catch
        {
            settings = new();
        }

        if (string.IsNullOrWhiteSpace(settings.CodexHome))
        {
            settings.CodexHome = Environment.GetEnvironmentVariable("CODEX_HOME")
                ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
        }
        settings.SqliteHome ??= Environment.GetEnvironmentVariable("CODEX_SQLITE_HOME");
        settings.LightweightLimit = Math.Clamp(settings.LightweightLimit, 1, 30);
        settings.FullLimit = Math.Clamp(settings.FullLimit, 1, 12);
        return settings;
    }

    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath)!);
        File.WriteAllText(SettingsPath, JsonSerializer.Serialize(this, JsonOptions.Pretty));
    }
}

internal sealed record ProviderInfo(string Provider, string AuthLabel, string ConfigPath);
internal sealed record StateDatabase(string Path, DateTime ModifiedAt);
internal sealed record ThreadRow(
    string Id,
    string RolloutPath,
    string Title,
    string ModelProvider,
    bool HasUserEvent,
    string Cwd,
    string Source,
    string? ThreadSource,
    bool Archived,
    long UpdatedAt,
    long? UpdatedAtMs,
    string FirstUserMessage,
    string Preview,
    long CreatedAt = 0,
    long? CreatedAtMs = null,
    long RecencyAt = 0,
    long? RecencyAtMs = null)
{
    public long EffectiveUpdatedAtMs => UpdatedAtMs is > 0 ? UpdatedAtMs.Value : UpdatedAt * 1000;
    public long EffectiveCreatedAtMs => CreatedAtMs is > 0 ? CreatedAtMs.Value : CreatedAt * 1000;
    public long? EffectiveRecencyAtMs => RecencyAtMs is > 0 ? RecencyAtMs.Value : RecencyAt > 0 ? RecencyAt * 1000 : null;
}
internal sealed record ProviderRepair(ThreadRow Thread, string TargetProvider);
internal sealed record PaginatedProviderWarning(
    string ThreadId,
    string Title,
    string RolloutPath,
    string CurrentProvider,
    string TargetProvider);
internal sealed record RolloutRepair(
    string Path,
    string SessionId,
    string? CurrentProvider,
    string TargetProvider,
    string OriginalFirstLine,
    string RepairedFirstLine);
internal sealed record IndexRepair(string ThreadId, string Title, long UpdatedAtMs);
internal sealed record TimestampRepair(
    string ThreadId,
    string Title,
    long CurrentUpdatedAtMs,
    long TargetUpdatedAtMs,
    long? CurrentCreatedAtMs = null,
    long? TargetCreatedAtMs = null);
internal sealed record TitleRepair(string ThreadId, string CurrentTitle, string TargetTitle);
internal sealed record RolloutMtimeRepair(string ThreadId, string Title, string RolloutPath, long CurrentMtimeMs, long TargetMtimeMs);
internal sealed record GlobalStateRepair(List<string> Changes, string RepairedJson);
internal sealed record RepairSummary(
    string TargetProvider,
    int SqliteProviderUpdates,
    int SqliteCompatibilityUpdates,
    int RolloutUpdates,
    int IndexInsertions,
    DateTime RepairedAt);
internal sealed record BackupFile(string OriginalPath, string BackupRelativePath);
internal sealed record BackupDirectory(string OriginalPath, string BackupRelativePath);
internal sealed record BackupFirstLine(string OriginalPath, string FirstLine);
internal sealed record BackupMtime(string OriginalPath, long ModifiedAtMs);
internal sealed record BackupRecord(
    string DirectoryName,
    DateTime CreatedAt,
    BackupMode Mode,
    string TargetProvider,
    RepairSummary Summary,
    long SizeBytes,
    string Path);
internal sealed record BackupManifest(
    BackupRecord Record,
    List<BackupFile> Files,
    List<BackupDirectory> Directories,
    List<BackupFirstLine> RolloutFirstLines,
    List<BackupMtime>? RolloutMtimes = null);

internal sealed class ScanResult
{
    public required ProviderInfo ProviderInfo { get; init; }
    public StateDatabase? StateDatabase { get; init; }
    public required List<ThreadRow> Threads { get; init; }
    public required List<ProviderRepair> SqliteProviderUpdates { get; init; }
    public required List<ThreadRow> SqliteCompatibilityUpdates { get; init; }
    public required List<RolloutRepair> RolloutRepairs { get; init; }
    public required List<PaginatedProviderWarning> PaginatedProviderWarnings { get; init; }
    public required List<PaginatedProviderRepair> PaginatedProviderRepairs { get; init; }
    public required List<string> PaginatedProviderDiagnostics { get; init; }
    public required List<IndexRepair> IndexRepairs { get; init; }
    public required List<TimestampRepair> SqliteTimestampRepairs { get; init; }
    public required List<TitleRepair> SqliteTitleRepairs { get; init; }
    public required List<RolloutMtimeRepair> RolloutMtimeRepairs { get; init; }
    public GlobalStateRepair? GlobalStateRepair { get; init; }
    public required List<BackupRecord> Backups { get; init; }
    public required string CodexHome { get; init; }
    public required string SqliteHome { get; init; }
    public bool AlignProvidersForVisibility { get; init; }

    public bool HasPaginatedReview => PaginatedProviderWarnings.Count > 0 || PaginatedProviderRepairs.Count > 0 || PaginatedProviderDiagnostics.Count > 0;
    public bool HasWarnings => HasPaginatedReview;

    public bool HasRepairs =>
        SqliteProviderUpdates.Count > 0 ||
        SqliteCompatibilityUpdates.Count > 0 ||
        RolloutRepairs.Count > 0 ||
        IndexRepairs.Count > 0 ||
        SqliteTimestampRepairs.Count > 0 ||
        SqliteTitleRepairs.Count > 0 ||
        RolloutMtimeRepairs.Count > 0 ||
        GlobalStateRepair is not null;

    public int PendingCount =>
        SqliteProviderUpdates.Count +
        SqliteCompatibilityUpdates.Count +
        RolloutRepairs.Count +
        IndexRepairs.Count +
        SqliteTimestampRepairs.Count +
        SqliteTitleRepairs.Count +
        RolloutMtimeRepairs.Count +
        (GlobalStateRepair?.Changes.Count ?? 0);

    public object ToSummary() => new
    {
        provider = ProviderInfo.Provider,
        auth = ProviderInfo.AuthLabel,
        alignProvidersForVisibility = AlignProvidersForVisibility,
        codexHome = CodexHome,
        sqliteHome = SqliteHome,
        stateDatabase = StateDatabase?.Path,
        threads = Threads.Count,
        sqliteProviderUpdates = SqliteProviderUpdates.Count,
        sqliteCompatibilityUpdates = SqliteCompatibilityUpdates.Count,
        rolloutRepairs = RolloutRepairs.Count,
        paginatedProviderWarnings = PaginatedProviderWarnings.Count,
        paginatedProviderRepairs = PaginatedProviderRepairs.Count,
        paginatedProviderDiagnostics = PaginatedProviderDiagnostics.Count,
        indexRepairs = IndexRepairs.Count,
        sqliteTimestampRepairs = SqliteTimestampRepairs.Count,
        sqliteTitleRepairs = SqliteTitleRepairs.Count,
        rolloutMtimeRepairs = RolloutMtimeRepairs.Count,
        globalStateChanges = GlobalStateRepair?.Changes.Count ?? 0,
        backups = Backups.Count,
        hasRepairs = HasRepairs
    };
}

internal static class ConfigParser
{
    public static (Dictionary<string, string> Root, Dictionary<string, Dictionary<string, string>> Providers) Parse(string path)
    {
        var root = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var providers = new Dictionary<string, Dictionary<string, string>>(StringComparer.OrdinalIgnoreCase);
        if (!File.Exists(path))
            return (root, providers);

        string? section = null;
        foreach (var rawLine in File.ReadLines(path))
        {
            var line = StripComment(rawLine).Trim();
            if (line.Length == 0)
                continue;
            if (line.StartsWith('[') && line.EndsWith(']'))
            {
                section = line[1..^1];
                continue;
            }
            var equals = line.IndexOf('=');
            if (equals < 1)
                continue;
            var key = line[..equals].Trim();
            var value = Unquote(line[(equals + 1)..].Trim());
            if (section is null)
            {
                root[key] = value;
            }
            else if (section.StartsWith("model_providers.", StringComparison.OrdinalIgnoreCase))
            {
                var provider = section["model_providers.".Length..].Trim('"');
                if (!providers.TryGetValue(provider, out var values))
                {
                    values = new(StringComparer.OrdinalIgnoreCase);
                    providers[provider] = values;
                }
                values[key] = value;
            }
        }
        return (root, providers);
    }

    private static string StripComment(string line)
    {
        var inQuote = false;
        var result = new StringBuilder();
        foreach (var character in line)
        {
            if (character == '"')
                inQuote = !inQuote;
            if (character == '#' && !inQuote)
                break;
            result.Append(character);
        }
        return result.ToString();
    }

    private static string Unquote(string value) =>
        value.Length >= 2 && value[0] == '"' && value[^1] == '"' ? value[1..^1] : value;
}

internal sealed class RepairService
{
    public ScanResult Scan(AppSettings settings)
    {
        var codexHome = Path.GetFullPath(settings.CodexHome);
        var configPath = Path.Combine(codexHome, "config.toml");
        var parsed = ConfigParser.Parse(configPath);
        var provider = parsed.Root.TryGetValue("model_provider", out var configured) && !string.IsNullOrWhiteSpace(configured)
            ? configured
            : "openai";
        var providerSection = parsed.Providers.TryGetValue(provider, out var section) ? section : [];
        var authLabel = provider == "openai"
            ? providerSection.TryGetValue("requires_openai_auth", out var auth) && auth.Equals("false", StringComparison.OrdinalIgnoreCase)
                ? "OpenAI API Key"
                : "OpenAI OAuth"
            : providerSection.TryGetValue("requires_openai_auth", out var customAuth) && customAuth.Equals("true", StringComparison.OrdinalIgnoreCase)
                ? "第三方 API"
                : "自定义 Provider";

        var sqliteHome = settings.SqliteHome;
        if (string.IsNullOrWhiteSpace(sqliteHome) && parsed.Root.TryGetValue("sqlite_home", out var configuredSqlite))
            sqliteHome = ExpandPath(configuredSqlite);
        sqliteHome = ResolveSQLiteHome(codexHome, sqliteHome);
        var state = LatestStateDatabase(sqliteHome);
        var threads = new List<ThreadRow>();
        if (state is not null)
        {
            using var db = new SqliteDatabase(state.Path, true);
            threads = db.QueryThreads();
        }
        var rolloutInfo = RolloutInfoByPath(threads);
        var paginatedScan = settings.AlignProvidersForVisibility
            ? PaginatedProviderPlanner.Scan(codexHome, sqliteHome, threads, provider, state?.Path)
            : new PaginatedProviderScan([], [], []);
        var paginatedRepairIDs = paginatedScan.Repairs.Select(repair => repair.ThreadId).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var paginatedPaths = rolloutInfo
            .Where(item => item.Value.IsPaginated)
            .Select(item => item.Key)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var sqliteProviderUpdates = settings.AlignProvidersForVisibility
            ? ProviderAlignmentRepairs(threads, provider, paginatedPaths, paginatedRepairIDs)
            : ProviderRepairs(threads, rolloutInfo);
        var rolloutRepairs = settings.AlignProvidersForVisibility
            ? RolloutProviderAlignmentRepairs(threads, provider, rolloutInfo)
            : new List<RolloutRepair>();
        var titleRepairs = TitleRepairs(threads);
        var timestampRepairs = TimestampRepairs(threads, rolloutInfo);
        var projectedThreads = ProjectedThreads(threads, titleRepairs, timestampRepairs);

        return new ScanResult
        {
            ProviderInfo = new(provider, authLabel, configPath),
            StateDatabase = state,
            Threads = threads,
            SqliteProviderUpdates = sqliteProviderUpdates,
            SqliteCompatibilityUpdates = [],
            RolloutRepairs = rolloutRepairs,
            PaginatedProviderWarnings = paginatedScan.Warnings,
            PaginatedProviderRepairs = paginatedScan.Repairs,
            PaginatedProviderDiagnostics = paginatedScan.Diagnostics,
            IndexRepairs = IndexRepairs(codexHome, projectedThreads),
            SqliteTimestampRepairs = timestampRepairs,
            SqliteTitleRepairs = titleRepairs,
            RolloutMtimeRepairs = RolloutMtimeRepairs(threads, rolloutInfo),
            GlobalStateRepair = GlobalStateRepair(codexHome, projectedThreads),
            Backups = LoadBackups(codexHome),
            CodexHome = codexHome,
            SqliteHome = sqliteHome,
            AlignProvidersForVisibility = settings.AlignProvidersForVisibility
        };
    }

    public BackupRecord? Repair(ScanResult scan, AppSettings settings, BackupMode mode, bool ignoreCodexRunning = false)
    {
        if (!ignoreCodexRunning && IsCodexRunning())
            throw new InvalidOperationException("检测到 Codex 正在运行。请先退出 Codex，再执行修复。");
        if (scan.StateDatabase is null)
            throw new InvalidOperationException($"未找到状态数据库：{scan.SqliteHome}");
        if (!scan.HasRepairs)
            return null;

        var backup = CreateBackup(scan, mode);
        using (var db = new SqliteDatabase(scan.StateDatabase.Path, false))
        {
            db.UpdateProviders(scan.SqliteProviderUpdates);
            db.UpdateTimestamps(scan.SqliteTimestampRepairs);
            db.UpdateTitles(scan.SqliteTitleRepairs);
            db.UpdateCompatibility(scan.SqliteCompatibilityUpdates.Select(row => row.Id));
        }
        foreach (var repair in scan.RolloutRepairs)
            ApplyRolloutRepair(repair.Path, repair.RepairedFirstLine);
        ApplyRolloutMtimes(scan.RolloutMtimeRepairs);
        if (scan.GlobalStateRepair is not null)
            File.WriteAllText(Path.Combine(scan.CodexHome, ".codex-global-state.json"), scan.GlobalStateRepair.RepairedJson, new UTF8Encoding(false));
        if (scan.IndexRepairs.Count > 0)
            RebuildSessionIndex(scan.IndexRepairs, scan.CodexHome);
        RotateBackups(scan.CodexHome, mode, mode == BackupMode.Full ? settings.FullLimit : settings.LightweightLimit);
        return backup;
    }

    public void RepairPaginated(ScanResult scan, PaginatedProviderRepair repair, AppSettings settings, BackupMode mode, bool ignoreCodexRunning = false)
    {
        if (!ignoreCodexRunning && IsCodexRunning())
            throw new InvalidOperationException("检测到 Codex 正在运行。请先退出 Codex，再执行分页修复。");
        if (!scan.PaginatedProviderRepairs.Any(item => item.Equals(repair)))
            throw new InvalidOperationException("分页修复预览已过期，请重新扫描。");
        var fresh = Scan(settings);
        var current = fresh.PaginatedProviderRepairs.FirstOrDefault(item => item.ThreadId.Equals(repair.ThreadId, StringComparison.OrdinalIgnoreCase));
        if (current is null || !current.Equals(repair))
            throw new InvalidOperationException("分页修复预览已过期，请重新扫描。");
        if (repair.RolloutRepairs.Count == 0 && repair.TurnOffsetRepairs.Count == 0 && repair.ProjectionOffsetRepairs.Count == 0)
            throw new InvalidOperationException("没有可写入的分页修复项。");

        var backup = PaginatedRepairBackup.Create(scan.CodexHome, repair.StateDatabase, repair.HistoryDatabase, repair.RolloutRepairs);
        try
        {
            TrialPaginatedRepair(backup, repair);
            ApplyPaginatedRepair(repair);
            var verified = Scan(settings);
            if (verified.PaginatedProviderRepairs.Any(item => item.ThreadId.Equals(repair.ThreadId, StringComparison.OrdinalIgnoreCase)))
                throw new InvalidOperationException("分页修复后仍有未收敛的偏移或 Provider 项。");
        }
        catch
        {
            try { backup.Restore(); } catch { }
            throw;
        }
    }

    private static void TrialPaginatedRepair(PaginatedRepairBackup backup, PaginatedProviderRepair repair)
    {
        var trialRoot = backup.CreateTrialRoot();
        var trialState = Path.Combine(trialRoot, "state.sqlite");
        var trialHistory = Path.Combine(trialRoot, "history.sqlite");
        File.Copy(backup.StateSnapshot, trialState, true);
        File.Copy(backup.HistorySnapshot, trialHistory, true);
        var thread = new ThreadRow(repair.ThreadId, "", repair.Title, repair.CurrentSQLiteProvider, true, "", "vscode", "user", false, 0, 0, "", "");
        using (var state = new SqliteDatabase(trialState, false))
            state.UpdateProvidersCompareAndSwap([new ProviderRepair(thread, repair.TargetProvider)]);
        using (var history = new SqliteDatabase(trialHistory, false))
        {
            history.UpdatePaginatedTurnOffsets(repair.TurnOffsetRepairs);
            foreach (var projection in repair.ProjectionOffsetRepairs)
                history.UpdatePaginatedProjectionOffset(projection);
            history.CheckIntegrity();
        }
        foreach (var rollout in repair.RolloutRepairs)
        {
            var trialPath = Path.Combine(trialRoot, Path.GetFileName(rollout.Path));
            File.Copy(rollout.Path, trialPath, true);
            PaginatedProviderPlanner.ApplyRolloutRepair(rollout, trialPath);
        }
        using var verifiedState = new SqliteDatabase(trialState, true);
        verifiedState.CheckIntegrity();
    }

    private static void ApplyPaginatedRepair(PaginatedProviderRepair repair)
    {
        var thread = new ThreadRow(repair.ThreadId, "", repair.Title, repair.CurrentSQLiteProvider, true, "", "vscode", "user", false, 0, 0, "", "");
        using (var state = new SqliteDatabase(repair.StateDatabase, false))
            state.UpdateProvidersCompareAndSwap([new ProviderRepair(thread, repair.TargetProvider)]);
        using (var history = new SqliteDatabase(repair.HistoryDatabase, false))
        {
            history.UpdatePaginatedTurnOffsets(repair.TurnOffsetRepairs);
            foreach (var projection in repair.ProjectionOffsetRepairs)
                history.UpdatePaginatedProjectionOffset(projection);
            history.CheckIntegrity();
        }
        foreach (var rollout in repair.RolloutRepairs)
            PaginatedProviderPlanner.ApplyRolloutRepair(rollout);
    }

    public void Restore(BackupRecord backup, bool ignoreCodexRunning = false)
    {
        if (!ignoreCodexRunning && IsCodexRunning())
            throw new InvalidOperationException("检测到 Codex 正在运行。请先退出 Codex，再恢复备份。");
        var manifestPath = Path.Combine(backup.Path, "manifest.json");
        var manifest = JsonSerializer.Deserialize<BackupManifest>(File.ReadAllText(manifestPath), JsonOptions.Pretty)
            ?? throw new InvalidOperationException($"无法读取备份清单：{manifestPath}");

        foreach (var item in manifest.Files)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(item.OriginalPath)!);
            File.Copy(Path.Combine(backup.Path, item.BackupRelativePath), item.OriginalPath, true);
        }
        foreach (var item in manifest.Directories)
        {
            if (Directory.Exists(item.OriginalPath))
                Directory.Delete(item.OriginalPath, true);
            CopyDirectory(Path.Combine(backup.Path, item.BackupRelativePath), item.OriginalPath);
        }
        foreach (var item in manifest.RolloutFirstLines)
            ApplyRolloutRepair(item.OriginalPath, item.FirstLine);
        foreach (var item in manifest.RolloutMtimes ?? [])
            File.SetLastWriteTimeUtc(item.OriginalPath, DateTimeOffset.FromUnixTimeMilliseconds(item.ModifiedAtMs).UtcDateTime);
    }

    public static bool IsCodexRunning()
    {
        foreach (var process in Process.GetProcesses())
        {
            try
            {
                if (process.ProcessName.Equals("Codex", StringComparison.OrdinalIgnoreCase))
                    return true;
            }
            catch
            {
                // Some system processes deny metadata access.
            }
        }
        return false;
    }

    public static void OpenDirectory(string path)
    {
        Directory.CreateDirectory(path);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
    }

    public static void OpenCodex()
    {
        try
        {
            Process.Start(new ProcessStartInfo("explorer.exe", @"shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App") { UseShellExecute = true });
        }
        catch
        {
            Process.Start(new ProcessStartInfo("codex://") { UseShellExecute = true });
        }
    }

    public static string BackupRoot(string codexHome) => Path.Combine(codexHome, "codex-synced-backups");

    private static StateDatabase? LatestStateDatabase(string sqliteHome) =>
        Directory.Exists(sqliteHome)
            ? Directory.EnumerateFiles(sqliteHome, "state_*.sqlite", SearchOption.TopDirectoryOnly)
                .Select(path => new StateDatabase(path, StateDatabaseActivity(path)))
                .OrderByDescending(state => state.ModifiedAt)
                .FirstOrDefault()
            : null;

    private static string ResolveSQLiteHome(string codexHome, string? explicitSQLiteHome)
    {
        if (!string.IsNullOrWhiteSpace(explicitSQLiteHome))
            return Path.GetFullPath(explicitSQLiteHome);

        var rootSQLiteHome = Path.GetFullPath(codexHome);
        var nestedSQLiteHome = Path.Combine(codexHome, "sqlite");
        return new[] { rootSQLiteHome, Path.GetFullPath(nestedSQLiteHome) }
            .Select(directory => (Directory: directory, State: LatestStateDatabase(directory)))
            .Where(item => item.State is not null)
            .OrderByDescending(item => item.State!.ModifiedAt)
            .Select(item => item.Directory)
            .FirstOrDefault() ?? rootSQLiteHome;
    }

    private static DateTime StateDatabaseActivity(string path)
    {
        return new[] { path, path + "-wal", path + "-shm" }
            .Where(File.Exists)
            .Select(File.GetLastWriteTimeUtc)
            .DefaultIfEmpty(DateTime.MinValue)
            .Max();
    }

    private static void ApplyRolloutRepair(string path, string firstLine)
    {
        var temp = path + ".codex-synced.tmp";
        using (var input = OpenSharedRead(path))
        using (var output = File.Create(temp))
        {
            output.Write(Encoding.UTF8.GetBytes(firstLine));
            output.WriteByte((byte)'\n');
            var buffer = new byte[1024 * 1024];
            var foundNewline = false;
            int read;
            while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
            {
                if (foundNewline)
                {
                    output.Write(buffer, 0, read);
                    continue;
                }
                var newline = Array.IndexOf(buffer, (byte)'\n', 0, read);
                if (newline < 0)
                    continue;
                foundNewline = true;
                var suffixStart = newline + 1;
                if (suffixStart < read)
                    output.Write(buffer, suffixStart, read - suffixStart);
            }
        }
        File.Move(temp, path, true);
    }

    private static RolloutRepair? MakeRolloutRepair(string path, string targetProvider)
    {
        if (!File.Exists(path))
            return null;
        var firstLine = ReadFirstLineShared(path);
        if (string.IsNullOrWhiteSpace(firstLine))
            return null;
        JsonObject root;
        try
        {
            root = JsonNode.Parse(firstLine)?.AsObject() ?? new JsonObject();
        }
        catch
        {
            return null;
        }
        if (root["type"]?.GetValue<string>() != "session_meta" || root["payload"] is not JsonObject payload)
            return null;
        var current = payload["model_provider"]?.GetValue<string>();
        if (current == targetProvider)
            return null;
        payload["model_provider"] = targetProvider;
        var repairedFirstLine = root.ToJsonString(new JsonSerializerOptions { WriteIndented = false });
        var sessionId = payload["id"]?.GetValue<string>() ?? Path.GetFileNameWithoutExtension(path);
        return new(path, sessionId, current, targetProvider, firstLine, repairedFirstLine);
    }

    private sealed record RolloutInfo(string? Provider, long? FirstTimestampMs, long? LastTimestampMs, bool IsPaginated);

    private static Dictionary<string, RolloutInfo> RolloutInfoByPath(List<ThreadRow> threads)
    {
        var result = new Dictionary<string, RolloutInfo>(StringComparer.OrdinalIgnoreCase);
        foreach (var path in threads.Select(row => row.RolloutPath).Where(path => !string.IsNullOrWhiteSpace(path)).Distinct(StringComparer.OrdinalIgnoreCase))
            result[path] = InspectRollout(path);
        return result;
    }

    private static RolloutInfo InspectRollout(string path)
    {
        if (!File.Exists(path))
            return new(null, null, null, false);
        string? provider = null;
        long? firstTimestamp = null;
        long? lastTimestamp = null;
        var isPaginated = false;
        foreach (var line in ReadLinesShared(path))
        {
            if (string.IsNullOrWhiteSpace(line))
                continue;
            try
            {
                var node = JsonNode.Parse(line)?.AsObject();
                if (node?["payload"] is JsonObject payload)
                {
                    if (provider is null)
                        provider = payload["model_provider"]?.GetValue<string>();
                    if (payload["history_mode"]?.GetValue<string>() == "paginated" ||
                        payload["history_base"] is JsonObject)
                        isPaginated = true;
                }
                if (node?["ordinal"] is not null)
                    isPaginated = true;
                var timestamp = node?["timestamp"]?.GetValue<string>();
                if (timestamp is not null && TryParseTimestampMs(timestamp, out var parsed))
                {
                    firstTimestamp ??= parsed;
                    lastTimestamp = parsed;
                }
            }
            catch
            {
                // Ignore malformed rollout lines; other lines can still carry usable timestamps.
            }
        }
        return new(provider, firstTimestamp, lastTimestamp, isPaginated);
    }

    private static List<ProviderRepair> ProviderRepairs(List<ThreadRow> threads, Dictionary<string, RolloutInfo> rollouts) =>
        threads
            .Where(row => rollouts.TryGetValue(row.RolloutPath, out var info) && !info.IsPaginated && !string.IsNullOrWhiteSpace(info.Provider) && info.Provider != row.ModelProvider)
            .Select(row => new ProviderRepair(row, rollouts[row.RolloutPath].Provider!))
            .ToList();

    private static List<ProviderRepair> ProviderAlignmentRepairs(List<ThreadRow> threads, string targetProvider, HashSet<string> paginatedPaths, HashSet<string> paginatedRepairIDs) =>
        string.IsNullOrWhiteSpace(targetProvider)
            ? []
            : ProviderAlignmentThreads(threads)
                .Where(row => !paginatedPaths.Contains(row.RolloutPath) && !paginatedRepairIDs.Contains(row.Id) && row.ModelProvider != targetProvider)
                .Select(row => new ProviderRepair(row, targetProvider))
                .ToList();

    private static List<RolloutRepair> RolloutProviderAlignmentRepairs(List<ThreadRow> threads, string targetProvider, Dictionary<string, RolloutInfo> rollouts)
    {
        if (string.IsNullOrWhiteSpace(targetProvider))
            return [];
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        return ProviderAlignmentThreads(threads)
            .Where(row => rollouts.TryGetValue(row.RolloutPath, out var info) && !info.IsPaginated)
            .Where(row => seen.Add(row.RolloutPath))
            .Select(row => MakeRolloutRepair(row.RolloutPath, targetProvider))
            .Where(repair => repair is not null)
            .Select(repair => repair!)
            .ToList();
    }

    private static List<PaginatedProviderWarning> PaginatedProviderWarnings(List<ThreadRow> threads, Dictionary<string, RolloutInfo> rollouts, string targetProvider)
    {
        if (string.IsNullOrWhiteSpace(targetProvider))
            return [];
        return ProviderAlignmentThreads(threads)
            .Select(row => (row, info: rollouts.TryGetValue(row.RolloutPath, out var info) ? info : null))
            .Where(item => item.info is { IsPaginated: true } && !string.IsNullOrWhiteSpace(item.info.Provider) && item.info.Provider != targetProvider)
            .Select(item => new PaginatedProviderWarning(item.row.Id, item.row.Title, item.row.RolloutPath, item.info!.Provider!, targetProvider))
            .ToList();
    }

    private static List<TimestampRepair> TimestampRepairs(List<ThreadRow> threads, Dictionary<string, RolloutInfo> rollouts)
    {
        var repairs = new List<TimestampRepair>();
        foreach (var row in threads)
        {
            if (!rollouts.TryGetValue(row.RolloutPath, out var info))
                continue;
            var currentUpdatedAtMs = row.EffectiveUpdatedAtMs;
            var targetUpdatedAtMs = info.LastTimestampMs ?? currentUpdatedAtMs;
            var updatedChanged = Math.Abs(currentUpdatedAtMs - targetUpdatedAtMs) > 1000;
            long? targetCreatedAtMs = null;
            if (row.EffectiveCreatedAtMs > targetUpdatedAtMs)
            {
                targetCreatedAtMs = new[] { info.FirstTimestampMs, row.EffectiveRecencyAtMs }
                    .Where(value => value.HasValue && value.Value > 0 && value.Value <= targetUpdatedAtMs)
                    .Select(value => value!.Value)
                    .DefaultIfEmpty(targetUpdatedAtMs)
                    .Min();
            }
            if (updatedChanged || targetCreatedAtMs is not null)
            {
                repairs.Add(new(
                    row.Id,
                    row.Title,
                    currentUpdatedAtMs,
                    targetUpdatedAtMs,
                    row.EffectiveCreatedAtMs,
                    targetCreatedAtMs));
            }
        }
        return repairs;
    }

    private static List<TitleRepair> TitleRepairs(List<ThreadRow> threads) =>
        threads
            .Where(row => SidebarSourceKind(row.Source) is not null && RolloutExists(row.RolloutPath))
            .OrderBy(row => row.EffectiveUpdatedAtMs)
            .ThenBy(row => row.Id, StringComparer.OrdinalIgnoreCase)
            .Select(row => (row, title: NormalizeTitleText(row.Title), first: NormalizeTitleText(row.FirstUserMessage)))
            .Where(item => string.IsNullOrWhiteSpace(item.title) || item.title == item.first || LooksCorruptedTitle(item.title))
            .Select(item =>
            {
                var seed = string.IsNullOrWhiteSpace(item.row.Title) || LooksCorruptedTitle(item.title)
                    ? string.IsNullOrWhiteSpace(item.row.Preview) ? item.row.FirstUserMessage : item.row.Preview
                    : item.row.Title;
                return new TitleRepair(item.row.Id, item.row.Title, ShortenSidebarTitle(seed, item.row.Cwd, item.row.FirstUserMessage));
            })
            .Where(repair => !string.IsNullOrWhiteSpace(repair.TargetTitle) && repair.TargetTitle != repair.CurrentTitle)
            .ToList();

    private static List<RolloutMtimeRepair> RolloutMtimeRepairs(List<ThreadRow> threads, Dictionary<string, RolloutInfo> rollouts) =>
        threads
            .Where(row => !row.Archived && ResumeSourceKind(row.Source) is not null && rollouts.TryGetValue(row.RolloutPath, out var info) && info.LastTimestampMs is not null && File.Exists(row.RolloutPath))
            .Select(row => (row, current: new DateTimeOffset(File.GetLastWriteTimeUtc(row.RolloutPath)).ToUnixTimeMilliseconds(), target: rollouts[row.RolloutPath].LastTimestampMs!.Value))
            .Where(item => Math.Abs(item.current - item.target) > 1000)
            .Select(item => new RolloutMtimeRepair(item.row.Id, item.row.Title, item.row.RolloutPath, item.current, item.target))
            .ToList();

    private static List<ThreadRow> ProjectedThreads(List<ThreadRow> threads, List<TitleRepair> titleRepairs, List<TimestampRepair> timestampRepairs)
    {
        var titles = titleRepairs.ToDictionary(repair => repair.ThreadId, repair => repair.TargetTitle, StringComparer.OrdinalIgnoreCase);
        var timestamps = timestampRepairs.ToDictionary(repair => repair.ThreadId, repair => repair.TargetUpdatedAtMs, StringComparer.OrdinalIgnoreCase);
        var createdTimestamps = timestampRepairs
            .Where(repair => repair.TargetCreatedAtMs is not null)
            .ToDictionary(repair => repair.ThreadId, repair => repair.TargetCreatedAtMs!.Value, StringComparer.OrdinalIgnoreCase);
        return threads.Select(row =>
        {
            var title = titles.TryGetValue(row.Id, out var nextTitle) ? nextTitle : row.Title;
            var updatedMs = timestamps.TryGetValue(row.Id, out var nextMs) ? nextMs : row.UpdatedAtMs;
            var updatedAt = timestamps.TryGetValue(row.Id, out var targetMs) ? targetMs / 1000 : row.UpdatedAt;
            var createdMs = createdTimestamps.TryGetValue(row.Id, out var nextCreatedMs) ? nextCreatedMs : row.CreatedAtMs;
            var createdAt = createdTimestamps.TryGetValue(row.Id, out var targetCreatedMs) ? targetCreatedMs / 1000 : row.CreatedAt;
            return row with
            {
                Title = title,
                UpdatedAt = updatedAt,
                UpdatedAtMs = updatedMs,
                CreatedAt = createdAt,
                CreatedAtMs = createdMs
            };
        }).ToList();
    }

    private static List<IndexRepair> IndexRepairs(string codexHome, List<ThreadRow> threads)
    {
        var desired = ResumeInventory(threads);
        var current = LoadIndexEntries(Path.Combine(codexHome, "session_index.jsonl"));
        return current.SequenceEqual(desired) ? [] : desired;
    }

    private static List<IndexRepair> ResumeInventory(List<ThreadRow> threads) =>
        threads
            .Where(row => RolloutExists(row.RolloutPath))
            .OrderBy(row => row.EffectiveUpdatedAtMs)
            .ThenBy(row => row.Id, StringComparer.OrdinalIgnoreCase)
            .Select(row => new IndexRepair(row.Id, row.Title, row.EffectiveUpdatedAtMs))
            .ToList();

    private static List<ThreadRow> ProviderAlignmentThreads(List<ThreadRow> threads) =>
        threads
            .Where(row => SidebarSourceKind(row.Source) is not null && RolloutExists(row.RolloutPath))
            .OrderBy(row => row.EffectiveUpdatedAtMs)
            .ThenBy(row => row.Id, StringComparer.OrdinalIgnoreCase)
            .ToList();

    private static List<ThreadRow> VisibleResumeThreads(List<ThreadRow> threads) =>
        threads
            .Where(row => !row.Archived && ResumeSourceKind(row.Source) is not null && RolloutExists(row.RolloutPath))
            .OrderBy(row => row.EffectiveUpdatedAtMs)
            .ThenBy(row => row.Id, StringComparer.OrdinalIgnoreCase)
            .ToList();

    private static List<IndexRepair> LoadIndexEntries(string indexPath)
    {
        if (!File.Exists(indexPath))
            return [];
        var entries = new List<IndexRepair>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in ReadLinesShared(indexPath))
        {
            if (string.IsNullOrWhiteSpace(line))
                continue;
            try
            {
                var node = JsonNode.Parse(line);
                var id = node?["id"]?.GetValue<string>();
                if (string.IsNullOrWhiteSpace(id) || !seen.Add(id))
                    return [];
                var title = node?["thread_name"]?.GetValue<string>() ?? "";
                var updated = node?["updated_at"]?.GetValue<string>();
                entries.Add(new(id, title, TryParseTimestampMs(updated, out var ms) ? ms : 0));
            }
            catch
            {
                return [];
            }
        }
        return entries;
    }

    private static void RebuildSessionIndex(List<IndexRepair> entries, string codexHome)
    {
        var indexPath = Path.Combine(codexHome, "session_index.jsonl");
        Directory.CreateDirectory(codexHome);
        using var writer = new StreamWriter(indexPath, false, new UTF8Encoding(false));
        foreach (var entry in entries)
        {
            writer.WriteLine(JsonSerializer.Serialize(new
            {
                id = entry.ThreadId,
                thread_name = entry.Title,
                updated_at = IsoFromMs(entry.UpdatedAtMs)
            }));
        }
    }

    private static GlobalStateRepair? GlobalStateRepair(string codexHome, List<ThreadRow> threads)
    {
        var path = Path.Combine(codexHome, ".codex-global-state.json");
        if (!File.Exists(path))
            return null;
        JsonObject root;
        try
        {
            root = JsonNode.Parse(ReadAllTextShared(path))?.AsObject() ?? new JsonObject();
        }
        catch
        {
            return null;
        }

        var changes = new List<string>();
        var selected = root["selected-remote-host-id"]?.GetValue<string>();
        if (selected?.StartsWith("remote-control:", StringComparison.OrdinalIgnoreCase) == true)
        {
            root["selected-remote-host-id"] = "local";
            changes.Add("selected-remote-host-id -> local");
        }

        if (root["remote-connection-auto-connect-by-host-id"] is JsonObject auto)
        {
            foreach (var key in auto.Select(item => item.Key).Where(key => key.StartsWith("remote-control:", StringComparison.OrdinalIgnoreCase)).ToList())
            {
                auto.Remove(key);
                changes.Add("removed remote-control auto-connect entry");
            }
        }

        if (root["added-remote-control-env-ids"] is JsonArray added)
        {
            var local = root["electron-local-remote-control-environment-id"]?.GetValue<string>();
            var filtered = added.Select(value => value?.GetValue<string>()).Where(value => value == local).ToList();
            if (filtered.Count != added.Count)
            {
                var next = new JsonArray();
                foreach (var value in filtered)
                    next.Add(value);
                root["added-remote-control-env-ids"] = next;
                changes.Add("removed stale remote-control env ids");
            }
        }

        var saved = root["electron-saved-workspace-roots"] is JsonArray savedArray
            ? savedArray.Select(value => value?.GetValue<string>()).Where(value => !string.IsNullOrWhiteSpace(value)).Select(value => value!).ToHashSet(StringComparer.OrdinalIgnoreCase)
            : new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var order = root["project-order"] as JsonArray ?? new JsonArray();
        if (root["project-order"] is not JsonArray)
            root["project-order"] = order;
        var orderSet = order.Select(value => value?.GetValue<string>()).Where(value => !string.IsNullOrWhiteSpace(value)).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var project in LocalProjectRoots(threads).Where(project => saved.Contains(project) && orderSet.Add(project)))
        {
            order.Add(project);
            changes.Add($"added project-order {project}");
        }

        if (changes.Count == 0)
            return null;
        return new(changes, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }) + Environment.NewLine);
    }

    private static List<string> LocalProjectRoots(List<ThreadRow> threads)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var roots = new List<string>();
        foreach (var row in VisibleResumeThreads(threads))
        {
            if (!string.IsNullOrWhiteSpace(row.Cwd) && seen.Add(row.Cwd))
                roots.Add(row.Cwd);
        }
        return roots;
    }

    private static void ApplyRolloutMtimes(List<RolloutMtimeRepair> repairs)
    {
        foreach (var repair in repairs)
            File.SetLastWriteTimeUtc(repair.RolloutPath, DateTimeOffset.FromUnixTimeMilliseconds(repair.TargetMtimeMs).UtcDateTime);
    }

    private static string? ResumeSourceKind(string source) =>
        source is "vscode" or "cli" or "exec" ? source : source.Contains("thread_spawn", StringComparison.Ordinal) ? "subagent:thread_spawn" : null;

    private static string? SidebarSourceKind(string source) =>
        source is "vscode" or "cli" or "exec" ? source : null;

    private static bool RolloutExists(string path) => !string.IsNullOrWhiteSpace(path) && File.Exists(path);

    private static string NormalizeTitleText(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
            return "";
        var text = Regex.Replace(value, "<image\\b[^>]*>.*?</image>", " ", RegexOptions.IgnoreCase | RegexOptions.Singleline);
        text = Regex.Replace(text, "<appshot\\b[^>]*>.*?</appshot>", " ", RegexOptions.IgnoreCase | RegexOptions.Singleline);
        text = Regex.Replace(text, "\\[([^\\]]{1,120})\\]\\([^)]+\\)", "$1");
        return Regex.Replace(text, "\\s+", " ").Trim();
    }

    private static bool LooksCorruptedTitle(string value)
    {
        string[] markers =
        [
            "to=functions.",
            "to be plain",
            "need plain text",
            "not xml",
            "wait there is extra",
            "'}]}",
            "}】"
        ];
        return markers.Any(marker => value.Contains(marker, StringComparison.OrdinalIgnoreCase));
    }

    private static string ShortenSidebarTitle(string? value, string? cwd, string? firstUserMessage)
    {
        const int limit = 80;
        var text = NormalizeTitleText(value);
        if (string.IsNullOrWhiteSpace(text))
            text = "Codex thread";
        var punctuation = text.IndexOfAny(['。', '！', '？', '!', '?']);
        if (punctuation >= 0)
            text = text[..(punctuation + 1)].Trim();
        if (text.Length > limit)
            text = text[..(limit - 3)].TrimEnd() + "...";
        if (text == NormalizeTitleText(firstUserMessage))
        {
            var project = string.IsNullOrWhiteSpace(cwd) ? "conversation" : Path.GetFileName(cwd.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
            if (string.IsNullOrWhiteSpace(project))
                project = "conversation";
            text = $"{text} - {project}";
            if (text.Length > limit)
                text = text[..(limit - 3)].TrimEnd() + "...";
        }
        return text;
    }

    private static bool TryParseTimestampMs(string? value, out long ms)
    {
        ms = 0;
        if (string.IsNullOrWhiteSpace(value))
            return false;
        if (!DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed))
            return false;
        ms = parsed.ToUnixTimeMilliseconds();
        return true;
    }

    private static string IsoFromMs(long ms) =>
        DateTimeOffset.FromUnixTimeMilliseconds(ms).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);

    private static BackupRecord CreateBackup(ScanResult scan, BackupMode mode)
    {
        var now = DateTime.UtcNow;
        var directoryName = $"{mode.ToString().ToLowerInvariant()}-{now:yyyyMMdd-HHmmssfff}";
        var directory = Path.Combine(BackupRoot(scan.CodexHome), directoryName);
        Directory.CreateDirectory(directory);
        var summary = new RepairSummary(
            scan.ProviderInfo.Provider,
            scan.SqliteProviderUpdates.Count,
            scan.SqliteCompatibilityUpdates.Count,
            scan.RolloutRepairs.Count + scan.RolloutMtimeRepairs.Count,
            scan.IndexRepairs.Count,
            now);
        var files = new List<BackupFile>();
        var directories = new List<BackupDirectory>();

        void CopyFile(string source, string relative)
        {
            if (!File.Exists(source))
                return;
            var destination = Path.Combine(directory, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            File.Copy(source, destination, true);
            files.Add(new(source, relative));
        }

        if (scan.StateDatabase is not null)
        {
            CopyFile(scan.StateDatabase.Path, Path.Combine("sqlite", Path.GetFileName(scan.StateDatabase.Path)));
            CopyFile(scan.StateDatabase.Path + "-wal", Path.Combine("sqlite", Path.GetFileName(scan.StateDatabase.Path) + "-wal"));
            CopyFile(scan.StateDatabase.Path + "-shm", Path.Combine("sqlite", Path.GetFileName(scan.StateDatabase.Path) + "-shm"));
        }
        CopyFile(Path.Combine(scan.CodexHome, "config.toml"), Path.Combine("codex", "config.toml"));
        CopyFile(Path.Combine(scan.CodexHome, "session_index.jsonl"), Path.Combine("codex", "session_index.jsonl"));
        CopyFile(Path.Combine(scan.CodexHome, ".codex-global-state.json"), Path.Combine("codex", ".codex-global-state.json"));

        void CopyFullDirectory(string name)
        {
            var source = Path.Combine(scan.CodexHome, name);
            if (!Directory.Exists(source))
                return;
            var relative = Path.Combine("codex", name);
            CopyDirectory(source, Path.Combine(directory, relative));
            directories.Add(new(source, relative));
        }
        if (mode == BackupMode.Full)
        {
            CopyFullDirectory("sessions");
            CopyFullDirectory("archived_sessions");
        }

        var firstLines = scan.RolloutRepairs.Select(repair => new BackupFirstLine(repair.Path, repair.OriginalFirstLine)).ToList();
        var mtimes = scan.RolloutMtimeRepairs.Select(repair => new BackupMtime(repair.RolloutPath, repair.CurrentMtimeMs)).ToList();
        var record = new BackupRecord(directoryName, now, mode, scan.ProviderInfo.Provider, summary, 0, directory);
        WriteManifest(directory, new(record, files, directories, firstLines, mtimes));
        record = record with { SizeBytes = DirectorySize(directory) };
        WriteManifest(directory, new(record, files, directories, firstLines, mtimes));
        return record;
    }

    private static void WriteManifest(string directory, BackupManifest manifest) =>
        File.WriteAllText(Path.Combine(directory, "manifest.json"), JsonSerializer.Serialize(manifest, JsonOptions.Pretty));

    private static List<BackupRecord> LoadBackups(string codexHome)
    {
        var root = BackupRoot(codexHome);
        if (!Directory.Exists(root))
            return [];
        var backups = new List<BackupRecord>();
        foreach (var directory in Directory.EnumerateDirectories(root))
        {
            try
            {
                var manifest = JsonSerializer.Deserialize<BackupManifest>(File.ReadAllText(Path.Combine(directory, "manifest.json")), JsonOptions.Pretty);
                if (manifest is not null)
                    backups.Add(manifest.Record with { Path = directory, SizeBytes = DirectorySize(directory) });
            }
            catch
            {
                // Ignore incomplete backup directories.
            }
        }
        return backups.OrderByDescending(backup => backup.CreatedAt).ToList();
    }

    private static void RotateBackups(string codexHome, BackupMode mode, int limit)
    {
        foreach (var backup in LoadBackups(codexHome).Where(backup => backup.Mode == mode).Skip(limit))
            Directory.Delete(backup.Path, true);
    }

    private static void CopyDirectory(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (var file in Directory.EnumerateFiles(source))
            File.Copy(file, Path.Combine(destination, Path.GetFileName(file)), true);
        foreach (var directory in Directory.EnumerateDirectories(source))
            CopyDirectory(directory, Path.Combine(destination, Path.GetFileName(directory)));
    }

    private static long DirectorySize(string directory) =>
        Directory.Exists(directory) ? Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories).Sum(path => new FileInfo(path).Length) : 0;

    private static string ExpandPath(string path)
    {
        if (path == "~")
            return Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (path.StartsWith("~/") || path.StartsWith("~\\"))
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), path[2..]);
        return Environment.ExpandEnvironmentVariables(path);
    }

    private static FileStream OpenSharedRead(string path) =>
        new(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);

    private static IEnumerable<string> ReadLinesShared(string path)
    {
        FileStream stream;
        try
        {
            stream = OpenSharedRead(path);
        }
        catch (IOException)
        {
            yield break;
        }
        catch (UnauthorizedAccessException)
        {
            yield break;
        }

        using (stream)
        using (var reader = new StreamReader(stream, Encoding.UTF8, true))
        {
            while (true)
            {
                string? line;
                try
                {
                    line = reader.ReadLine();
                }
                catch (IOException)
                {
                    yield break;
                }

                if (line is null)
                    yield break;
                yield return line;
            }
        }
    }

    private static string? ReadFirstLineShared(string path)
    {
        try
        {
            using var stream = OpenSharedRead(path);
            using var reader = new StreamReader(stream, Encoding.UTF8, true);
            return reader.ReadLine();
        }
        catch (IOException)
        {
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static string ReadAllTextShared(string path)
    {
        using var stream = OpenSharedRead(path);
        using var reader = new StreamReader(stream, Encoding.UTF8, true);
        return reader.ReadToEnd();
    }

}

internal sealed class SqliteDatabase : IDisposable
{
    private IntPtr _handle;

    public SqliteDatabase(string path, bool readOnly)
    {
        var flags = readOnly ? NativeSqlite.SQLITE_OPEN_READONLY : NativeSqlite.SQLITE_OPEN_READWRITE | NativeSqlite.SQLITE_OPEN_CREATE;
        var result = NativeSqlite.sqlite3_open_v2(path, out _handle, flags, IntPtr.Zero);
        if (result != NativeSqlite.SQLITE_OK)
            throw new InvalidOperationException($"无法打开 SQLite：{ErrorMessage}");
    }

    public List<ThreadRow> QueryThreads()
    {
        var columns = TableColumns("threads");
        var updatedAtMs = columns.Contains("updated_at_ms") ? "updated_at_ms" : "NULL";
        var createdAt = columns.Contains("created_at") ? "created_at" : "0";
        var createdAtMs = columns.Contains("created_at_ms") ? "created_at_ms" : "NULL";
        var recencyAt = columns.Contains("recency_at") ? "recency_at" : "0";
        var recencyAtMs = columns.Contains("recency_at_ms") ? "recency_at_ms" : "NULL";
        var source = columns.Contains("source") ? "source" : "''";
        var firstUser = columns.Contains("first_user_message") ? "first_user_message" : "''";
        var preview = columns.Contains("preview") ? "preview" : "''";
        var title = columns.Contains("name") ? "COALESCE(NULLIF(name, ''), title)" : "title";
        var sql = $"""
            SELECT id, rollout_path, {title}, model_provider, has_user_event, cwd, thread_source, archived, updated_at
                 , {updatedAtMs} AS updated_at_ms
                 , {source} AS source
                 , {firstUser} AS first_user_message
                 , {preview} AS preview
                 , {createdAt} AS created_at
                 , {createdAtMs} AS created_at_ms
                 , {recencyAt} AS recency_at
                 , {recencyAtMs} AS recency_at_ms
            FROM threads
            ORDER BY COALESCE(NULLIF({updatedAtMs}, 0), updated_at * 1000) DESC
            """;
        using var statement = Prepare(sql);
        var rows = new List<ThreadRow>();
        while (NativeSqlite.sqlite3_step(statement.Handle) == NativeSqlite.SQLITE_ROW)
        {
            rows.Add(new(
                statement.Text(0),
                statement.Text(1),
                statement.Text(2),
                statement.Text(3),
                NativeSqlite.sqlite3_column_int(statement.Handle, 4) != 0,
                statement.Text(5),
                statement.Text(10),
                statement.NullableText(6),
                NativeSqlite.sqlite3_column_int(statement.Handle, 7) != 0,
                NativeSqlite.sqlite3_column_int64(statement.Handle, 8),
                statement.NullableInt64(9),
                statement.Text(11),
                statement.Text(12),
                NativeSqlite.sqlite3_column_int64(statement.Handle, 13),
                statement.NullableInt64(14),
                NativeSqlite.sqlite3_column_int64(statement.Handle, 15),
                statement.NullableInt64(16)));
        }
        return rows;
    }

    public List<HistoryEntrypointRow> QueryHistoryEntrypointRows()
    {
        var columns = TableColumns("threads");
        if (!columns.Contains("id") || !columns.Contains("rollout_path"))
            throw new InvalidOperationException("threads 表缺少对话入口字段。");
        var title = columns.Contains("name") && columns.Contains("title") ? "COALESCE(NULLIF(name, ''), title)" : columns.Contains("name") ? "name" : columns.Contains("title") ? "title" : "id";
        var mode = columns.Contains("history_mode") ? "COALESCE(history_mode, '')" : "''";
        using var statement = Prepare($"SELECT id, rollout_path, {title}, {mode} FROM threads ORDER BY id");
        var rows = new List<HistoryEntrypointRow>();
        while (NativeSqlite.sqlite3_step(statement.Handle) == NativeSqlite.SQLITE_ROW)
            rows.Add(new(statement.Text(0), statement.Text(1), statement.Text(2), statement.Text(3)));
        return rows;
    }

    public void ChangeEntrypoint(string threadId, string expectedPath, string targetPath)
    {
        Execute("BEGIN IMMEDIATE");
        try
        {
            using var statement = Prepare("UPDATE threads SET rollout_path = ? WHERE id = ? AND rollout_path = ?");
            statement.BindText(1, targetPath);
            statement.BindText(2, threadId);
            statement.BindText(3, expectedPath);
            if (NativeSqlite.sqlite3_step(statement.Handle) != NativeSqlite.SQLITE_DONE || NativeSqlite.sqlite3_changes(_handle) != 1)
                throw new InvalidOperationException("对话入口已变化，拒绝覆盖。");
            CheckIntegrity();
            Execute("COMMIT");
        }
        catch
        {
            try { Execute("ROLLBACK"); } catch { }
            throw;
        }
    }

    public void UpdateProviders(IEnumerable<ProviderRepair> repairs)
    {
        var values = repairs.ToList();
        if (values.Count == 0)
            return;
        Execute("BEGIN IMMEDIATE");
        try
        {
            using var statement = Prepare("UPDATE threads SET model_provider = ? WHERE id = ?");
            foreach (var repair in values)
            {
                statement.Reset();
                statement.BindText(1, repair.TargetProvider);
                statement.BindText(2, repair.Thread.Id);
                if (NativeSqlite.sqlite3_step(statement.Handle) != NativeSqlite.SQLITE_DONE)
                    throw new InvalidOperationException($"SQLite 更新失败：{ErrorMessage}");
            }
            Execute("COMMIT");
        }
        catch
        {
            try { Execute("ROLLBACK"); } catch { }
            throw;
        }
    }

    public void UpdateProvidersCompareAndSwap(IEnumerable<ProviderRepair> repairs)
    {
        var values = repairs.ToList();
        if (values.Count == 0)
            return;
        Execute("BEGIN IMMEDIATE");
        try
        {
            using var statement = Prepare("UPDATE threads SET model_provider = ? WHERE id = ? AND model_provider = ?");
            foreach (var repair in values)
            {
                statement.Reset();
                statement.BindText(1, repair.TargetProvider);
                statement.BindText(2, repair.Thread.Id);
                statement.BindText(3, repair.Thread.ModelProvider);
                if (NativeSqlite.sqlite3_step(statement.Handle) != NativeSqlite.SQLITE_DONE || NativeSqlite.sqlite3_changes(_handle) != 1)
                    throw new InvalidOperationException("SQLite Provider 数据已变化，拒绝覆盖。");
            }
            Execute("COMMIT");
        }
        catch
        {
            try { Execute("ROLLBACK"); } catch { }
            throw;
        }
    }

    public void UpdateTimestamps(IEnumerable<TimestampRepair> repairs)
    {
        var values = repairs.ToList();
        if (values.Count == 0)
            return;
        var columns = TableColumns("threads");
        var hasUpdatedAtMs = columns.Contains("updated_at_ms");
        var hasCreatedAt = columns.Contains("created_at");
        var hasCreatedAtMs = columns.Contains("created_at_ms");
        Execute("BEGIN IMMEDIATE");
        try
        {
            foreach (var repair in values)
            {
                var assignments = new List<string> { "updated_at = ?" };
                if (hasUpdatedAtMs)
                    assignments.Add("updated_at_ms = ?");
                if (repair.TargetCreatedAtMs is not null && hasCreatedAt)
                {
                    assignments.Add("created_at = ?");
                    if (hasCreatedAtMs)
                        assignments.Add("created_at_ms = ?");
                }
                using var statement = Prepare($"UPDATE threads SET {string.Join(", ", assignments)} WHERE id = ?");
                var index = 1;
                statement.BindInt64(index++, repair.TargetUpdatedAtMs / 1000);
                if (hasUpdatedAtMs)
                    statement.BindInt64(index++, repair.TargetUpdatedAtMs);
                if (repair.TargetCreatedAtMs is long createdAtMs && hasCreatedAt)
                {
                    statement.BindInt64(index++, createdAtMs / 1000);
                    if (hasCreatedAtMs)
                        statement.BindInt64(index++, createdAtMs);
                }
                statement.BindText(index, repair.ThreadId);
                if (NativeSqlite.sqlite3_step(statement.Handle) != NativeSqlite.SQLITE_DONE)
                    throw new InvalidOperationException($"SQLite 更新失败：{ErrorMessage}");
            }
            Execute("COMMIT");
        }
        catch
        {
            try { Execute("ROLLBACK"); } catch { }
            throw;
        }
    }

    public void UpdateTitles(IEnumerable<TitleRepair> repairs)
    {
        var values = repairs.ToList();
        if (values.Count == 0)
            return;
        var hasName = TableColumns("threads").Contains("name");
        Execute("BEGIN IMMEDIATE");
        try
        {
            using var statement = Prepare(hasName
                ? "UPDATE threads SET title = ?, name = ? WHERE id = ?"
                : "UPDATE threads SET title = ? WHERE id = ?");
            foreach (var repair in values)
            {
                statement.Reset();
                statement.BindText(1, repair.TargetTitle);
                if (hasName)
                {
                    statement.BindText(2, repair.TargetTitle);
                    statement.BindText(3, repair.ThreadId);
                }
                else
                {
                    statement.BindText(2, repair.ThreadId);
                }
                if (NativeSqlite.sqlite3_step(statement.Handle) != NativeSqlite.SQLITE_DONE)
                    throw new InvalidOperationException($"SQLite 更新失败：{ErrorMessage}");
            }
            Execute("COMMIT");
        }
        catch
        {
            try { Execute("ROLLBACK"); } catch { }
            throw;
        }
    }

    public void UpdateCompatibility(IEnumerable<string> threadIds) =>
        UpdateMany("""
            UPDATE threads
            SET has_user_event = CASE WHEN has_user_event = 0 THEN 1 ELSE has_user_event END,
                cwd = CASE WHEN cwd = '' THEN '~' ELSE cwd END,
                thread_source = CASE WHEN thread_source IS NULL OR thread_source = '' THEN 'user' ELSE thread_source END
            WHERE id = ?
            """, threadIds, statement => statement.BindText(1, statement.CurrentId!));

    public List<PaginatedTurnRow> PaginatedTurnRows(string threadId)
    {
        var columns = TableColumns("thread_turns");
        if (!columns.IsSupersetOf(["thread_id", "turn_id", "rollout_ordinal", "rollout_byte_offset", "rollout_end_ordinal", "rollout_end_byte_offset"]))
            throw new InvalidOperationException("thread_turns 缺少分页偏移字段，需人工确认。");
        using var statement = Prepare("SELECT thread_id, turn_id, rollout_ordinal, rollout_byte_offset, rollout_end_ordinal, rollout_end_byte_offset FROM thread_turns WHERE thread_id = ? ORDER BY rollout_ordinal, turn_id");
        statement.BindText(1, threadId);
        var rows = new List<PaginatedTurnRow>();
        while (NativeSqlite.sqlite3_step(statement.Handle) == NativeSqlite.SQLITE_ROW)
            rows.Add(new(statement.Text(0), statement.Text(1), NativeSqlite.sqlite3_column_int64(statement.Handle, 2), NativeSqlite.sqlite3_column_int64(statement.Handle, 3), statement.NullableInt64(4), statement.NullableInt64(5)));
        return rows;
    }

    public PaginatedProjectionRow? PaginatedProjectionRow(string threadId)
    {
        var columns = TableColumns("thread_history_projection_state");
        if (!columns.IsSupersetOf(["thread_id", "next_rollout_byte_offset", "next_rollout_ordinal"]))
            throw new InvalidOperationException("projection state 缺少分页偏移字段，需人工确认。");
        using var statement = Prepare("SELECT next_rollout_byte_offset, next_rollout_ordinal FROM thread_history_projection_state WHERE thread_id = ?");
        statement.BindText(1, threadId);
        if (NativeSqlite.sqlite3_step(statement.Handle) != NativeSqlite.SQLITE_ROW)
            return null;
        return new PaginatedProjectionRow(NativeSqlite.sqlite3_column_int64(statement.Handle, 0), NativeSqlite.sqlite3_column_int64(statement.Handle, 1));
    }

    public void UpdatePaginatedTurnOffsets(IEnumerable<PaginatedTurnOffsetRepair> repairs)
    {
        var values = repairs.ToList();
        if (values.Count == 0)
            return;
        Execute("BEGIN IMMEDIATE");
        try
        {
            using var statement = Prepare("UPDATE thread_turns SET rollout_byte_offset = ?, rollout_end_byte_offset = ? WHERE thread_id = ? AND turn_id = ? AND rollout_byte_offset = ? AND ((rollout_end_byte_offset IS NULL AND ? IS NULL) OR rollout_end_byte_offset = ?)");
            foreach (var repair in values)
            {
                statement.Reset();
                statement.BindInt64(1, repair.TargetStartOffset);
                statement.BindOptionalInt64(2, repair.TargetEndOffset);
                statement.BindText(3, repair.ThreadId);
                statement.BindText(4, repair.TurnId);
                statement.BindInt64(5, repair.CurrentStartOffset);
                statement.BindOptionalInt64(6, repair.CurrentEndOffset);
                statement.BindOptionalInt64(7, repair.CurrentEndOffset);
                if (NativeSqlite.sqlite3_step(statement.Handle) != NativeSqlite.SQLITE_DONE || NativeSqlite.sqlite3_changes(_handle) != 1)
                    throw new InvalidOperationException("thread_turns 偏移已变化，拒绝覆盖。");
            }
            Execute("COMMIT");
        }
        catch
        {
            try { Execute("ROLLBACK"); } catch { }
            throw;
        }
    }

    public void UpdatePaginatedProjectionOffset(PaginatedProjectionOffsetRepair repair)
    {
        Execute("BEGIN IMMEDIATE");
        try
        {
            using var statement = Prepare("UPDATE thread_history_projection_state SET next_rollout_byte_offset = ? WHERE thread_id = ? AND next_rollout_byte_offset = ?");
            statement.BindInt64(1, repair.TargetOffset);
            statement.BindText(2, repair.ThreadId);
            statement.BindInt64(3, repair.CurrentOffset);
            if (NativeSqlite.sqlite3_step(statement.Handle) != NativeSqlite.SQLITE_DONE || NativeSqlite.sqlite3_changes(_handle) != 1)
                throw new InvalidOperationException("projection 偏移已变化，拒绝覆盖。");
            Execute("COMMIT");
        }
        catch
        {
            try { Execute("ROLLBACK"); } catch { }
            throw;
        }
    }

    public void BackupTo(string destination)
    {
        if (File.Exists(destination))
            throw new InvalidOperationException($"备份目标已存在：{destination}");
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        using var target = new SqliteDatabase(destination, false);
        var backup = NativeSqlite.sqlite3_backup_init(target._handle, "main", _handle, "main");
        if (backup == IntPtr.Zero)
            throw new InvalidOperationException($"SQLite Backup API 初始化失败：{target.ErrorMessage}");
        var result = NativeSqlite.SQLITE_OK;
        var retries = 0;
        do
        {
            result = NativeSqlite.sqlite3_backup_step(backup, 256);
            if (result is NativeSqlite.SQLITE_BUSY or NativeSqlite.SQLITE_LOCKED)
            {
                retries++;
                NativeSqlite.sqlite3_sleep(20);
            }
        } while (result == NativeSqlite.SQLITE_OK || (result is NativeSqlite.SQLITE_BUSY or NativeSqlite.SQLITE_LOCKED) && retries < 50);
        var finish = NativeSqlite.sqlite3_backup_finish(backup);
        if (result != NativeSqlite.SQLITE_DONE || finish != NativeSqlite.SQLITE_OK)
            throw new InvalidOperationException("SQLite Backup API 未完成。");
        target.CheckIntegrity();
    }

    public void CheckIntegrity()
    {
        using var statement = Prepare("PRAGMA integrity_check");
        if (NativeSqlite.sqlite3_step(statement.Handle) != NativeSqlite.SQLITE_ROW || !string.Equals(statement.Text(0), "ok", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("SQLite integrity_check 失败。");
    }

    public void Execute(string sql)
    {
        var result = NativeSqlite.sqlite3_exec(_handle, sql, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        if (result != NativeSqlite.SQLITE_OK)
            throw new InvalidOperationException($"SQLite 执行失败：{ErrorMessage}");
    }

    private void UpdateMany(string sql, IEnumerable<string> ids, Action<SqliteStatement> bind)
    {
        var values = ids.ToList();
        if (values.Count == 0)
            return;
        Execute("BEGIN IMMEDIATE");
        try
        {
            using var statement = Prepare(sql);
            foreach (var id in values)
            {
                statement.Reset();
                statement.CurrentId = id;
                bind(statement);
                if (NativeSqlite.sqlite3_step(statement.Handle) != NativeSqlite.SQLITE_DONE)
                    throw new InvalidOperationException($"SQLite 更新失败：{ErrorMessage}");
            }
            Execute("COMMIT");
        }
        catch
        {
            try { Execute("ROLLBACK"); } catch { }
            throw;
        }
    }

    private SqliteStatement Prepare(string sql)
    {
        if (NativeSqlite.sqlite3_prepare_v2(_handle, sql, -1, out var statement, IntPtr.Zero) != NativeSqlite.SQLITE_OK)
            throw new InvalidOperationException($"SQLite 查询准备失败：{ErrorMessage}");
        return new(statement);
    }

    private HashSet<string> TableColumns(string table)
    {
        using var statement = Prepare($"PRAGMA table_info({table})");
        var columns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        while (NativeSqlite.sqlite3_step(statement.Handle) == NativeSqlite.SQLITE_ROW)
        {
            var name = statement.NullableText(1);
            if (!string.IsNullOrWhiteSpace(name))
                columns.Add(name);
        }
        return columns;
    }

    private string ErrorMessage => Marshal.PtrToStringUTF8(NativeSqlite.sqlite3_errmsg(_handle)) ?? "unknown";

    private string ErrorMessageForBackup => ErrorMessage;

    public void Dispose()
    {
        if (_handle != IntPtr.Zero)
        {
            NativeSqlite.sqlite3_close(_handle);
            _handle = IntPtr.Zero;
        }
    }
}

internal sealed class SqliteStatement(IntPtr handle) : IDisposable
{
    public IntPtr Handle { get; private set; } = handle;
    public string? CurrentId { get; set; }

    public string Text(int index) => NullableText(index) ?? "";
    public string? NullableText(int index)
    {
        var value = NativeSqlite.sqlite3_column_text(Handle, index);
        return value == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(value);
    }
    public long? NullableInt64(int index) =>
        NativeSqlite.sqlite3_column_type(Handle, index) == NativeSqlite.SQLITE_NULL ? null : NativeSqlite.sqlite3_column_int64(Handle, index);
    public void BindText(int index, string value) => NativeSqlite.sqlite3_bind_text(Handle, index, value, -1, new IntPtr(-1));
    public void BindInt64(int index, long value) => NativeSqlite.sqlite3_bind_int64(Handle, index, value);
    public void BindOptionalInt64(int index, long? value)
    {
        if (value is long number)
            NativeSqlite.sqlite3_bind_int64(Handle, index, number);
        else
            NativeSqlite.sqlite3_bind_null(Handle, index);
    }
    public void Reset()
    {
        NativeSqlite.sqlite3_reset(Handle);
        NativeSqlite.sqlite3_clear_bindings(Handle);
    }
    public void Dispose()
    {
        if (Handle != IntPtr.Zero)
        {
            NativeSqlite.sqlite3_finalize(Handle);
            Handle = IntPtr.Zero;
        }
    }
}

internal static class NativeSqlite
{
    private const string Library = "winsqlite3";
    public const int SQLITE_OK = 0;
    public const int SQLITE_ROW = 100;
    public const int SQLITE_DONE = 101;
    public const int SQLITE_NULL = 5;
    public const int SQLITE_BUSY = 5;
    public const int SQLITE_LOCKED = 6;
    public const int SQLITE_OPEN_READONLY = 0x00000001;
    public const int SQLITE_OPEN_READWRITE = 0x00000002;
    public const int SQLITE_OPEN_CREATE = 0x00000004;

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int sqlite3_open_v2([MarshalAs(UnmanagedType.LPUTF8Str)] string filename, out IntPtr db, int flags, IntPtr vfs);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int sqlite3_close(IntPtr db);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr sqlite3_errmsg(IntPtr db);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int sqlite3_prepare_v2(IntPtr db, [MarshalAs(UnmanagedType.LPUTF8Str)] string sql, int bytes, out IntPtr statement, IntPtr tail);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int sqlite3_step(IntPtr statement);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int sqlite3_finalize(IntPtr statement);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int sqlite3_reset(IntPtr statement);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int sqlite3_clear_bindings(IntPtr statement);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr sqlite3_column_text(IntPtr statement, int index);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int sqlite3_column_type(IntPtr statement, int index);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int sqlite3_column_int(IntPtr statement, int index);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern long sqlite3_column_int64(IntPtr statement, int index);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int sqlite3_bind_text(IntPtr statement, int index, [MarshalAs(UnmanagedType.LPUTF8Str)] string value, int bytes, IntPtr destructor);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int sqlite3_bind_int64(IntPtr statement, int index, long value);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int sqlite3_exec(IntPtr db, [MarshalAs(UnmanagedType.LPUTF8Str)] string sql, IntPtr callback, IntPtr callbackArg, IntPtr errorMessage);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int sqlite3_changes(IntPtr db);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int sqlite3_bind_null(IntPtr statement, int index);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr sqlite3_backup_init(IntPtr destination, [MarshalAs(UnmanagedType.LPUTF8Str)] string destinationName, IntPtr source, [MarshalAs(UnmanagedType.LPUTF8Str)] string sourceName);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int sqlite3_backup_step(IntPtr backup, int pages);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int sqlite3_backup_finish(IntPtr backup);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int sqlite3_sleep(int milliseconds);
}

internal sealed class MainForm : Form
{
    private readonly RepairService _service = new();
    private readonly AppSettings _settings = AppSettings.Load();
    private ScanResult? _scan;
    private readonly Label _status = LabelWithFont(20, FontStyle.Bold);
    private readonly Label _detail = LabelWithFont(10);
    private readonly Label _provider = LabelWithFont(10, FontStyle.Bold);
    private readonly Label _database = LabelWithFont(9);
    private readonly ProgressBar _progressBar = new() { Visible = false, Minimum = 0, Maximum = 100, Style = ProgressBarStyle.Continuous };
    private readonly Label _progressDetail = LabelWithFont(9);
    private readonly Label[] _metrics = [LabelWithFont(24, FontStyle.Bold), LabelWithFont(24, FontStyle.Bold), LabelWithFont(24, FontStyle.Bold), LabelWithFont(24, FontStyle.Bold)];
    private readonly DataGridView _pendingGrid = CreateGrid();
    private readonly DataGridView _backupGrid = CreateGrid();
    private readonly RadioButton _lightweight = new() { Text = "轻量备份", AutoSize = true, Checked = true };
    private readonly RadioButton _full = new() { Text = "全量备份", AutoSize = true };
    private readonly TextBox _codexHome = new() { Dock = DockStyle.Fill };
    private readonly TextBox _sqliteHome = new() { Dock = DockStyle.Fill };
    private readonly NumericUpDown _lightweightLimit = new() { Minimum = 1, Maximum = 30, Width = 72 };
    private readonly NumericUpDown _fullLimit = new() { Minimum = 1, Maximum = 12, Width = 72 };
    private readonly CheckBox _openAfterRepair = new() { Text = "修复完成后自动打开 Codex", AutoSize = true };
    private readonly CheckBox _alignProviders = new() { Text = "跨 Provider 显示历史", AutoSize = true };
    private readonly TabControl _pages = new() { Dock = DockStyle.Fill, Appearance = TabAppearance.FlatButtons, ItemSize = new Size(0, 1), SizeMode = TabSizeMode.Fixed };

    public MainForm()
    {
        Text = "Codex Synced";
        MinimumSize = new Size(920, 640);
        Size = new Size(1120, 760);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(246, 248, 251);
        Font = new Font("Microsoft YaHei UI", 9F);

        var root = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2 };
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 190));
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        Controls.Add(root);
        root.Controls.Add(BuildSidebar(), 0, 0);
        root.Controls.Add(_pages, 1, 0);
        _pages.TabPages.Add(BuildHomePage());
        _pages.TabPages.Add(BuildPendingPage());
        _pages.TabPages.Add(BuildBackupsPage());
        _pages.TabPages.Add(BuildSettingsPage());

        _codexHome.Text = _settings.CodexHome;
        _sqliteHome.Text = _settings.SqliteHome ?? "";
        _lightweightLimit.Value = _settings.LightweightLimit;
        _fullLimit.Value = _settings.FullLimit;
        _openAfterRepair.Checked = _settings.OpenCodexAfterRepair;
        _alignProviders.Checked = _settings.AlignProvidersForVisibility;
        _lightweight.Checked = _settings.DefaultBackupMode == BackupMode.Lightweight;
        _full.Checked = _settings.DefaultBackupMode == BackupMode.Full;
        Shown += async (_, _) => await ScanAsync();
    }

    private Control BuildSidebar()
    {
        var panel = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            Padding = new Padding(14, 22, 14, 14),
            BackColor = Color.FromArgb(27, 35, 48)
        };
        var title = LabelWithFont(15, FontStyle.Bold);
        title.Text = "Codex Synced";
        title.ForeColor = Color.White;
        title.Margin = new Padding(8, 0, 0, 20);
        title.AutoSize = true;
        panel.Controls.Add(title);
        panel.Controls.Add(NavigationButton("修复状态", 0));
        panel.Controls.Add(NavigationButton("待修复项", 1));
        panel.Controls.Add(NavigationButton("备份", 2));
        panel.Controls.Add(NavigationButton("设置", 3));
        return panel;
    }

    private Button NavigationButton(string text, int page)
    {
        var button = new Button
        {
            Text = text,
            FlatStyle = FlatStyle.Flat,
            BackColor = Color.FromArgb(39, 50, 66),
            ForeColor = Color.White,
            Width = 155,
            Height = 42,
            Margin = new Padding(2, 0, 2, 8),
            TextAlign = ContentAlignment.MiddleLeft,
            Padding = new Padding(14, 0, 0, 0)
        };
        button.FlatAppearance.BorderSize = 0;
        button.Click += (_, _) => _pages.SelectedIndex = page;
        return button;
    }

    private TabPage BuildHomePage()
    {
        var page = Page("会话历史修复", "修复 Codex Desktop 侧边栏标题、时间、索引和本地 UI 状态。");
        var body = (FlowLayoutPanel)page.Controls[0];
        var statusCard = Card(860, 172);
        _status.Text = "正在识别当前环境";
        _status.Location = new Point(22, 18);
        _status.AutoSize = true;
        _detail.Text = "不会修改 Token、API Key、第三方 URL 或会话正文。";
        _detail.ForeColor = Color.DimGray;
        _detail.Location = new Point(24, 55);
        _detail.AutoSize = true;
        _provider.Location = new Point(24, 94);
        _provider.AutoSize = true;
        _database.Location = new Point(320, 96);
        _database.AutoSize = true;
        _progressBar.Location = new Point(24, 126);
        _progressBar.Size = new Size(360, 8);
        _progressDetail.Location = new Point(400, 120);
        _progressDetail.Size = new Size(430, 24);
        _progressDetail.ForeColor = Color.DimGray;
        statusCard.Controls.AddRange([_status, _detail, _provider, _database, _progressBar, _progressDetail]);
        body.Controls.Add(statusCard);

        var metricRow = new FlowLayoutPanel { Width = 880, Height = 118, FlowDirection = FlowDirection.LeftToRight, WrapContents = false };
        var labels = new[] { "SQLite Provider", "标题", "索引", "时间/UI" };
        for (var index = 0; index < labels.Length; index++)
        {
            var metric = Card(205, 96);
            _metrics[index].Text = "0";
            _metrics[index].Location = new Point(16, 17);
            _metrics[index].AutoSize = true;
            var caption = new Label { Text = labels[index], Location = new Point(18, 62), AutoSize = true, ForeColor = Color.DimGray };
            metric.Controls.AddRange([_metrics[index], caption]);
            metricRow.Controls.Add(metric);
        }
        body.Controls.Add(metricRow);

        var actions = Card(860, 112);
        actions.Controls.Add(ActionButton("重新扫描", 18, 20, async () => await ScanAsync()));
        actions.Controls.Add(ActionButton("查看待修复项", 154, 20, () => _pages.SelectedIndex = 1));
        actions.Controls.Add(ActionButton("打开备份目录", 330, 20, () => RepairService.OpenDirectory(RepairService.BackupRoot(_settings.CodexHome))));
        actions.Controls.Add(ActionButton("打开 Codex", 498, 20, RepairService.OpenCodex));
        var note = new Label { Text = "请在修复或恢复前退出 Codex。扫描是只读操作。", Location = new Point(20, 76), AutoSize = true, ForeColor = Color.DimGray };
        actions.Controls.Add(note);
        body.Controls.Add(actions);
        return page;
    }

    private TabPage BuildPendingPage()
    {
        var page = Page("待修复项", "修复前预览。确认后先备份，再写入必要的可见性字段。");
        var body = (FlowLayoutPanel)page.Controls[0];
        var choice = Card(860, 72);
        _lightweight.Location = new Point(20, 25);
        _full.Location = new Point(120, 25);
        var repair = ActionButton("备份并修复", 690, 18, RepairAsync);
        choice.Controls.AddRange([_lightweight, _full, repair]);
        body.Controls.Add(choice);
        var gridCard = Card(860, 420);
        _pendingGrid.Dock = DockStyle.Fill;
        gridCard.Controls.Add(_pendingGrid);
        body.Controls.Add(gridCard);
        return page;
    }

    private TabPage BuildBackupsPage()
    {
        var page = Page("备份", "每次写入前都会创建可恢复备份。");
        var body = (FlowLayoutPanel)page.Controls[0];
        var actions = Card(860, 62);
        actions.Controls.Add(ActionButton("恢复选中备份", 18, 12, RestoreSelectedAsync));
        actions.Controls.Add(ActionButton("打开备份目录", 176, 12, () => RepairService.OpenDirectory(RepairService.BackupRoot(_settings.CodexHome))));
        body.Controls.Add(actions);
        var gridCard = Card(860, 430);
        _backupGrid.Dock = DockStyle.Fill;
        gridCard.Controls.Add(_backupGrid);
        body.Controls.Add(gridCard);
        return page;
    }

    private TabPage BuildSettingsPage()
    {
        var page = Page("设置", "Windows 版默认读取 %USERPROFILE%\\.codex。");
        var body = (FlowLayoutPanel)page.Controls[0];
        var card = Card(860, 342);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(16), ColumnCount = 3, RowCount = 7 };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 145));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 94));
        AddSettingsRow(layout, 0, "Codex Home", _codexHome, ChooseCodexHome);
        AddSettingsRow(layout, 1, "SQLite Home", _sqliteHome, ChooseSqliteHome);
        layout.Controls.Add(new Label { Text = "轻量备份上限", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft }, 0, 2);
        layout.Controls.Add(_lightweightLimit, 1, 2);
        layout.Controls.Add(new Label { Text = "全量备份上限", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft }, 0, 3);
        layout.Controls.Add(_fullLimit, 1, 3);
        layout.Controls.Add(_openAfterRepair, 0, 4);
        layout.SetColumnSpan(_openAfterRepair, 2);
        layout.Controls.Add(_alignProviders, 0, 5);
        layout.SetColumnSpan(_alignProviders, 2);
        layout.Controls.Add(ActionButton("保存设置", 0, 0, SaveSettings), 0, 6);
        card.Controls.Add(layout);
        body.Controls.Add(card);
        return page;
    }

    private static TabPage Page(string title, string subtitle)
    {
        var page = new TabPage { BackColor = Color.FromArgb(246, 248, 251), Padding = new Padding(22) };
        var body = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true };
        var header = new Panel { Width = 880, Height = 70 };
        var heading = LabelWithFont(22, FontStyle.Bold);
        heading.Text = title;
        heading.AutoSize = true;
        heading.Location = new Point(0, 2);
        var detail = LabelWithFont(10);
        detail.Text = subtitle;
        detail.ForeColor = Color.DimGray;
        detail.AutoSize = true;
        detail.Location = new Point(2, 40);
        header.Controls.AddRange([heading, detail]);
        body.Controls.Add(header);
        page.Controls.Add(body);
        return page;
    }

    private static Panel Card(int width, int height) => new()
    {
        Width = width,
        Height = height,
        BackColor = Color.White,
        Margin = new Padding(0, 0, 0, 12),
        Padding = new Padding(10)
    };

    private static Label LabelWithFont(float size, FontStyle style = FontStyle.Regular) => new()
    {
        Font = new Font("Microsoft YaHei UI", size, style)
    };

    private static DataGridView CreateGrid() => new()
    {
        ReadOnly = true,
        AllowUserToAddRows = false,
        AllowUserToDeleteRows = false,
        AllowUserToResizeRows = false,
        AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
        BackgroundColor = Color.White,
        BorderStyle = BorderStyle.None,
        RowHeadersVisible = false,
        SelectionMode = DataGridViewSelectionMode.FullRowSelect
    };

    private static Button ActionButton(string text, int left, int top, Action action)
    {
        var button = new Button
        {
            Text = text,
            Location = new Point(left, top),
            AutoSize = true,
            Height = 34,
            FlatStyle = FlatStyle.Flat,
            BackColor = Color.FromArgb(31, 111, 235),
            ForeColor = Color.White,
            Padding = new Padding(8, 0, 8, 0)
        };
        button.FlatAppearance.BorderSize = 0;
        button.Click += (_, _) => action();
        return button;
    }

    private static void AddSettingsRow(TableLayoutPanel layout, int row, string title, TextBox box, Action choose)
    {
        layout.Controls.Add(new Label { Text = title, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft }, 0, row);
        layout.Controls.Add(box, 1, row);
        layout.Controls.Add(ActionButton("选择", 0, 0, choose), 2, row);
    }

    private async Task ScanAsync()
    {
        SetBusy("正在识别当前环境...", "读取 config.toml、状态库和 Provider 设置。", 16);
        await Task.Yield();
        try
        {
            ApplySettings();
            SetBusy("正在扫描本地历史...", "比对 SQLite、rollout 和 session_index。", 42);
            _scan = _service.Scan(_settings);
            _status.Text = _scan.HasRepairs ? $"发现 {_scan.PendingCount} 项待处理" : "侧边栏状态正常";
            _detail.Text = _scan.HasRepairs ? "请查看待修复项，确认变更后执行备份并修复。" : "当前没有待处理项。重新扫描即可检查本地历史。";
            _provider.Text = $"Provider: {_scan.ProviderInfo.Provider}  ·  {_scan.ProviderInfo.AuthLabel}";
            _database.Text = $"状态库: {_scan.StateDatabase?.Path ?? "未找到"}";
            _metrics[0].Text = (_scan.SqliteProviderUpdates.Count + _scan.RolloutRepairs.Count).ToString();
            _metrics[1].Text = _scan.SqliteTitleRepairs.Count.ToString();
            _metrics[2].Text = _scan.IndexRepairs.Count.ToString();
            _metrics[3].Text = (_scan.SqliteTimestampRepairs.Count + _scan.RolloutMtimeRepairs.Count + (_scan.GlobalStateRepair?.Changes.Count ?? 0)).ToString();
            _pendingGrid.DataSource = PreviewRows(_scan).ToList();
            _backupGrid.DataSource = _scan.Backups.Select(backup => new { 时间 = backup.CreatedAt.ToLocalTime(), 模式 = backup.Mode, Provider = backup.TargetProvider, 大小KB = backup.SizeBytes / 1024, 路径 = backup.Path }).ToList();
            ClearBusy();
        }
        catch (Exception ex)
        {
            _status.Text = "扫描失败";
            _detail.Text = ex.Message;
            ClearBusy();
            MessageBox.Show(ex.Message, "扫描失败", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private async void RepairAsync()
    {
        if (_scan is null || !_scan.HasRepairs)
        {
            MessageBox.Show("当前没有待修复项。", "Codex Synced");
            return;
        }
        if (MessageBox.Show($"即将创建备份并修复 {_scan.PendingCount} 项。继续吗？", "确认修复", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK)
            return;
        SetBusy("正在备份并修复...", "创建备份并写入 SQLite、rollout 和索引。", 48);
        await Task.Yield();
        try
        {
            _service.Repair(_scan, _settings, _full.Checked ? BackupMode.Full : BackupMode.Lightweight);
            MessageBox.Show("修复完成。侧边栏会话摘要已经修复。", "Codex Synced", MessageBoxButtons.OK, MessageBoxIcon.Information);
            SetBusy("正在复核结果...", "重新扫描确认修复收敛。", 82);
            await ScanAsync();
            if (_settings.OpenCodexAfterRepair)
                RepairService.OpenCodex();
        }
        catch (Exception ex)
        {
            ClearBusy();
            MessageBox.Show(ex.Message, "修复失败", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private async void RestoreSelectedAsync()
    {
        if (_scan is null || _backupGrid.SelectedRows.Count == 0)
        {
            MessageBox.Show("请先选择一个备份。", "Codex Synced");
            return;
        }
        var index = _backupGrid.SelectedRows[0].Index;
        if (index < 0 || index >= _scan.Backups.Count)
            return;
        var backup = _scan.Backups[index];
        if (MessageBox.Show($"将恢复备份 {backup.DirectoryName}。请确认 Codex 已退出。", "确认恢复", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK)
            return;
        SetBusy("正在恢复备份...", "还原 SQLite、session_index 和 rollout metadata。", 32);
        await Task.Yield();
        try
        {
            _service.Restore(backup);
            MessageBox.Show("备份恢复完成。", "Codex Synced", MessageBoxButtons.OK, MessageBoxIcon.Information);
            SetBusy("正在复核结果...", "重新扫描恢复后的状态。", 82);
            await ScanAsync();
        }
        catch (Exception ex)
        {
            ClearBusy();
            MessageBox.Show(ex.Message, "恢复失败", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private void SetBusy(string message, string detail, int percent)
    {
        _status.Text = message;
        _detail.Text = detail;
        _progressBar.Visible = true;
        _progressBar.Value = Math.Clamp(percent, _progressBar.Minimum, _progressBar.Maximum);
        _progressDetail.Text = $"{percent}% · {detail}";
        Refresh();
    }

    private void ClearBusy()
    {
        _progressBar.Visible = false;
        _progressDetail.Text = "";
        Refresh();
    }

    private static IEnumerable<object> PreviewRows(ScanResult scan)
    {
        foreach (var repair in scan.SqliteProviderUpdates)
            yield return new { 类型 = "Provider 对齐", 标题 = TitleOrId(repair.Thread.Title, repair.Thread.Id), 详情 = $"{repair.Thread.ModelProvider} -> {repair.TargetProvider}" };
        foreach (var repair in scan.RolloutRepairs)
            yield return new { 类型 = "rollout Provider", 标题 = TitleOrId(repair.SessionId, Path.GetFileName(repair.Path)), 详情 = $"{repair.CurrentProvider ?? "nil"} -> {repair.TargetProvider}" };
        foreach (var repair in scan.SqliteTitleRepairs)
            yield return new { 类型 = "标题", 标题 = TitleOrId(repair.TargetTitle, repair.ThreadId), 详情 = TitleOrId(repair.CurrentTitle, "空标题") };
        foreach (var repair in scan.SqliteTimestampRepairs)
            yield return new { 类型 = "时间", 标题 = TitleOrId(repair.Title, repair.ThreadId), 详情 = $"{repair.CurrentUpdatedAtMs} -> {repair.TargetUpdatedAtMs}" };
        foreach (var repair in scan.RolloutMtimeRepairs)
            yield return new { 类型 = "mtime", 标题 = TitleOrId(repair.Title, repair.ThreadId), 详情 = $"{repair.CurrentMtimeMs} -> {repair.TargetMtimeMs}" };
        if (scan.IndexRepairs.Count > 0)
            yield return new { 类型 = "索引", 标题 = "重建 session_index.jsonl", 详情 = $"{scan.IndexRepairs.Count} 条会话" };
        foreach (var change in scan.GlobalStateRepair?.Changes ?? [])
            yield return new { 类型 = "UI 状态", 标题 = change, 详情 = ".codex-global-state.json" };
    }

    private static string TitleOrId(string value, string fallback) =>
        string.IsNullOrWhiteSpace(value) ? fallback : value.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.Trim() ?? fallback;

    private void ApplySettings()
    {
        _settings.CodexHome = _codexHome.Text.Trim();
        _settings.SqliteHome = string.IsNullOrWhiteSpace(_sqliteHome.Text) ? null : _sqliteHome.Text.Trim();
        _settings.LightweightLimit = (int)_lightweightLimit.Value;
        _settings.FullLimit = (int)_fullLimit.Value;
        _settings.OpenCodexAfterRepair = _openAfterRepair.Checked;
        _settings.AlignProvidersForVisibility = _alignProviders.Checked;
        _settings.DefaultBackupMode = _full.Checked ? BackupMode.Full : BackupMode.Lightweight;
    }

    private async void SaveSettings()
    {
        ApplySettings();
        _settings.Save();
        MessageBox.Show("设置已保存。", "Codex Synced");
        await ScanAsync();
    }

    private void ChooseCodexHome() => ChooseFolder(_codexHome);
    private void ChooseSqliteHome() => ChooseFolder(_sqliteHome);
    private static void ChooseFolder(TextBox target)
    {
        using var dialog = new FolderBrowserDialog { SelectedPath = target.Text };
        if (dialog.ShowDialog() == DialogResult.OK)
            target.Text = dialog.SelectedPath;
    }
}

internal static class SelfTest
{
    public static int Run()
    {
        var root = Path.Combine(Path.GetTempPath(), "codex-synced-self-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            File.WriteAllText(Path.Combine(root, "config.toml"), """
                model_provider = "custom"

                [mcp_servers.example]
                model_provider = "ignored"
                """);
            var rolloutDirectory = Path.Combine(root, "sessions", "2026", "06", "01");
            Directory.CreateDirectory(rolloutDirectory);
            var rollout = Path.Combine(rolloutDirectory, "rollout-self-test.jsonl");
            var archivedRollout = Path.Combine(rolloutDirectory, "rollout-archived-test.jsonl");
            File.WriteAllText(rollout, """
                {"timestamp":"2026-06-01T12:00:00.000Z","type":"session_meta","payload":{"id":"self-test","model_provider":"openai","cwd":"C:\\work"}}
                {"timestamp":"2026-06-01T12:05:00.000Z","type":"event_msg","payload":{"message":"keep me"}}
                """);
            File.WriteAllText(archivedRollout, """
                {"timestamp":"2026-06-01T13:00:00.000Z","type":"session_meta","payload":{"id":"archived-test","model_provider":"openai","cwd":"C:\\work"}}
                {"timestamp":"2026-06-01T13:05:00.000Z","type":"event_msg","payload":{"message":"archived body"}}
                """);
            File.SetLastWriteTimeUtc(rollout, DateTimeOffset.FromUnixTimeSeconds(1).UtcDateTime);
            var archivedCreatedMs = DateTimeOffset.Parse("2026-06-01T13:00:00.000Z").ToUnixTimeMilliseconds();
            var archivedUpdatedMs = DateTimeOffset.Parse("2026-06-01T13:05:00.000Z").ToUnixTimeMilliseconds();
            var state = Path.Combine(root, "state_5.sqlite");
            using (var db = new SqliteDatabase(state, false))
            {
                db.Execute("""
                    CREATE TABLE threads (
                        id TEXT PRIMARY KEY,
                        rollout_path TEXT,
                        created_at INTEGER,
                        title TEXT,
                        model_provider TEXT,
                        has_user_event INTEGER,
                        cwd TEXT,
                        source TEXT,
                        thread_source TEXT,
                        archived INTEGER,
                        updated_at INTEGER,
                        updated_at_ms INTEGER,
                        first_user_message TEXT,
                        preview TEXT,
                        created_at_ms INTEGER,
                        recency_at INTEGER,
                        recency_at_ms INTEGER,
                        name TEXT
                    )
                    """);
                db.Execute($"""
                    INSERT INTO threads (
                        id, rollout_path, created_at, title, model_provider, has_user_event, cwd, source,
                        thread_source, archived, updated_at, updated_at_ms, first_user_message, preview,
                        created_at_ms, recency_at, recency_at_ms, name
                    ) VALUES (
                        'self-test',
                        '{rollout.Replace("'", "''")}',
                        1,
                        'Self test',
                        'custom',
                        1,
                        'C:\work',
                        'vscode',
                        'user',
                        0,
                        1,
                        1000,
                        'Self test',
                        '',
                        1000,
                        1,
                        1000,
                        NULL
                    );
                    INSERT INTO threads (
                        id, rollout_path, created_at, title, model_provider, has_user_event, cwd, source,
                        thread_source, archived, updated_at, updated_at_ms, first_user_message, preview,
                        created_at_ms, recency_at, recency_at_ms, name
                    ) VALUES (
                        'archived-test',
                        '{archivedRollout.Replace("'", "''")}',
                        {(archivedCreatedMs + 28_800_000) / 1000},
                        '修改幻灯片大小 Need plain text, not XML',
                        'openai',
                        1,
                        'C:\work',
                        'vscode',
                        'user',
                        1,
                        {archivedUpdatedMs / 1000},
                        {archivedUpdatedMs},
                        '读取os的agent',
                        '读取os的agent',
                        {archivedCreatedMs + 28_800_000},
                        {archivedCreatedMs / 1000},
                        {archivedCreatedMs},
                        NULL
                    )
                    """);
            }
            var settings = new AppSettings { CodexHome = root, OpenCodexAfterRepair = false, AlignProvidersForVisibility = false };
            var service = new RepairService();
            var scan = service.Scan(settings);
            Assert(scan.SqliteProviderUpdates.Count == 1, "SQLite provider repair was not detected.");
            Assert(scan.SqliteTitleRepairs.Count == 2, "Active and corrupted archived title repairs were not detected.");
            Assert(scan.SqliteTimestampRepairs.Count == 2, "Updated-at and created-at repairs were not detected.");
            Assert(scan.SqliteTimestampRepairs.Any(repair => repair.ThreadId == "archived-test" && repair.TargetCreatedAtMs == archivedCreatedMs), "Archived created_at repair was not detected.");
            Assert(scan.RolloutMtimeRepairs.Count == 1, "Rollout mtime repair was not detected.");
            Assert(scan.RolloutRepairs.Count == 0, "Rollout content should not be rewritten.");
            Assert(scan.IndexRepairs.Count == 2, "Index repair did not retain the archived thread.");
            var backup = service.Repair(scan, settings, BackupMode.Lightweight, true);
            Assert(backup is not null, "Backup was not created.");
            var repaired = service.Scan(settings);
            Assert(!repaired.HasRepairs, "Repairs did not converge.");
            Assert(File.ReadAllText(rollout).Contains("\"message\":\"keep me\""), "Rollout body changed unexpectedly.");
            service.Restore(backup!, true);
            var restored = service.Scan(settings);
            Assert(restored.SqliteProviderUpdates.Count == 1, "Restore did not return SQLite provider metadata.");
            settings.AlignProvidersForVisibility = true;
            ScanResult aligned;
            using (new FileStream(rollout, FileMode.Open, FileAccess.Write, FileShare.Read))
            {
                aligned = service.Scan(settings);
            }
            Assert(aligned.SqliteProviderUpdates.Count == 1, "Provider alignment did not include the archived thread.");
            Assert(aligned.RolloutRepairs.Count == 2, "Provider alignment did not include active and archived rollouts.");
            var alignedBackup = service.Repair(aligned, settings, BackupMode.Lightweight, true);
            Assert(alignedBackup is not null, "Provider alignment backup was not created.");
            Assert(File.ReadAllText(rollout).Contains("\"model_provider\":\"custom\""), "Rollout provider was not aligned to custom.");
            Assert(File.ReadAllText(rollout).Contains("\"message\":\"keep me\""), "Rollout body changed unexpectedly during provider alignment.");
            Assert(File.ReadAllText(archivedRollout).Contains("\"model_provider\":\"custom\""), "Archived rollout provider was not aligned to custom.");
            Assert(File.ReadAllText(archivedRollout).Contains("\"message\":\"archived body\""), "Archived rollout body changed unexpectedly.");

            var paginatedRoot = Path.Combine(root, "paginated-safety");
            Directory.CreateDirectory(paginatedRoot);
            File.WriteAllText(Path.Combine(paginatedRoot, "config.toml"), "model_provider = \"custom\"" + Environment.NewLine);
            var paginatedDirectory = Path.Combine(paginatedRoot, "sessions", "2026", "06", "03");
            Directory.CreateDirectory(paginatedDirectory);
            var paginatedRollout = Path.Combine(paginatedDirectory, "rollout-paginated.jsonl");
            File.WriteAllText(paginatedRollout, "{\"timestamp\":\"2026-06-03T12:00:00.000Z\",\"ordinal\":0,\"type\":\"session_meta\",\"payload\":{\"id\":\"paginated\",\"history_mode\":\"paginated\",\"model_provider\":\"openai\"}}" + Environment.NewLine + "{\"ordinal\":1,\"type\":\"event_msg\",\"payload\":{\"message\":\"keep paginated body\"}}" + Environment.NewLine);
            var paginatedState = Path.Combine(paginatedRoot, "state_5.sqlite");
            CreateSingleThreadState(paginatedState, "paginated", paginatedRollout);
            using (var db = new SqliteDatabase(paginatedState, false))
                db.Execute("UPDATE threads SET model_provider = 'openai'");
            var paginatedHistory = Path.Combine(paginatedRoot, "thread_history_1.sqlite");
            CreatePaginatedHistoryState(paginatedHistory, "paginated", paginatedRollout);
            var beforePaginated = File.ReadAllBytes(paginatedRollout);
            var beforePaginatedBody = Encoding.UTF8.GetBytes("{\"ordinal\":1,\"type\":\"event_msg\",\"payload\":{\"message\":\"keep paginated body\"}}" + Environment.NewLine);
            var paginatedScan = service.Scan(new AppSettings { CodexHome = paginatedRoot, OpenCodexAfterRepair = false, AlignProvidersForVisibility = true });
            Assert(paginatedScan.PaginatedProviderWarnings.Count == 0, "A valid paginated Provider plan was incorrectly downgraded to a warning.");
            Assert(paginatedScan.PaginatedProviderRepairs.Count == 1, "Paginated Provider repair was not planned.");
            Assert(paginatedScan.SqliteProviderUpdates.Count == 0, "Paginated thread was incorrectly added to SQLite Provider writes.");
            Assert(paginatedScan.RolloutRepairs.Count == 0, "Paginated rollout was incorrectly added to ordinary header writes.");
            var paginatedRepair = paginatedScan.PaginatedProviderRepairs[0];
            service.RepairPaginated(paginatedScan, paginatedRepair, new AppSettings { CodexHome = paginatedRoot, OpenCodexAfterRepair = false, AlignProvidersForVisibility = true }, BackupMode.Lightweight, true);
            var afterPaginated = File.ReadAllBytes(paginatedRollout);
            Assert(afterPaginated.AsSpan(afterPaginated.Length - beforePaginatedBody.Length).SequenceEqual(beforePaginatedBody), "Paginated rollout body changed during repair.");
            var postPaginated = service.Scan(new AppSettings { CodexHome = paginatedRoot, OpenCodexAfterRepair = false, AlignProvidersForVisibility = true });
            Assert(postPaginated.PaginatedProviderWarnings.Count == 0 && postPaginated.PaginatedProviderRepairs.Count == 0, "Paginated Provider repair did not converge.");
            Assert(postPaginated.SqliteProviderUpdates.Count == 0 && postPaginated.RolloutRepairs.Count == 0, "Paginated Provider writes reappeared after safe repair.");

            var historyRoot = Path.Combine(root, "history-entrypoint");
            Directory.CreateDirectory(historyRoot);
            File.WriteAllText(Path.Combine(historyRoot, "config.toml"), "model_provider = \"custom\"" + Environment.NewLine);
            var historyDirectory = Path.Combine(historyRoot, "sessions", "2026", "06", "04");
            Directory.CreateDirectory(historyDirectory);
            const string logicalHistoryId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
            const string physicalRootId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
            const string physicalChildId = "cccccccc-cccc-cccc-cccc-cccccccccccc";
            var historyRootPath = Path.Combine(historyDirectory, $"rollout-2026-06-04T00-00-00-{logicalHistoryId}_{physicalRootId}.jsonl");
            var historyChildPath = Path.Combine(historyDirectory, $"rollout-2026-06-04T00-01-00-{logicalHistoryId}_{physicalChildId}.jsonl");
            var historyRootLine = "{\"ordinal\":0,\"type\":\"session_meta\",\"payload\":{\"id\":\"" + logicalHistoryId + "\",\"history_mode\":\"paginated\"}}" + Environment.NewLine;
            File.WriteAllText(historyRootPath, historyRootLine);
            var historyChildLine = "{\"ordinal\":1,\"type\":\"session_meta\",\"payload\":{\"id\":\"" + logicalHistoryId + "\",\"history_mode\":\"paginated\",\"history_base\":{\"thread_id\":\"" + physicalRootId + "\",\"end_ordinal_exclusive\":1,\"end_byte_offset\":" + Encoding.UTF8.GetByteCount(historyRootLine) + "}}}" + Environment.NewLine;
            File.WriteAllText(historyChildPath, historyChildLine + "{\"ordinal\":2,\"type\":\"event_msg\",\"payload\":{\"message\":\"new branch\"}}" + Environment.NewLine);
            CreateHistoryEntrypointState(Path.Combine(historyRoot, "state_5.sqlite"), logicalHistoryId, historyRootPath);
            var historyService = new HistoryEntrypointService();
            var historyScan = historyService.Scan(new AppSettings { CodexHome = historyRoot, OpenCodexAfterRepair = false });
            Assert(historyScan.Diagnoses.Count == 1 && historyScan.Diagnoses[0].ProposedPath == historyChildPath, "Chat entrypoint lineage was not diagnosed.");
            var historyRecord = historyService.Repair(historyScan, historyScan.Diagnoses[0], new AppSettings { CodexHome = historyRoot, OpenCodexAfterRepair = false }, true);
            var repairedHistoryScan = historyService.Scan(new AppSettings { CodexHome = historyRoot, OpenCodexAfterRepair = false });
            Assert(repairedHistoryScan.Diagnoses[0].ProposedPath is null && repairedHistoryScan.Diagnoses[0].CurrentPath == historyChildPath, "Chat entrypoint repair did not converge.");
            historyService.Rollback(historyRecord, new AppSettings { CodexHome = historyRoot, OpenCodexAfterRepair = false }, true);
            var rolledBackHistoryScan = historyService.Scan(new AppSettings { CodexHome = historyRoot, OpenCodexAfterRepair = false });
            Assert(rolledBackHistoryScan.Diagnoses[0].ProposedPath == historyChildPath && rolledBackHistoryScan.Diagnoses[0].CurrentPath == historyRootPath, "Chat entrypoint rollback did not restore the original path.");

            var migratedRoot = Path.Combine(root, "migrated-sqlite-home");
            Directory.CreateDirectory(migratedRoot);
            File.WriteAllText(Path.Combine(migratedRoot, "config.toml"), "model_provider = \"custom\"" + Environment.NewLine);
            var migratedRolloutDirectory = Path.Combine(migratedRoot, "sessions", "2026", "06", "02");
            Directory.CreateDirectory(migratedRolloutDirectory);
            var staleRollout = Path.Combine(migratedRolloutDirectory, "rollout-stale.jsonl");
            var activeRollout = Path.Combine(migratedRolloutDirectory, "rollout-active.jsonl");
            File.WriteAllText(staleRollout, "{\"timestamp\":\"2026-06-02T12:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"stale-root\",\"model_provider\":\"custom\"}}" + Environment.NewLine);
            File.WriteAllText(activeRollout, "{\"timestamp\":\"2026-06-02T12:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"active-nested\",\"model_provider\":\"custom\"}}" + Environment.NewLine);
            CreateSingleThreadState(Path.Combine(migratedRoot, "state_5.sqlite"), "stale-root", staleRollout);
            var nestedSqliteHome = Path.Combine(migratedRoot, "sqlite");
            Directory.CreateDirectory(nestedSqliteHome);
            CreateSingleThreadState(Path.Combine(nestedSqliteHome, "state_5.sqlite"), "active-nested", activeRollout);

            var migratedScan = service.Scan(new AppSettings { CodexHome = migratedRoot, OpenCodexAfterRepair = false });
            Assert(Path.GetFullPath(migratedScan.SqliteHome) == Path.GetFullPath(nestedSqliteHome), "Migrated sqlite home was not preferred over stale root database.");
            Assert(migratedScan.Threads.Count == 1 && migratedScan.Threads[0].Id == "active-nested", "Scan used the stale root state database instead of the active sqlite directory.");
            File.SetLastWriteTimeUtc(Path.Combine(migratedRoot, "state_5.sqlite"), DateTime.UtcNow.AddMinutes(1));
            var rootActiveScan = service.Scan(new AppSettings { CodexHome = migratedRoot, OpenCodexAfterRepair = false });
            Assert(Path.GetFullPath(rootActiveScan.SqliteHome) == Path.GetFullPath(migratedRoot), "A newer root state database was ignored.");
            Assert(rootActiveScan.Threads.Count == 1 && rootActiveScan.Threads[0].Id == "stale-root", "Scan did not switch back to the newer root state database.");
            Console.WriteLine("Codex Synced Windows self-test passed.");
            return 0;
        }
        finally
        {
            if (Directory.Exists(root))
                Directory.Delete(root, true);
        }
    }

    private static void Assert(bool condition, string message)
    {
        if (!condition)
            throw new InvalidOperationException(message);
    }

    private static void CreateSingleThreadState(string statePath, string threadId, string rolloutPath)
    {
        using var db = new SqliteDatabase(statePath, false);
        db.Execute("""
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT,
                created_at INTEGER,
                title TEXT,
                model_provider TEXT,
                has_user_event INTEGER,
                cwd TEXT,
                source TEXT,
                thread_source TEXT,
                archived INTEGER,
                updated_at INTEGER,
                updated_at_ms INTEGER,
                first_user_message TEXT,
                preview TEXT
            )
            """);
        db.Execute($"""
            INSERT INTO threads VALUES (
                '{threadId.Replace("'", "''")}',
                '{rolloutPath.Replace("'", "''")}',
                1,
                '{threadId.Replace("'", "''")}',
                'custom',
                1,
                'C:\work',
                'vscode',
                'user',
                0,
                1,
                1000,
                '{threadId.Replace("'", "''")}',
                ''
            )
            """);
    }

    private static void CreatePaginatedHistoryState(string historyPath, string threadId, string rolloutPath)
    {
        var bytes = File.ReadAllBytes(rolloutPath);
        var newline = Array.IndexOf(bytes, (byte)'\n');
        if (newline < 0)
            throw new InvalidOperationException("Paginated self-test rollout has no newline.");
        var firstEnd = newline + 1;
        var fileLength = bytes.Length;
        using var db = new SqliteDatabase(historyPath, false);
        db.Execute("CREATE TABLE thread_turns(thread_id TEXT, turn_id TEXT, rollout_ordinal INTEGER, rollout_byte_offset INTEGER, rollout_end_ordinal INTEGER, rollout_end_byte_offset INTEGER, PRIMARY KEY(thread_id, turn_id))");
        db.Execute("CREATE TABLE thread_history_projection_state(thread_id TEXT PRIMARY KEY, next_rollout_byte_offset INTEGER, next_rollout_ordinal INTEGER)");
        db.Execute($"INSERT INTO thread_turns VALUES ('{threadId}', 'turn-1', 1, {firstEnd}, 2, {fileLength})");
        db.Execute($"INSERT INTO thread_history_projection_state VALUES ('{threadId}', {fileLength}, 2)");
    }

    private static void CreateHistoryEntrypointState(string statePath, string threadId, string rolloutPath)
    {
        using var db = new SqliteDatabase(statePath, false);
        db.Execute("CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT, title TEXT, history_mode TEXT)");
        db.Execute($"INSERT INTO threads VALUES ('{threadId}', '{rolloutPath.Replace("'", "''")}', 'History self-test', 'paginated')");
    }
}
