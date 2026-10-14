using System.Net;
using System.Text.Json.Nodes;
using System.Text;
using CodexSynced.Windows;

// Pure updater tests: no WPF runtime, real network or user data required.
var assertions = 0;
void Assert(bool condition) { assertions++; if (!condition) throw new Exception($"Assertion {assertions} failed"); }
void Reject(Action action)
{
    try { action(); } catch { assertions++; return; }
    throw new Exception("Expected rejection");
}
async Task RejectAsync(Func<Task> action)
{
    try { await action(); } catch { assertions++; return; }
    throw new Exception("Expected async rejection");
}
JsonObject Fixture()
{
    var assets = new JsonArray();
    foreach (var extension in new[] { "msi", "zip" })
    {
        var name = $"Codex-Synced-Windows-x64-1.10.0.{extension}";
        assets.Add(new JsonObject { ["name"] = name, ["size"] = 1024, ["state"] = "uploaded",
            ["browser_download_url"] = $"{SoftwareUpdateService.RepositoryUrl}/releases/download/v1.10.0/{name}" });
    }
    return new JsonObject { ["tag_name"] = "v1.10.0", ["draft"] = false, ["prerelease"] = false,
        ["html_url"] = $"{SoftwareUpdateService.RepositoryUrl}/releases/tag/v1.10.0", ["body"] = "Notes", ["assets"] = assets };
}
byte[] Bytes(JsonObject value) => Encoding.UTF8.GetBytes(value.ToJsonString());
SoftwareUpdate? Parse(JsonObject value, string current = "1.8.1") => SoftwareUpdateService.Parse(Bytes(value), current);

Assert(SoftwareUpdateService.ParseVersion("1.10.0") > SoftwareUpdateService.ParseVersion("1.9.9"));
Assert(SoftwareUpdateService.ParseVersion("2.0.0") > SoftwareUpdateService.ParseVersion("1.999.999"));
Assert(Parse(Fixture())?.Version == "1.10.0");
Assert(Parse(Fixture(), "1.10.0") is null);
Assert(Parse(Fixture(), "2.0.0") is null);
foreach (var version in new[] { "dev", "", "1.2", "1.2.3.4", "v1.2.3", "1.2.3-beta", "01.2.3", "1.2.-3", "1.2.٣", "1.2.3\n", "1000000000.0.0" })
    Reject(() => SoftwareUpdateService.ParseVersion(version));
foreach (var field in new[] { "draft", "prerelease" })
{
    var fixture = Fixture(); fixture[field] = true; Reject(() => Parse(fixture));
    fixture.Remove(field); Reject(() => Parse(fixture));
}
foreach (var tag in new[] { "latest", "v1.10.0-beta", "v../evil" })
{
    var fixture = Fixture(); fixture["tag_name"] = tag; Reject(() => Parse(fixture));
}
foreach (var page in new[] { "http://github.com/haohaomin/codex-session-synced/releases/tag/v1.10.0",
    "https://github.com.evil.test/haohaomin/codex-session-synced/releases/tag/v1.10.0",
    "https://github.com/saymyzj/codex-session-synced/releases/tag/v1.10.0",
    $"{SoftwareUpdateService.RepositoryUrl}/releases/tag/v1.9.0",
    $"{SoftwareUpdateService.RepositoryUrl}/releases/tag/v1.10.0?next=evil" })
{
    var fixture = Fixture(); fixture["html_url"] = page; Reject(() => Parse(fixture));
}
foreach (var extensionIndex in new[] { 0, 1 })
{
    foreach (var field in new[] { "name", "state", "browser_download_url" })
    {
        var fixture = Fixture(); fixture["assets"]![extensionIndex]![field] = "invalid"; Reject(() => Parse(fixture));
    }
    foreach (var size in new[] { 0, -1 })
    {
        var fixture = Fixture(); fixture["assets"]![extensionIndex]!["size"] = size; Reject(() => Parse(fixture));
    }
    var missing = Fixture(); missing["assets"]!.AsArray().RemoveAt(extensionIndex); Reject(() => Parse(missing));
    var duplicate = Fixture(); duplicate["assets"]!.AsArray().Add(duplicate["assets"]![extensionIndex]!.DeepClone()); Reject(() => Parse(duplicate));
}
var nullAssets = Fixture(); nullAssets["assets"] = null; Reject(() => Parse(nullAssets));
Reject(() => SoftwareUpdateService.Parse(Encoding.UTF8.GetBytes("{}"), "1.8.1"));
Reject(() => SoftwareUpdateService.Parse(new byte[SoftwareUpdateService.MaximumResponseBytes + 1], "1.8.1"));
var notes = Fixture(); notes["body"] = new string('x', 20_000); Assert(Parse(notes)?.Notes.Length == 12_000);
notes["body"] = null; Assert(Parse(notes)?.Notes == "");

var success = new StubHandler(HttpStatusCode.OK, Bytes(Fixture()));
Assert((await SoftwareUpdateService.CheckAsync("1.8.1", success))?.Version == "1.10.0");
Assert(success.Requests == 1 && success.MetadataOnly);
foreach (var status in new[] { 302, 403, 404, 429, 500 })
    await RejectAsync(() => SoftwareUpdateService.CheckAsync("1.8.1", new StubHandler((HttpStatusCode)status, Bytes(Fixture()))));
await RejectAsync(() => SoftwareUpdateService.CheckAsync("1.8.1", new StubHandler(HttpStatusCode.OK, Encoding.UTF8.GetBytes("broken"))));
await RejectAsync(() => SoftwareUpdateService.CheckAsync("1.8.1", new StubHandler(HttpStatusCode.OK, new byte[SoftwareUpdateService.MaximumResponseBytes + 1])));
await RejectAsync(() => SoftwareUpdateService.CheckAsync("1.8.1", new StubHandler(HttpStatusCode.OK, new byte[SoftwareUpdateService.MaximumResponseBytes + 1], unknownLength: true)));
await RejectAsync(() => SoftwareUpdateService.CheckAsync("1.8.1", new StubHandler(HttpStatusCode.OK, [], offline: true)));
Console.WriteLine($"Software update tests passed: {assertions} assertions.");

sealed class StubHandler(HttpStatusCode status, byte[] data, bool offline = false, bool unknownLength = false) : HttpMessageHandler
{
    internal int Requests { get; private set; }
    internal bool MetadataOnly { get; private set; }
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Requests++;
        MetadataOnly = request.Method == HttpMethod.Get && request.RequestUri?.AbsoluteUri == SoftwareUpdateService.Endpoint && request.Headers.Authorization is null;
        if (!MetadataOnly || offline) throw new HttpRequestException("Simulated network failure");
        return Task.FromResult(new HttpResponseMessage(status) { Content = unknownLength ? new StreamContent(new NonSeekingStream(data)) : new ByteArrayContent(data) });
    }
}

sealed class NonSeekingStream(byte[] data) : MemoryStream(data)
{
    public override bool CanSeek => false;
}
