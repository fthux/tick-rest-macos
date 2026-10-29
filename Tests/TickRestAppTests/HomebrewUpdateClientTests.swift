import Foundation
import XCTest
import TickRestCore
@testable import TickRestApp

final class HomebrewUpdateClientTests: XCTestCase {
    private var session: URLSession!
    private var defaults: UserDefaults!
    private var suite: String!
    private var date = Date(timeIntervalSince1970: 1_790_000_000)
    private let cask = Data("""
    cask "tickrest-dev" do
      version "1.2.0,3"
      depends_on macos: :ventura
      url "https://github.com/fthux/tick-rest-macos-dev/releases/download/build-3/app.zip"
    end
    """.utf8)

    override func setUp() {
        super.setUp()
        suite = "HomebrewUpdateClientTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CaskURLProtocol.self]
        session = URLSession(configuration: config)
        CaskURLProtocol.requests = []
        CaskURLProtocol.respond = { _ in XCTFail("Unexpected network request"); throw URLError(.badURL) }
    }

    override func tearDown() {
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func client() -> HomebrewUpdateClient {
        HomebrewUpdateClient(session: session, channel: .dev, defaults: defaults, now: { [unowned self] in self.date })
    }

    private func contents(_ data: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "file", "encoding": "base64", "content": data.base64EncodedString() + "\n",
                                                   "download_url": "https://raw.githubusercontent.com/never-follow"])
    }

    private func expectError(_ expected: HomebrewUpdateError, client: HomebrewUpdateClient? = nil) async {
        do { _ = try await (client ?? self.client()).fetch(); XCTFail("Expected error") }
        catch { XCTAssertEqual(String(describing: error), String(describing: expected)) }
    }

    func testRawSuccessUsesChannelURLAndNoAPIWithoutNewerVersion() async throws {
        CaskURLProtocol.respond = { [self] request in
            XCTAssertEqual(request.url, AppDistributionChannel.dev.caskURL)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/plain")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, [:], cask)
        }
        let update = try await client().fetch(current: UpdateRelease(version: "1.2.0", build: "3"))
        XCTAssertEqual(update.buildNumber, "3")
        XCTAssertEqual(CaskURLProtocol.requests.count, 1)
    }

    func testRawTransportAndServerFailuresFallBackOnceToBase64Contents() async throws {
        for failure in [0, 500, 503] {
            CaskURLProtocol.requests = []
            CaskURLProtocol.respond = { [self] request in
                if request.url == AppDistributionChannel.dev.caskURL {
                    if failure == 0 { throw URLError(.notConnectedToInternet) }
                    return (failure, [:], Data())
                }
                XCTAssertEqual(request.url, AppDistributionChannel.dev.caskAPIURL)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (200, [:], try contents(cask))
            }
            let update1 = try await client().fetch()
            XCTAssertEqual(update1.version, "1.2.0")
            XCTAssertEqual(CaskURLProtocol.requests.count, 2)
        }
    }

    func testMissingForbiddenOrMalformedRawDoesNotFallBack() async {
        for (status, body, expected) in [(404, Data(), HomebrewUpdateError.unavailable), (403, Data("Forbidden".utf8), .unavailable),
                                         (200, Data("<html>Bad response</html>".utf8), .invalidManifest)] {
            CaskURLProtocol.requests = []
            CaskURLProtocol.respond = { _ in (status, [:], body) }
            await expectError(expected)
            XCTAssertEqual(CaskURLProtocol.requests.count, 1)
        }
    }

    func testRateLimitPersistsAcrossClientsAndHonorsLongestReset() async throws {
        let reset = date.addingTimeInterval(3600)
        CaskURLProtocol.respond = { _ in (429, ["Retry-After": "120", "X-RateLimit-Reset": String(Int(reset.timeIntervalSince1970))], Data()) }
        let first = client()
        await expectError(.rateLimited, client: first)
        XCTAssertEqual(first.retryAfter, reset)
        XCTAssertEqual(CaskURLProtocol.requests.count, 1, "Explicit throttling must not trigger the API fallback")
        await expectError(.rateLimited)
        XCTAssertEqual(CaskURLProtocol.requests.count, 1, "A new client must honor persisted backoff")
        date = reset.addingTimeInterval(1)
        CaskURLProtocol.respond = { [self] _ in (200, [:], cask) }
        let update2 = try await client().fetch()
        XCTAssertEqual(update2.version, "1.2.0")
        XCTAssertEqual(CaskURLProtocol.requests.count, 2)
    }

    func test403RateLimitSignalsAndHTTPDateRetryAfter() async {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        for (headers, body, expectedDelay) in [(["X-RateLimit-Remaining": "0"], "", 60.0),
                                              ([:], "API rate limit exceeded", 60.0),
                                              (["Retry-After": formatter.string(from: date.addingTimeInterval(300))], "", 300.0)] {
            defaults.removeObject(forKey: "homebrewUpdate.githubRetryAfter")
            CaskURLProtocol.requests = []
            CaskURLProtocol.respond = { _ in (403, headers, Data(body.utf8)) }
            await expectError(.rateLimited)
            XCTAssertEqual(client().retryAfter, date.addingTimeInterval(expectedDelay))
            XCTAssertEqual(CaskURLProtocol.requests.count, 1)
        }
    }

    func testAPIRateLimitAlsoBlocksNextRawRequest() async {
        CaskURLProtocol.respond = { request in
            request.url == AppDistributionChannel.dev.caskURL ? (503, [:], Data()) : (429, ["Retry-After": "600"], Data())
        }
        await expectError(.rateLimited)
        await expectError(.rateLimited)
        XCTAssertEqual(CaskURLProtocol.requests.count, 2)
    }

    func testSuccessfulResponseWithZeroRemainingStillChecksVersionButSkipsNotes() async throws {
        CaskURLProtocol.respond = { [self] _ in (200, ["X-RateLimit-Remaining": "0"], cask) }
        let update = try await client().fetch(current: UpdateRelease(version: "1.0.0"))
        XCTAssertEqual(update.version, "1.2.0")
        XCTAssertEqual(update.summary, "")
        XCTAssertNotNil(client().retryAfter)
        XCTAssertEqual(CaskURLProtocol.requests.count, 1)
    }

    func testRawETagAnd304CacheSurviveNewClient() async throws {
        CaskURLProtocol.respond = { [self] _ in (200, ["ETag": "\"cask-1\""], cask) }
        _ = try await client().fetch()
        CaskURLProtocol.respond = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"cask-1\"")
            return (304, [:], Data())
        }
        let update3 = try await client().fetch()
        XCTAssertEqual(update3.version, "1.2.0")
        let update4 = try await client().fetch()
        XCTAssertEqual(update4.version, "1.2.0", "A 304 without ETag must retain the previous ETag")
    }

    func testContentsETagCachesWrapperAndDoesNotFollowDownloadURL() async throws {
        CaskURLProtocol.respond = { [self] request in
            if request.url == AppDistributionChannel.dev.caskURL { return (503, [:], Data()) }
            return (200, ["ETag": "api-1"], try contents(cask))
        }
        _ = try await client().fetch()
        CaskURLProtocol.respond = { request in
            if request.url == AppDistributionChannel.dev.caskURL { return (503, [:], Data()) }
            XCTAssertEqual(request.url, AppDistributionChannel.dev.caskAPIURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "api-1")
            return (304, [:], Data())
        }
        let update5 = try await client().fetch()
        XCTAssertEqual(update5.version, "1.2.0")
        XCTAssertEqual(CaskURLProtocol.requests.count, 4)
    }

    func testInvalidResponsesAreNotCachedAndAPIContentMustBeValid() async {
        CaskURLProtocol.respond = { _ in (200, ["ETag": "invalid"], Data("{}".utf8)) }
        await expectError(.invalidManifest)
        CaskURLProtocol.respond = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
            if request.url == AppDistributionChannel.dev.caskURL { return (500, [:], Data()) }
            return (200, [:], Data("{\"type\":\"dir\",\"encoding\":\"base64\",\"content\":\"\"}".utf8))
        }
        await expectError(.invalidManifest)
    }

    func testOptionalNotesUseActualTagAreCappedAndCached() async throws {
        CaskURLProtocol.respond = { [self] request in
            if request.url == AppDistributionChannel.dev.caskURL { return (200, [:], cask) }
            XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/fthux/tick-rest-macos-dev/releases/tags/build-3")
            return (200, [:], try JSONSerialization.data(withJSONObject: ["body": String(repeating: "x", count: 5000), "draft": false, "prerelease": false]))
        }
        let current = UpdateRelease(version: "1.0.0")
        let first = try await client().fetch(current: current)
        XCTAssertEqual(first.summary.count, 4000)
        let second = try await client().fetch(current: current)
        XCTAssertEqual(second.summary, first.summary)
        XCTAssertEqual(CaskURLProtocol.requests.count, 3)
    }

    func testNotesFailureDoesNotHideValidCaskAndCancellationDoesNotFallBack() async throws {
        CaskURLProtocol.respond = { [self] request in
            if request.url == AppDistributionChannel.dev.caskURL { return (200, [:], cask) }
            return (503, [:], Data())
        }
        let update = try await client().fetch(current: UpdateRelease(version: "1.0.0"))
        XCTAssertEqual(update.version, "1.2.0")
        XCTAssertEqual(update.summary, "")
        CaskURLProtocol.requests = []
        CaskURLProtocol.respond = { _ in throw URLError(.cancelled) }
        do { _ = try await client().fetch(); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(CaskURLProtocol.requests.count, 1)
    }
}

private final class CaskURLProtocol: URLProtocol {
    static var requests: [URLRequest] = []
    static var respond: ((URLRequest) throws -> (Int, [String: String], Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        do {
            let (status, headers, body) = try Self.respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
