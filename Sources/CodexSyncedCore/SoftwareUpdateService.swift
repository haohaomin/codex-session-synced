import Foundation

/// Stable release numbers only. Do not infer an installed version for unbundled builds.
public struct ReleaseVersion: Comparable, Sendable {
    private let parts: [Int]

    public init(_ value: String) throws {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, fields.allSatisfy({ field in
            !field.isEmpty && field.count <= 9 && field.utf8.allSatisfy { (48...57).contains($0) }
                && (field.count == 1 || field.first != "0")
        }) else { throw SoftwareUpdateError.invalidVersion }
        parts = fields.map { Int($0)! }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.parts.lexicographicallyPrecedes(rhs.parts)
    }
}

public enum SoftwareUpdateError: String, LocalizedError {
    case invalidVersion = "Cannot compare this version. A stable major.minor.patch version is required."
    case invalidRelease = "The release metadata or platform packages could not be validated."
    case responseTooLarge = "The update response exceeds the 1 MiB limit."
    case httpFailure = "GitHub update check failed (network, rate limit, redirect, or unavailable release). Retry later."
    public var errorDescription: String? { rawValue }
}

public struct SoftwareUpdate: Equatable, Sendable {
    public let version: String
    public let notes: String
    public let pageURL: URL
}

private struct GitHubRelease: Decodable {
    let tag_name: String
    let html_url: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    struct Asset: Decodable {
        let name: String
        let browser_download_url: String
        let size: Int64
        let state: String
    }
}

private final class NoUpdateRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public enum SoftwareUpdateService {
    public static let repositoryURL = "https://github.com/haohaomin/codex-session-synced"
    public static let endpoint = URL(string: "https://api.github.com/repos/haohaomin/codex-session-synced/releases/latest")!
    public static let maximumResponseBytes = 1_048_576

    public static func parse(_ data: Data, currentVersion: String) throws -> SoftwareUpdate? {
        let installed = try ReleaseVersion(currentVersion)
        guard data.count <= maximumResponseBytes else { throw SoftwareUpdateError.responseTooLarge }
        let release: GitHubRelease
        do { release = try JSONDecoder().decode(GitHubRelease.self, from: data) }
        catch { throw SoftwareUpdateError.invalidRelease }
        guard !release.draft, !release.prerelease, release.tag_name.hasPrefix("v") else {
            throw SoftwareUpdateError.invalidRelease
        }
        let version = String(release.tag_name.dropFirst())
        let latest = try ReleaseVersion(version)
        let page = "\(repositoryURL)/releases/tag/v\(version)"
        guard release.html_url == page else { throw SoftwareUpdateError.invalidRelease }
        let name = "Codex-Synced-macOS-\(version).dmg"
        let assets = release.assets.filter { $0.name == name }
        guard assets.count == 1, let asset = assets.first,
              asset.state == "uploaded", asset.size > 0,
              asset.browser_download_url == "\(repositoryURL)/releases/download/v\(version)/\(name)"
        else { throw SoftwareUpdateError.invalidRelease }
        guard latest > installed else { return nil }
        return SoftwareUpdate(version: version, notes: String((release.body ?? "").prefix(12_000)), pageURL: URL(string: page)!)
    }

    /// Reads release metadata only. No package download, filesystem access or installation.
    public static func check(currentVersion: String, configuration: URLSessionConfiguration = .ephemeral) async throws -> SoftwareUpdate? {
        _ = try ReleaseVersion(currentVersion)
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoUpdateRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Codex-Synced-Update-Check", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url == endpoint else {
            throw SoftwareUpdateError.httpFailure
        }
        guard response.expectedContentLength <= maximumResponseBytes else { throw SoftwareUpdateError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else { throw SoftwareUpdateError.responseTooLarge }
            data.append(byte)
        }
        return try parse(data, currentVersion: currentVersion)
    }
}
