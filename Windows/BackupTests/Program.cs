using System.Text.Json;
using CodexSynced.Windows;

var assertions = 0;
void Assert(bool value) { assertions++; if (!value) throw new Exception($"Assertion {assertions} failed"); }
void Reject(Action action)
{
    try { action(); } catch { assertions++; return; }
    throw new Exception("Unsafe operation was not rejected");
}
var service = new BackupManagementService();
foreach (var history in new[] { false, true })
{
    var home = Path.Combine(Path.GetTempPath(), "codex-backup-tests-" + Guid.NewGuid());
    var path = Path.Combine(home, history ? "history-entrypoint-backups" : "codex-synced-backups", "fixture");
    Directory.CreateDirectory(path);
    try
    {
        var manifestPath = Path.Combine(path, history ? "history-repair.json" : "manifest.json");
        var manifest = JsonSerializer.Serialize(new { version = 1, codexHome = home,
            record = new { path, directory = path, directoryName = "fixture", createdAt = DateTime.UtcNow, title = "fixture", targetProvider = "custom" } });
        File.WriteAllText(manifestPath, manifest);
        File.WriteAllText(Path.Combine(home, "live.jsonl"), "keep live messages");
        var item = service.Inventory(home).Items.Single();
        Assert(Directory.Exists(path)); // Inventory/cancel does not delete.
        Assert(File.ReadAllText(manifestPath) == manifest);
        Reject(() => service.Delete(item, Path.Combine(home, "other-home")));
        Reject(() => service.Delete(item with { Directory = Path.GetDirectoryName(path)! }, home));
        File.AppendAllText(manifestPath, "\n");
        Reject(() => service.Delete(item, home));
        Assert(Directory.Exists(path));
        File.WriteAllText(manifestPath, manifest);
        var deleted = service.Delete(item, home);
        Assert(!Directory.Exists(path));
        Assert(service.Inventory(home).Items.Count == 0);
        Assert(File.ReadAllText(Path.Combine(deleted, Path.GetFileName(manifestPath))) == manifest);
        Assert(File.ReadAllText(Path.Combine(home, "live.jsonl")) == "keep live messages");
        Directory.Move(deleted, path);
        Assert(service.Inventory(home).Items.Count == 1);
        var external = Path.Combine(home, "external");
        Directory.Move(path, external);
        Directory.CreateSymbolicLink(path, external);
        Assert(service.Inventory(home).Items.Count == 0);
        Assert(service.Inventory(home).Warnings.Count > 0);
        Reject(() => service.Delete(item, home));
        Assert(Directory.Exists(external));
        Directory.Delete(path);
        Directory.Move(external, path);
        File.Move(manifestPath, Path.Combine(home, "external.json"));
        File.CreateSymbolicLink(manifestPath, Path.Combine(home, "external.json"));
        Assert(service.Inventory(home).Items.Count == 0);
        Reject(() => service.Delete(item, home));
    }
    finally { Directory.Delete(home, true); } // Only this newly-created test fixture.
}
Console.WriteLine($"Backup management tests passed: {assertions} assertions.");
