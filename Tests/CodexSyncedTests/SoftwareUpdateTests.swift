import Foundation
import Testing
@testable import CodexSyncedCore

private func releaseFixture(version: String = "1.10.0", changes: [String: Any] = [:], assetChanges: [String: Any] = [:]) throws -> Data {
    let name = "Codex-Synced-macOS-\(version).dmg"
    var asset: [String: Any] = ["name": name, "size": 1024, "state": "uploaded",
        "browser_download_url": "\(SoftwareUpdateService.repositoryURL)/releases/download/v\(version)/\(name)"]
    asset.merge(assetChanges) { _, new in new }
    var release: [String: Any] = ["tag_name": "v\(version)", "draft": false, "prerelease": false,
        "html_url": "\(SoftwareUpdateService.repositoryURL)/releases/tag/v\(version)",
        "body": "Release notes", "assets": [asset]]
    release.merge(changes) { _, new in new }
    return try JSONSerialization.data(withJSONObject: release)
}

private final class UpdateProtocolStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url == SoftwareUpdateService.endpoint,
              request.value(forHTTPHeaderField: "Authorization") == nil else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let scenario = request.value(forHTTPHeaderField: "Test-Scenario") ?? "200"
        if scenario == "offline" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let payload = scenario == "large" ? Data(repeating: 32, count: SoftwareUpdateService.maximumResponseBytes + 1)
            : scenario == "json" ? Data("broken".utf8) : try! releaseFixture()
        let response = HTTPURLResponse(url: request.url!, statusCode: Int(scenario) ?? 200,
            httpVersion: "HTTP/1.1", headerFields: scenario == "large-header" ? ["Content-Length": "2000000"] : [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct SoftwareUpdateTests {
    @Test func comparesNumericallyAndAvoidsDowngrade() throws {
        #expect(try ReleaseVersion("1.10.0") > ReleaseVersion("1.9.9"))
        #expect(try ReleaseVersion("2.0.0") > ReleaseVersion("1.999.999"))
        #expect(try SoftwareUpdateService.parse(releaseFixture(), currentVersion: "1.8.1")?.version == "1.10.0")
        #expect(try SoftwareUpdateService.parse(releaseFixture(), currentVersion: "1.10.0") == nil)
        #expect(try SoftwareUpdateService.parse(releaseFixture(), currentVersion: "2.0.0") == nil)
    }

    @Test(arguments: ["dev", "", "1.2", "1.2.3.4", "v1.2.3", "1.2.3-beta", "01.2.3", "1.2.-3", "1.2.٣", "1.2.3\n", "1000000000.0.0"])
    func rejectsInvalidVersion(value: String) {
        #expect(throws: (any Error).self) { try ReleaseVersion(value) }
    }

    @Test func rejectsDraftPrereleaseAndWrongTag() throws {
        for change: [String: Any] in [["draft": true], ["prerelease": true], ["tag_name": "latest"], ["tag_name": "v1.2.3-beta"], ["draft": NSNull()]] {
            let data = try releaseFixture(changes: change)
            #expect(throws: (any Error).self) { try SoftwareUpdateService.parse(data, currentVersion: "1.8.1") }
        }
    }

    @Test func rejectsUntrustedPages() throws {
        for url in ["http://github.com/haohaomin/codex-session-synced/releases/tag/v1.10.0",
                    "https://github.com.evil.test/haohaomin/codex-session-synced/releases/tag/v1.10.0",
                    "https://github.com/saymyzj/codex-session-synced/releases/tag/v1.10.0",
                    "\(SoftwareUpdateService.repositoryURL)/releases/tag/v1.9.0",
                    "\(SoftwareUpdateService.repositoryURL)/releases/tag/v1.10.0?next=evil"] {
            let data = try releaseFixture(changes: ["html_url": url])
            #expect(throws: (any Error).self) { try SoftwareUpdateService.parse(data, currentVersion: "1.8.1") }
        }
    }

    @Test func rejectsInvalidPlatformPackages() throws {
        for change: [String: Any] in [["name": "windows.zip"], ["size": 0], ["size": -1], ["state": "new"],
                                     ["browser_download_url": "https://evil.test/package.dmg"],
                                     ["browser_download_url": "\(SoftwareUpdateService.repositoryURL)/releases/download/v1.8.1/Codex-Synced-macOS-1.8.1.dmg"]] {
            let data = try releaseFixture(assetChanges: change)
            #expect(throws: (any Error).self) { try SoftwareUpdateService.parse(data, currentVersion: "1.8.1") }
        }
        let valid = try #require(JSONSerialization.jsonObject(with: releaseFixture()) as? [String: Any])
        let assets = try #require(valid["assets"] as? [[String: Any]])
        for badAssets in [[], assets + assets] {
            let data = try releaseFixture(changes: ["assets": badAssets])
            #expect(throws: (any Error).self) { try SoftwareUpdateService.parse(data, currentVersion: "1.8.1") }
        }
    }

    @Test func boundsAndPlainNotes() throws {
        let body = String(repeating: "x", count: 20_000)
        #expect(try SoftwareUpdateService.parse(releaseFixture(changes: ["body": body]), currentVersion: "1.8.1")?.notes.count == 12_000)
        #expect(try SoftwareUpdateService.parse(releaseFixture(changes: ["body": NSNull()]), currentVersion: "1.8.1")?.notes == "")
        #expect(throws: (any Error).self) { try SoftwareUpdateService.parse(Data("{}".utf8), currentVersion: "1.8.1") }
        #expect(throws: (any Error).self) { try SoftwareUpdateService.parse(Data(repeating: 32, count: 1_048_577), currentVersion: "1.8.1") }
    }

    @Test func networkOnlyRequestsMetadata() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateProtocolStub.self]
        #expect(try await SoftwareUpdateService.check(currentVersion: "1.8.1", configuration: config)?.version == "1.10.0")
    }

    @Test(arguments: ["403", "404", "429", "500", "302", "offline", "json", "large", "large-header"])
    func rejectsNetworkFailures(scenario: String) async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateProtocolStub.self]
        config.httpAdditionalHeaders = ["Test-Scenario": scenario]
        await #expect(throws: (any Error).self) {
            try await SoftwareUpdateService.check(currentVersion: "1.8.1", configuration: config)
        }
    }
}
