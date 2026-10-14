using System.Net.Http;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace CodexSynced.Windows;

internal sealed record SoftwareUpdate(string Version, string Notes, Uri PageUrl);

/// <summary>Release metadata only: no package downloads, filesystem writes or installation.</summary>
internal static class SoftwareUpdateService
{
    internal const string RepositoryUrl = "https://github.com/haohaomin/codex-session-synced";
    internal const string Endpoint = "https://api.github.com/repos/haohaomin/codex-session-synced/releases/latest";
    internal const int MaximumResponseBytes = 1_048_576;

    internal static Version ParseVersion(string value)
    {
        if (!Regex.IsMatch(value, @"\A(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\z"))
            throw new InvalidOperationException("Cannot compare this version. A stable major.minor.patch version is required.");
        return Version.Parse(value);
    }

    private sealed class Release
    {
        [JsonPropertyName("tag_name")] public required string Tag { get; init; }
        [JsonPropertyName("html_url")] public required string Page { get; init; }
        [JsonPropertyName("body")] public string? Body { get; init; }
        [JsonPropertyName("draft")] public required bool Draft { get; init; }
        [JsonPropertyName("prerelease")] public required bool Prerelease { get; init; }
        [JsonPropertyName("assets")] public required Asset[] Assets { get; init; }
    }

    private sealed class Asset
    {
        [JsonPropertyName("name")] public required string Name { get; init; }
        [JsonPropertyName("browser_download_url")] public required string Url { get; init; }
        [JsonPropertyName("size")] public required long Size { get; init; }
        [JsonPropertyName("state")] public required string State { get; init; }
    }

    internal static SoftwareUpdate? Parse(byte[] data, string currentVersion)
    {
        var installed = ParseVersion(currentVersion);
        if (data.Length > MaximumResponseBytes) throw new InvalidOperationException("The update response exceeds the 1 MiB limit.");
        var release = JsonSerializer.Deserialize<Release>(data);
        if (release is null || release.Draft || release.Prerelease || release.Tag is null || !release.Tag.StartsWith('v') || release.Assets is null)
            throw new InvalidOperationException("Invalid stable release metadata.");
        var version = release.Tag[1..];
        var latest = ParseVersion(version);
        var page = $"{RepositoryUrl}/releases/tag/v{version}";
        if (release.Page != page) throw new InvalidOperationException("Untrusted release page.");
        foreach (var extension in new[] { "msi", "zip" })
        {
            var name = $"Codex-Synced-Windows-x64-{version}.{extension}";
            var assets = release.Assets.Where(asset => asset is not null && asset.Name == name).ToArray();
            if (assets.Length != 1 || assets[0].Size <= 0 || assets[0].State != "uploaded" ||
                assets[0].Url != $"{RepositoryUrl}/releases/download/v{version}/{name}")
                throw new InvalidOperationException("The Windows packages could not be validated.");
        }
        return latest > installed
            ? new SoftwareUpdate(version, (release.Body ?? "")[..Math.Min(release.Body?.Length ?? 0, 12_000)], new Uri(page))
            : null;
    }

    internal static async Task<SoftwareUpdate?> CheckAsync(string currentVersion, HttpMessageHandler? handler = null)
    {
        _ = ParseVersion(currentVersion);
        using var client = new HttpClient(handler ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false, UseDefaultCredentials = false });
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        using var request = new HttpRequestMessage(HttpMethod.Get, Endpoint);
        request.Headers.Add("Accept", "application/vnd.github+json");
        request.Headers.Add("User-Agent", "Codex-Synced-Update-Check");
        request.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
        if (response.StatusCode != System.Net.HttpStatusCode.OK)
            throw new InvalidOperationException($"GitHub update check failed (HTTP {(int)response.StatusCode}). Retry later.");
        if (response.Content.Headers.ContentLength > MaximumResponseBytes)
            throw new InvalidOperationException("The update response exceeds the 1 MiB limit.");
        await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
        using var buffer = new System.IO.MemoryStream();
        var block = new byte[8192];
        int read;
        while ((read = await stream.ReadAsync(block, timeout.Token)) != 0)
        {
            if (buffer.Length + read > MaximumResponseBytes)
                throw new InvalidOperationException("The update response exceeds the 1 MiB limit.");
            buffer.Write(block, 0, read);
        }
        return Parse(buffer.ToArray(), currentVersion);
    }
}
