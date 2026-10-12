import Foundation
import XCTest
import TickRestCore
@testable import TickRestApp

final class AboutCountryTests: XCTestCase {
    @MainActor
    private func lookup(_ json: String, status: Int = 200) async -> AboutCountry? {
        CountryURLProtocol.body = Data(json.utf8)
        CountryURLProtocol.status = status
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return await AboutCountry.lookup(session: session)
    }

    @MainActor
    func testChinaResponseDisplaysRequestedEnglishMessage() async throws {
        let previousLanguage = L10n.language
        L10n.language = "en"
        defer { L10n.language = previousLanguage }
        let result = await lookup("""
        {"countryOrRegion":{"code":"CN","isEUCountry":false},
         "enrichment":{"countryOrRegion":{"name":"China","flag":"🇨🇳"},"continent":{"name":"Asia"}}}
        """)
        let country = try XCTUnwrap(result)
        XCTAssertEqual(country.name, "China")
        XCTAssertEqual(country.availabilityText, "Tick Rest is currently free in your country (China 🇨🇳).")
    }

    @MainActor
    func testOtherCountryUsesAPINameAndFlag() async throws {
        let previousLanguage = L10n.language
        L10n.language = "en"
        defer { L10n.language = previousLanguage }
        let result = await lookup("""
        {"countryOrRegion":{"code":"US"},
         "enrichment":{"countryOrRegion":{"name":"United States of America","flag":"🇺🇸"}}}
        """)
        let country = try XCTUnwrap(result)
        XCTAssertEqual(country.availabilityText, "Tick Rest is currently free in your country (United States of America 🇺🇸).")
    }

    @MainActor
    func testValidResponseTrimsNameFlagAndCode() async throws {
        let result = await lookup("""
        {"countryOrRegion":{"code":" jp "},
         "enrichment":{"countryOrRegion":{"name":" Japan ","flag":" 🇯🇵 "}}}
        """)
        let country = try XCTUnwrap(result)
        XCTAssertEqual(country.code, "JP")
        XCTAssertEqual(country.name, "Japan")
        XCTAssertEqual(country.flag, "🇯🇵")
    }

    @MainActor
    func testIncompleteEnrichmentKeepsDefaultMessage() async {
        let previousLanguage = L10n.language
        L10n.language = "en"
        defer { L10n.language = previousLanguage }
        for enrichment in ["null", "{}", #"{"name":"Japan"}"#, #"{"flag":"🇯🇵"}"#,
                           #"{"name":"  ","flag":"🇯🇵"}"#, #"{"name":"Japan","flag":""}"#,
                           #"{"name":"Japan","flag":"JP"}"#, #"{"name":"Japan","flag":"🇨🇳"}"#] {
            let result = await lookup("""
            {"countryOrRegion":{"code":"JP"},"enrichment":{"countryOrRegion":\(enrichment)}}
            """)
            XCTAssertNil(result)
            XCTAssertEqual(result?.availabilityText ?? L10n.text("about.free"), "Tick Rest is currently free in your country")
        }
    }

    @MainActor
    func testFailedAndInvalidResponsesDoNotGuessCountry() async {
        let httpFailure = await lookup(#"{"countryOrRegion":{"code":"CN"}}"#, status: 503)
        XCTAssertNil(httpFailure)
        for body in ["not JSON", "{}", #"{"countryOrRegion":{"code":"XX"}}"#,
                     #"{"countryOrRegion":{"code":"001"}}"#,
                     #"{"countryOrRegion":{"code":"CN"},"enrichment":{"countryOrRegion":{"name":42,"flag":"🇨🇳"}}}"#] {
            let result = await lookup(body)
            XCTAssertNil(result)
        }
    }

    @MainActor
    func testOfflineRequestReturnsNoCountry() async {
        let result = await lookup("", status: 0)
        XCTAssertNil(result)
    }
}

private final class CountryURLProtocol: URLProtocol {
    static var body = Data()
    static var status = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://who-arrives-api.fthux.com/?fields=flag,names")
        if Self.status == 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
