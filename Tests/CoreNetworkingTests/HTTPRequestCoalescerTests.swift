import Foundation
import XCTest
@testable import CoreNetworking

final class HTTPRequestCoalescerTests: XCTestCase {
    private actor Counter {
        private(set) var value = 0

        func increment() -> Int {
            value += 1
            return value
        }
    }

    func testConcurrentIdenticalRequestsShareOneTransfer() async throws {
        let coalescer = HTTPRequestCoalescer()
        let counter = Counter()
        let key = HTTPRequestCoalescer.Key(
            method: "GET", url: "https://example.test/Items", headers: "authorization=token"
        )

        async let first = coalescer.perform(key: key) {
            _ = await counter.increment()
            try? await Task.sleep(for: .milliseconds(120))
            return makeCoalescedPayload("first")
        }
        try await Task.sleep(for: .milliseconds(30))
        async let second = coalescer.perform(key: key) {
            _ = await counter.increment()
            return makeCoalescedPayload("second")
        }

        let (owner, joiner) = try await (first, second)
        XCTAssertFalse(owner.joined)
        XCTAssertTrue(joiner.joined)
        XCTAssertEqual(owner.payload.data, Data("first".utf8))
        XCTAssertEqual(joiner.payload.data, Data("first".utf8))
        let transfers = await counter.value
        XCTAssertEqual(transfers, 1, "The second caller must join the in-flight transfer")
    }

    func testDifferentKeysDoNotShare() async throws {
        let coalescer = HTTPRequestCoalescer()
        let counter = Counter()

        let first = HTTPRequestCoalescer.Key(method: "GET", url: "https://example.test/a", headers: "")
        let second = HTTPRequestCoalescer.Key(method: "GET", url: "https://example.test/b", headers: "")

        async let a = coalescer.perform(key: first) {
            _ = await counter.increment()
            try? await Task.sleep(for: .milliseconds(60))
            return makeCoalescedPayload("a")
        }
        async let b = coalescer.perform(key: second) {
            _ = await counter.increment()
            return makeCoalescedPayload("b")
        }

        let (left, right) = try await (a, b)
        XCTAssertFalse(left.joined)
        XCTAssertFalse(right.joined)
        XCTAssertEqual(left.payload.data, Data("a".utf8))
        XCTAssertEqual(right.payload.data, Data("b".utf8))
        let transfers = await counter.value
        XCTAssertEqual(transfers, 2)
    }

    func testDifferentLanesDoNotShareEvenForTheSameURL() async throws {
        let coalescer = HTTPRequestCoalescer()
        let counter = Counter()
        async let defaultLane = coalescer.perform(
            key: HTTPRequestCoalescer.Key(
                method: "GET", url: "https://example.test/same", headers: "", lane: "default"
            )
        ) {
            _ = await counter.increment()
            try? await Task.sleep(for: .milliseconds(60))
            return makeCoalescedPayload("default")
        }
        async let discoveryLane = coalescer.perform(
            key: HTTPRequestCoalescer.Key(
                method: "GET", url: "https://example.test/same", headers: "", lane: "discovery"
            )
        ) {
            _ = await counter.increment()
            return makeCoalescedPayload("discovery")
        }

        let (left, right) = try await (defaultLane, discoveryLane)
        XCTAssertFalse(left.joined)
        XCTAssertFalse(right.joined)
        let transfers = await counter.value
        XCTAssertEqual(transfers, 2, "Lanes have different timeouts and pools")
    }

    func testCompletedKeyIsReleasedForTheNextRequest() async throws {
        let coalescer = HTTPRequestCoalescer()
        let counter = Counter()
        let key = HTTPRequestCoalescer.Key(method: "GET", url: "https://example.test/c", headers: "")

        let first = try await coalescer.perform(key: key) {
            _ = await counter.increment()
            return makeCoalescedPayload("one")
        }
        XCTAssertFalse(first.joined)

        // A reload must not receive the finished transfer; it starts a new one.
        let second = try await coalescer.perform(key: key) {
            _ = await counter.increment()
            return makeCoalescedPayload("two")
        }
        XCTAssertFalse(second.joined)
        XCTAssertEqual(second.payload.data, Data("two".utf8))
        let transfers = await counter.value
        XCTAssertEqual(transfers, 2)
    }

    func testFailureReachesEveryJoinerAndIsRetryable() async throws {
        let coalescer = HTTPRequestCoalescer()
        let counter = Counter()
        let key = HTTPRequestCoalescer.Key(method: "GET", url: "https://example.test/d", headers: "")

        async let first = coalescer.perform(key: key) {
            _ = await counter.increment()
            try? await Task.sleep(for: .milliseconds(80))
            throw URLError(.timedOut)
        }
        try await Task.sleep(for: .milliseconds(20))
        async let second = coalescer.perform(key: key) {
            _ = await counter.increment()
            return makeCoalescedPayload("never")
        }

        do {
            _ = try await first
            XCTFail("The owner must surface the transport failure")
        } catch {
            XCTAssertTrue(error is URLError)
        }
        do {
            _ = try await second
            XCTFail("The joiner must surface the same failure")
        } catch {
            XCTAssertTrue(error is URLError)
        }

        let retry = try await coalescer.perform(key: key) {
            _ = await counter.increment()
            return makeCoalescedPayload("recovered")
        }
        XCTAssertFalse(retry.joined)
        XCTAssertEqual(retry.payload.data, Data("recovered".utf8))
        let transfers = await counter.value
        XCTAssertEqual(transfers, 2)
    }
}

final class NetworkLedgerTests: XCTestCase {
    func testLineIsContentFreeAndComposable() {
        let line = NetworkLedger.makeLine(
            method: "GET",
            path: "/Users/redacted/Items",
            status: 200,
            milliseconds: 123,
            bytes: 4567,
            coalesced: true,
            route: "continueWatching"
        )
        XCTAssertEqual(
            line,
            "GET path=/Users/redacted/Items status=200 ms=123 bytes=4567 coalesced=1 route=continueWatching"
        )
        XCTAssertFalse(line.contains("Authorization"))
        XCTAssertFalse(line.contains("token"))
    }

    func testQuerySummaryOnlyShowsShapeParameters() {
        let summary = NetworkLedger.querySummary([
            URLQueryItem(name: "ParentId", value: "abc123"),
            URLQueryItem(name: "IncludeItemTypes", value: "Episode"),
            URLQueryItem(name: "Limit", value: "100"),
            URLQueryItem(name: "api_key", value: "secret"),
            URLQueryItem(name: "Ids", value: String(repeating: "f", count: 60))
        ])
        XCTAssertEqual(
            summary,
            "ParentId=abc123,IncludeItemTypes=Episode,Limit=100,Ids=" + String(repeating: "f", count: 28) + "~"
        )
        XCTAssertFalse(summary.contains("secret"))
        XCTAssertFalse(summary.contains("api_key"))
    }

    func testFailureLineCarriesNetworkCode() {
        let line = NetworkLedger.makeLine(
            method: "GET",
            path: "/Users/redacted/Items",
            status: nil,
            milliseconds: 90,
            bytes: 0,
            coalesced: false,
            route: "itemDetail",
            error: -1009
        )
        XCTAssertTrue(line.contains("status=-"))
        XCTAssertTrue(line.contains("error=-1009"))
        XCTAssertTrue(line.contains("coalesced=0"))
    }
}


private func makeCoalescedPayload(_ text: String) -> HTTPRequestCoalescer.Payload {
    HTTPRequestCoalescer.Payload(
        data: Data(text.utf8),
        response: URLResponse(
            url: URL(string: "https://example.test/Items")!,
            mimeType: "application/json",
            expectedContentLength: text.utf8.count,
            textEncodingName: nil
        )
    )
}
