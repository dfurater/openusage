import XCTest
@testable import OpenUsage

// File-scope, nonisolated helpers: the fake handler runs as a `@Sendable` closure, so it may only
// touch Sendable values — no captures from the @MainActor test class.
private func httpResponse(_ status: Int, _ json: String) -> HTTPResponse {
    HTTPResponse(statusCode: status, headers: [:], body: Data(json.utf8))
}

private let billingStateJSON =
    #"{"balanceUsd": "3.20", "monthlyCap": {"limitUsd": "1000", "spentThisMonthUsd": "42.50"}}"#
private let subscriptionJSON =
    #"{"current": {"tierName": "Plus", "monthlyCredits": "22", "creditsRemaining": "17", "cycleEndsAt": "2099-09-04T10:09:32Z"}}"#

@MainActor
final class NousProviderTests: XCTestCase {
    private func makeProvider(
        _ handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse,
        files: FakeFiles = FakeFiles()
    ) -> NousProvider {
        NousProvider(
            authStore: NousAuthStore(
                files: files,
                environment: FakeEnvironment(["NOUS_PORTAL_API_KEY": "npk-test"])
            ),
            usageClient: NousUsageClient(http: RoutingHTTPClient(handler: handler))
        )
    }

    func testRefreshMapsBothEndpointsIntoSnapshot() async {
        let provider = makeProvider { request in
            if request.url.absoluteString.contains("/api/billing/state") {
                return httpResponse(200, billingStateJSON)
            }
            return httpResponse(200, subscriptionJSON)
        }

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Plus")

        let labels = snapshot.lines.map(\.label)
        XCTAssertEqual(labels, ["Monthly Cap", "Balance", "Credits", "Credits Left"])

        guard case .progress(_, let spent, let cap, .dollars, _, _, _)? = snapshot.line(label: "Monthly Cap") else {
            return XCTFail("missing Monthly Cap meter")
        }
        XCTAssertEqual(spent, 42.50, accuracy: 0.001)
        XCTAssertEqual(cap, 1000, accuracy: 0.001)

        guard case .progress(_, let used, let monthly, .dollars, let resetsAt, _, _)? = snapshot.line(label: "Credits") else {
            return XCTFail("missing Credits meter")
        }
        XCTAssertEqual(used, 5, accuracy: 0.001)
        XCTAssertEqual(monthly, 22, accuracy: 0.001)
        XCTAssertNotNil(resetsAt)
    }

    func testOneEndpointFailingLeavesTheOtherUsable() async {
        let provider = makeProvider { request in
            if request.url.absoluteString.contains("/api/billing/state") {
                return httpResponse(500, "{}")
            }
            return httpResponse(200, subscriptionJSON)
        }

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Credits", "Credits Left"])
    }

    func testJointAuthFailureReportsRejectedCredential() async {
        let provider = makeProvider { _ in httpResponse(401, "{}") }

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.lines.first?.isError, true)
    }

    func testMissingCredentialSurfacesNotLoggedIn() async {
        let provider = NousProvider(
            authStore: NousAuthStore(files: FakeFiles(), environment: FakeEnvironment([:])),
            usageClient: NousUsageClient(http: RoutingHTTPClient(handler: { _ in
                XCTFail("no request should be made without credentials")
                throw NousUsageError.connectionFailed
            }))
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.lines.first?.isError, true)
        if case .badge(_, let text, _, _)? = snapshot.lines.first {
            XCTAssertTrue(text.contains("hermes setup --portal"))
        } else {
            XCTFail("expected an error badge")
        }
    }

    func testExpiredAccessTokenFailsCleanlyWithoutAnyRequest() async {
        // The no-refresh invariant: an expired token never triggers a refresh attempt here — Hermes
        // alone may rotate refresh tokens — and no network call happens at all.
        var expired = FakeFiles()
        expired.files[NousAuthStore.sharedOAuthPath] =
            #"{"access_token":"stale","expires_at":"2020-01-01T00:00:00Z"}"#

        let provider = NousProvider(
            authStore: NousAuthStore(files: expired, environment: FakeEnvironment([:])),
            usageClient: NousUsageClient(http: RoutingHTTPClient(handler: { _ in
                XCTFail("expired token must not reach the network")
                throw NousUsageError.connectionFailed
            }))
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.lines.first?.isError, true)
        if case .badge(_, let text, _, _)? = snapshot.lines.first {
            XCTAssertTrue(text.contains("Hermes"))
        } else {
            XCTFail("expected an error badge")
        }
    }

    func testHasLocalCredentialsMirrorsTheAPISource() async {
        let withKey = NousProvider(authStore: NousAuthStore(
            files: FakeFiles([NousAuthStore.configPaths[0]: #"{"apiKey":"npk"}"#]),
            environment: FakeEnvironment([:])
        ))
        let withoutKey = NousProvider(authStore: NousAuthStore(files: FakeFiles(), environment: FakeEnvironment([:])))

        let keyResult = await withKey.hasLocalCredentials()
        let emptyResult = await withoutKey.hasLocalCredentials()

        XCTAssertTrue(keyResult)
        XCTAssertFalse(emptyResult)
    }

    func testBearerAuthorizationRidesEveryRequest() async {
        // Read the recorded requests back through the routing client instead of mutating captured
        // state inside the @Sendable handler.
        let client = RoutingHTTPClient(handler: { request in
            if request.url.absoluteString.contains("/api/billing/state") {
                return httpResponse(200, billingStateJSON)
            }
            return httpResponse(200, subscriptionJSON)
        })
        let provider = NousProvider(
            authStore: NousAuthStore(
                files: FakeFiles(),
                environment: FakeEnvironment(["NOUS_PORTAL_API_KEY": "npk-test"])
            ),
            usageClient: NousUsageClient(http: client)
        )

        _ = await provider.refresh()

        XCTAssertEqual(client.requests.count, 2)
        for request in client.requests {
            XCTAssertEqual(request.headers["Authorization"], "Bearer npk-test")
            XCTAssertEqual(request.headers["Accept"], "application/json")
        }
    }
}
