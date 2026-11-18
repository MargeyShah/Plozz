import XCTest
import Foundation
@testable import CoreModels
import CoreNetworking
@testable import ProviderJellyfin
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Jellyfin applies no Next Up date cutoff unless one is sent, and its base API
/// has no dismissal. These tests pin the two server contracts Plozz relies on:
/// the `nextUpDateCutoff` window its own clients use, and the optional
/// discontinue-watching plugin's denylist.
final class JellyfinNextUpAndDismissalTests: XCTestCase {

    // MARK: - Next Up window

    func testNextUpSendsTheServerDateCutoffAndRewatchingPreference() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/DisplayPreferences/usersettings", json: """
        {"CustomPrefs":{"maxDaysForNextUp":"90","enableRewatchingInNextUp":"true"}}
        """)
        http.stub(pathSuffix: "/Items/Resume", json: #"{"Items":[],"TotalRecordCount":0}"#)
        http.stub(pathSuffix: "/Shows/NextUp", json: #"{"Items":[],"TotalRecordCount":0}"#)

        _ = try await provider(http).continueWatching(limit: 20)

        let query = try XCTUnwrap(http.queryItems(forPathSuffix: "/Shows/NextUp"))
        XCTAssertEqual(query.first { $0.name == "EnableRewatching" }?.value, "true")
        let cutoff = try XCTUnwrap(query.first { $0.name == "NextUpDateCutoff" }?.value)
        XCTAssertEqual(cutoff.count, 10, "Date-only, so a timezone cannot shift the window")
        let expected = JellyfinClient.nextUpDateCutoffString(
            Date().addingTimeInterval(-90 * 86_400)
        )
        XCTAssertEqual(cutoff, expected)
    }

    func testNextUpFallsBackToJellyfinsOwnDefaultOf365Days() async throws {
        // No display preferences stored: Jellyfin Web keeps this value locally,
        // so the server usually has nothing to read.
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/DisplayPreferences/usersettings", json: #"{"CustomPrefs":{}}"#)
        http.stub(pathSuffix: "/Items/Resume", json: #"{"Items":[],"TotalRecordCount":0}"#)
        http.stub(pathSuffix: "/Shows/NextUp", json: #"{"Items":[],"TotalRecordCount":0}"#)

        _ = try await provider(http).continueWatching(limit: 20)

        let query = try XCTUnwrap(http.queryItems(forPathSuffix: "/Shows/NextUp"))
        XCTAssertEqual(
            query.first { $0.name == "NextUpDateCutoff" }?.value,
            JellyfinClient.nextUpDateCutoffString(Date().addingTimeInterval(-365 * 86_400))
        )
        XCTAssertEqual(query.first { $0.name == "EnableRewatching" }?.value, "false")
    }

    func testZeroDaysMeansNoCutoff() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/DisplayPreferences/usersettings", json: """
        {"CustomPrefs":{"maxDaysForNextUp":"0"}}
        """)
        http.stub(pathSuffix: "/Items/Resume", json: #"{"Items":[],"TotalRecordCount":0}"#)
        http.stub(pathSuffix: "/Shows/NextUp", json: #"{"Items":[],"TotalRecordCount":0}"#)

        _ = try await provider(http).continueWatching(limit: 20)

        let query = try XCTUnwrap(http.queryItems(forPathSuffix: "/Shows/NextUp"))
        XCTAssertNil(query.first { $0.name == "NextUpDateCutoff" })
    }

    func testSeriesScopedNextUpKeepsResumableCandidatesAndNoCutoff() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/DisplayPreferences/usersettings", json: """
        {"CustomPrefs":{"maxDaysForNextUp":"30"}}
        """)
        http.stub(pathSuffix: "/Items/Resume", json: #"{"Items":[],"TotalRecordCount":0}"#)
        http.stub(pathSuffix: "/Shows/NextUp", json: #"{"Items":[],"TotalRecordCount":0}"#)

        _ = try await provider(http).resumeEpisode(inSeries: "series-1")

        let query = try XCTUnwrap(http.queryItems(forPathSuffix: "/Shows/NextUp"))
        XCTAssertEqual(query.first { $0.name == "EnableResumable" }?.value, "true")
        XCTAssertNil(
            query.first { $0.name == "NextUpDateCutoff" },
            "A series lookup is about the next episode, not a recent-activity window."
        )
    }

    // MARK: - Dismissal

    func testDismissalUsesThePluginDenylistWhenInstalled() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/DiscontinueWatching/Config", json: #"{"EnableFrontendFiltering":true}"#)
        http.stub(pathSuffix: "/DiscontinueWatching/Items/item-1", json: "{}")

        try await provider(http).removeFromContinueWatching(itemID: "item-1")

        XCTAssertEqual(http.method(forPathSuffix: "/DiscontinueWatching/Items/item-1"), .post)
        XCTAssertFalse(
            http.sentPaths.contains { $0.hasSuffix("UserData") },
            "The plugin preserves the resume point; clearing it would throw progress away."
        )
    }

    func testDismissalFallsBackToClearingThePositionWithoutThePlugin() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/UserItems/item-1/UserData", json: "{}")

        try await provider(http).removeFromContinueWatching(itemID: "item-1")

        XCTAssertTrue(http.sentPaths.contains { $0.hasSuffix("/UserItems/item-1/UserData") })
        XCTAssertFalse(http.sentPaths.contains { $0.contains("DiscontinueWatching/Items") })
    }

    func testPluginProbeIsCachedForTheConnection() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/DiscontinueWatching/Config", json: #"{"EnableFrontendFiltering":true}"#)
        http.stub(pathSuffix: "/DiscontinueWatching/Items/item-1", json: "{}")
        http.stub(pathSuffix: "/DiscontinueWatching/Items/item-2", json: "{}")

        let sut = provider(http)
        try await sut.removeFromContinueWatching(itemID: "item-1")
        try await sut.removeFromContinueWatching(itemID: "item-2")

        XCTAssertEqual(
            http.sentPaths.filter { $0 == "/DiscontinueWatching/Config" }.count, 1
        )
    }

    func testDismissedTitlesAreSubtractedFromBothFeeds() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/DiscontinueWatching/Config", json: #"{"EnableFrontendFiltering":true}"#)
        http.stub(pathSuffix: "/DiscontinueWatching/items", json: "[\"e372e2d1-12fa-dec4-f140-b37f7e955b77\"]")
        http.stub(pathSuffix: "/Items/Resume", json: #"{"Items":[],"TotalRecordCount":0}"#)
        http.stub(pathSuffix: "/Shows/NextUp", json: """
        {"Items":[
          {"Id":"e372e2d112fadec4f140b37f7e955b77","Type":"Episode","SeriesId":"s"},
          {"Id":"kept","Type":"Episode","SeriesId":"s"}],
         "TotalRecordCount":2}
        """)

        let feed = try await provider(http).continueWatching(limit: 20)

        XCTAssertEqual(
            feed.map(\.id), ["kept"],
            "The plugin only filters Resume; Next Up needs the same list applied."
        )
    }

    // MARK: - Helpers

    private func provider(_ http: StubHTTPClient) -> JellyfinProvider {
        JellyfinProvider(session: UserSession(
            server: .init(
                id: "server", name: "Fixture",
                baseURL: URL(string: "http://localhost")!, provider: .jellyfin
            ),
            userID: "user", userName: "Fixture", deviceID: "device", accessToken: "fixture"
        ), http: http)
    }
}
