import Foundation
import TickRestCore

/// Raw is authoritative. The public Contents API is a one-shot fallback for transport/5xx failures.
/// A confirmed rate limit cools down both paths, including optional release-note requests.
final class HomebrewUpdateClient {
    let channel: AppDistributionChannel
    private let session: URLSession
    private let defaults: UserDefaults
    private let now: () -> Date
    private let prefix: String
    private static let backoffKey = "homebrewUpdate.githubRetryAfter"

    init(session: URLSession = .shared, channel: AppDistributionChannel = HomebrewUpdateConfiguration.channel,
         defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.session = session; self.channel = channel; self.defaults = defaults; self.now = now
        prefix = "homebrewUpdate.caskHTTP." + channel.rawValue + "."
    }

    var retryAfter: Date? {
        guard let date = defaults.object(forKey: Self.backoffKey) as? Date, date > now() else { return nil }
        return date
    }

    func fetch(current: UpdateRelease? = nil) async throws -> HomebrewUpdateManifest {
        let result: Response
        let viaAPI: Bool
        do {
            result = try await get(channel.caskURL, key: "raw", accept: "text/plain", limit: 64 * 1024)
            viaAPI = false
        } catch RequestFailure.fallback {
            // Never use download_url: it would send the client back to the Raw host.
            result = try await get(channel.caskAPIURL, key: "contents", accept: "application/vnd.github+json", limit: 128 * 1024)
            viaAPI = true
        }
        let bytes: Data
        if viaAPI {
            struct Contents: Decodable { let type: String; let encoding: String; let content: String }
            guard let contents = try? JSONDecoder().decode(Contents.self, from: result.data),
                  contents.type == "file", contents.encoding == "base64",
                  let decoded = Data(base64Encoded: contents.content, options: .ignoreUnknownCharacters) else {
                throw HomebrewUpdateError.invalidManifest
            }
            bytes = decoded
        } else { bytes = result.data }
        let update = try HomebrewCaskUpdate.parse(bytes, channel: channel)
        cache(result, key: viaAPI ? "contents" : "raw")
        guard let current, try update.isNewer(than: current.version, currentBuild: current.build) else { return update }
        return try await addingReleaseNotes(to: update)
    }

    private func addingReleaseNotes(to update: HomebrewUpdateManifest) async throws -> HomebrewUpdateManifest {
        let tag = update.releaseNotesURL.lastPathComponent
        let key = "notes." + update.release.identifier + "." + tag
        if let text = defaults.string(forKey: prefix + key) { return update.withSummary(text) }
        var components = URLComponents(string: "https://api.github.com/repos/fthux/\(channel.repository)/releases/tags/")!
        components.path += tag
        guard let url = components.url else { return update }
        do {
            let response = try await get(url, key: nil, accept: "application/vnd.github+json", limit: 512 * 1024, timeout: 8)
            struct Release: Decodable { let body: String?; let draft: Bool; let prerelease: Bool }
            guard let release = try? JSONDecoder().decode(Release.self, from: response.data),
                  !release.draft, !release.prerelease else { return update }
            let notes = String((release.body ?? "").prefix(4000))
            defaults.set(notes, forKey: prefix + key)
            return update.withSummary(notes)
        } catch is CancellationError { throw CancellationError() }
        catch { return update } // Notes are optional; a ready Cask remains installable without them.
    }

    private struct Response { let data: Data; let etag: String? }
    private enum RequestFailure: Error { case fallback }

    private func get(_ url: URL, key: String?, accept: String, limit: Int, timeout: TimeInterval = 20) async throws -> Response {
        try Task.checkCancellation()
        guard retryAfter == nil else { throw HomebrewUpdateError.rateLimited }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("TickRest-Updater", forHTTPHeaderField: "User-Agent")
        let cached = key.flatMap { defaults.data(forKey: prefix + $0 + ".body") }
        if let key, cached != nil, let etag = defaults.string(forKey: prefix + key + ".etag") {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch {
            if key == "raw" { throw RequestFailure.fallback }
            throw HomebrewUpdateError.network
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw HomebrewUpdateError.unavailable }
        let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining")
        let retry = http.value(forHTTPHeaderField: "Retry-After")
        let rateMessage = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        let limited = http.statusCode == 429 || (http.statusCode == 403 &&
            (remaining == "0" || retry != nil || rateMessage.contains("rate limit")))
        if limited || remaining == "0" {
            var until = now().addingTimeInterval(60)
            if let retry {
                if let seconds = TimeInterval(retry) { until = max(until, now().addingTimeInterval(seconds)) }
                else {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                    if let date = formatter.date(from: retry) { until = max(until, date) }
                }
            }
            if let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset"), let epoch = TimeInterval(reset) {
                until = max(until, Date(timeIntervalSince1970: epoch))
            }
            defaults.set(max(retryAfter ?? until, until), forKey: Self.backoffKey)
        }
        if limited { throw HomebrewUpdateError.rateLimited }
        if http.statusCode == 304, let cached {
            let etag = http.value(forHTTPHeaderField: "ETag") ?? key.flatMap { defaults.string(forKey: prefix + $0 + ".etag") }
            return Response(data: cached, etag: etag)
        }
        if (500...599).contains(http.statusCode) {
            if key == "raw" { throw RequestFailure.fallback }
            throw HomebrewUpdateError.unavailable
        }
        guard http.statusCode == 200 else { throw HomebrewUpdateError.unavailable }
        guard data.count <= limit else { throw HomebrewUpdateError.invalidManifest }
        return Response(data: data, etag: http.value(forHTTPHeaderField: "ETag"))
    }

    private func cache(_ response: Response, key: String) {
        defaults.set(response.data, forKey: prefix + key + ".body")
        if let etag = response.etag { defaults.set(etag, forKey: prefix + key + ".etag") }
        else { defaults.removeObject(forKey: prefix + key + ".etag") }
    }
}
