using System.IO;
using System.Security.Cryptography;
using System.Text.Json;

namespace CodexSynced.Windows;

internal sealed record ManagedBackup(string Directory, bool IsHistory, DateTime CreatedAt, string Title,
    string RecordJson, string ManifestHash, DateTime DirectoryCreatedAt);
internal sealed record BackupInventory(List<ManagedBackup> Items, List<string> Warnings);

/// <summary>Read-only inventory and recoverable deletion, independent of the conversation scan.</summary>
internal sealed class BackupManagementService
{
    internal static string DeletedRoot(string home) => Path.Combine(Path.GetFullPath(home), "codex-synced-deleted-backups");

    internal BackupInventory Inventory(string home)
    {
        var items = new List<ManagedBackup>();
        var warnings = new List<string>();
        foreach (var history in new[] { false, true })
        {
            var root = Root(home, history);
            if (!Directory.Exists(root)) continue;
            try
            {
                RequireDirectory(root);
                foreach (var path in Directory.EnumerateFileSystemEntries(root))
                {
                    try { items.Add(Read(path, history, home)); }
                    catch (Exception error) { warnings.Add($"{Path.GetFileName(path)}: {error.Message}"); }
                }
            }
            catch (Exception error) { warnings.Add($"{root}: {error.Message}"); }
        }
        return new(items.OrderByDescending(item => item.CreatedAt).ToList(), warnings);
    }

    internal string Delete(ManagedBackup item, string home)
    {
        var fresh = Read(item.Directory, item.IsHistory, home);
        if (fresh.ManifestHash != item.ManifestHash || fresh.DirectoryCreatedAt != item.DirectoryCreatedAt)
            throw new InvalidOperationException("备份已变化，请刷新后重新确认。Backup changed; refresh and confirm again.");
        // A same-volume rename guarantees recoverability even when the Windows Recycle Bin is disabled.
        // Never use recursive deletion or fall back to permanent deletion.
        var deleted = DeletedRoot(home);
        if (File.Exists(deleted)) throw new IOException("已删除备份目录被文件占用。Deleted-backup directory is occupied by a file.");
        if (Directory.Exists(deleted)) RequireDirectory(deleted);
        else Directory.CreateDirectory(deleted);
        RequireDirectory(deleted);
        var destination = Path.Combine(deleted, Guid.NewGuid().ToString("N") + "-" + Path.GetFileName(item.Directory));
        Directory.Move(fresh.Directory, destination);
        return destination;
    }

    private static string Root(string home, bool history) => Path.Combine(Path.GetFullPath(home), history ? "history-entrypoint-backups" : "codex-synced-backups");
    private static bool Same(string a, string b) => string.Equals(Path.GetFullPath(a).TrimEnd(Path.DirectorySeparatorChar), Path.GetFullPath(b).TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase);
    private static void RequireDirectory(string path)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.Directory) == 0 || (attributes & FileAttributes.ReparsePoint) != 0)
            throw new IOException("拒绝链接或非目录。Linked or non-directory backups are not allowed.");
    }

    private static ManagedBackup Read(string path, bool history, string home)
    {
        path = Path.GetFullPath(path);
        var root = Root(home, history);
        if (!Same(Path.GetDirectoryName(path)!, root))
            throw new IOException("只能删除当前备份目录内的一份备份。Only a direct backup under the current backup root may be deleted.");
        RequireDirectory(root);
        RequireDirectory(path);
        var manifest = Path.Combine(path, history ? "history-repair.json" : "manifest.json");
        if ((File.GetAttributes(manifest) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0)
            throw new IOException("备份描述文件无效。Invalid backup manifest.");
        var bytes = File.ReadAllBytes(manifest);
        using var json = JsonDocument.Parse(bytes);
        var record = json.RootElement.GetProperty("record");
        if (history)
        {
            if (json.RootElement.GetProperty("version").GetInt32() != 1 || !Same(record.GetProperty("directory").GetString()!, path) ||
                !Same(json.RootElement.GetProperty("codexHome").GetString()!, home))
                throw new IOException("修复记录位置无效。Invalid repair-record location.");
        }
        else if (!Same(record.GetProperty("path").GetString()!, path) || record.GetProperty("directoryName").GetString() != Path.GetFileName(path))
            throw new IOException("备份位置与记录不一致。Backup location does not match its manifest.");
        var title = history ? record.GetProperty("title").GetString()! : record.GetProperty("targetProvider").GetString()!;
        return new(path, history, record.GetProperty("createdAt").GetDateTime(), title, record.GetRawText(),
            Convert.ToHexString(SHA256.HashData(bytes)), Directory.GetCreationTimeUtc(path));
    }
}
