import Foundation
import TickRestCore

/// Keep only the country name, code and flag; other geolocation fields are not retained.
struct AboutCountry {
    let code: String
    let name: String
    let flag: String

    var availabilityText: String {
        L10n.text("about.free_country", "\(name) \(flag)")
    }

    static func lookup(session: URLSession = .shared) async -> AboutCountry? {
        let url = URL(string: "https://who-arrives-api.fthux.com/?fields=flag,names")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { return nil }
            let result = try JSONDecoder().decode(Response.self, from: data)
            let code = result.countryOrRegion.code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard code.unicodeScalars.count == 2,
                  code.unicodeScalars.allSatisfy({ (65...90).contains($0.value) }),
                  Locale.Region.isoRegions.contains(where: { $0.identifier == code }) else { return nil }
            guard let name = result.enrichment?.countryOrRegion?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  let flag = result.enrichment?.countryOrRegion?.flag?.trimmingCharacters(in: .whitespacesAndNewlines)
            else { return nil }
            // A valid country flag is the regional-indicator pair for its country code.
            let expectedFlag = String(String.UnicodeScalarView(code.unicodeScalars.compactMap {
                UnicodeScalar(0x1F1E6 + $0.value - 65)
            }))
            guard flag == expectedFlag else { return nil }
            return AboutCountry(code: code, name: name, flag: flag)
        } catch {
            // The About page remains usable offline, without guessing a country.
            return nil
        }
    }

    private struct Response: Decodable {
        struct Country: Decodable { let code: String }
        struct Enrichment: Decodable {
            struct Country: Decodable { let name: String?; let flag: String? }
            let countryOrRegion: Country?
        }
        let countryOrRegion: Country
        let enrichment: Enrichment?
    }
}
