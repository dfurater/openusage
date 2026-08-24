import XCTest
@testable import OpenUsage

/// Keychain-mode Codex cannot expose an account during prompt-free launch discovery. Its first
/// successful refresh already owns the selected credential, so cloud history learns the verified
/// account without another keychain read or any cross-account history carry-forward.
@MainActor
final class CodexAccountCloudSyncTests: XCTestCase {
    let instant = Date(timeIntervalSince1970: 1_800_000_000)

    func testKeychainAccountHistoryBecomesCloudSyncableAfterSuccessfulRefresh() async throws {
        let fixture = try makeFixture(
            keychainAuth: authJSON(accountID: "  KEYCHAIN-ACCOUNT  "),
            includeHistory: true
        )
        XCTAssertEqual(fixture.keychain.readCount, 0, "launch must not add a keychain read")

        let outcome = await fixture.store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertEqual(fixture.keychain.readCount, 1, "only the existing credential refresh may read it")
        XCTAssertEqual(fixture.provider.lastSuccessfulIdentityKey, "keychain-account")
        XCTAssertEqual(fixture.cache.producedByIdentityKey(providerID: "codex"), "keychain-account")
        let document = fixture.store.localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac")
        XCTAssertNotNil(document.providers["codex"])
        XCTAssertEqual(document.identities?["codex"], "keychain-account")
    }

    func testKeychainIdentityFallsBackToVerifiedIDTokenAccountClaim() async throws {
        let idToken = try makeIDToken(accountID: "JWT-ACCOUNT")
        let fixture = try makeFixture(
            keychainAuth: authJSON(accountID: nil, idToken: idToken),
            includeHistory: true
        )

        let outcome = await fixture.store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertEqual(fixture.provider.lastSuccessfulIdentityKey, "jwt-account")
        XCTAssertEqual(
            fixture.store.localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac")
                .identities?["codex"],
            "jwt-account"
        )
        XCTAssertEqual(fixture.keychain.readCount, 1)
    }

    func testKeychainIdentityFallsBackToVerifiedAccessTokenAccountClaim() async throws {
        let accessToken = try makeIDToken(accountID: "ACCESS-TOKEN-ACCOUNT")
        let fixture = try makeFixture(
            keychainAuth: authJSON(accessToken: accessToken, accountID: nil),
            includeHistory: true
        )

        let outcome = await fixture.store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertEqual(fixture.provider.lastSuccessfulIdentityKey, "access-token-account")
        XCTAssertEqual(fixture.cache.producedByIdentityKey(providerID: "codex"), "access-token-account")
        XCTAssertEqual(
            fixture.store.localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac")
                .identities?["codex"],
            "access-token-account"
        )
        XCTAssertEqual(fixture.keychain.readCount, 1)
    }

    func testIdentitylessKeychainCredentialRemainsExcludedFromCloudHistory() async throws {
        let fixture = try makeFixture(
            keychainAuth: authJSON(accountID: nil),
            includeHistory: true
        )

        let outcome = await fixture.store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertNotNil(fixture.store.localSnapshots["codex"]?.usageHistory)
        XCTAssertNil(fixture.provider.lastSuccessfulIdentityKey)
        XCTAssertNil(fixture.cache.producedByIdentityKey(providerID: "codex"))
        let document = fixture.store.localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac")
        XCTAssertNil(document.providers["codex"])
    }

    func testKeychainFallbackPublishesWinningAccountNotRejectedFileAccount() async throws {
        let http = RoutingHTTPClient { request in
            if request.headers["Authorization"] == "Bearer rejected-file-token" {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }
        let fixture = try makeFixture(
            keychainAuth: authJSON(accessToken: "winning-keychain-token", accountID: "ACCOUNT-B"),
            fileAuth: authJSON(accessToken: "rejected-file-token", accountID: "ACCOUNT-A"),
            includeHistory: true,
            http: http
        )

        let outcome = await fixture.store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertEqual(fixture.provider.lastSuccessfulIdentityKey, "account-b")
        XCTAssertEqual(fixture.cache.producedByIdentityKey(providerID: "codex"), "account-b")
        XCTAssertEqual(
            fixture.store.localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac")
                .identities?["codex"],
            "account-b"
        )
        XCTAssertEqual(fixture.keychain.readCount, 1)
    }

    func testFirstIdentitylessFallbackCannotInheritRejectedFileAccount() async throws {
        let history = historicalUsage()
        let http = RoutingHTTPClient { request in
            if request.headers["Authorization"] == "Bearer rejected-file-token" {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }
        let fixture = try makeFixture(
            keychainAuth: authJSON(accessToken: "identityless-keychain-token", accountID: nil),
            fileAuth: authJSON(accessToken: "rejected-file-token", accountID: "ACCOUNT-A"),
            includeHistory: false,
            initialIdentity: "account-a",
            cachedHistory: history,
            http: http
        )
        XCTAssertNotNil(fixture.provider.lastSuccessfulCredentialFingerprint)
        XCTAssertNil(fixture.provider.lastSuccessfulIdentityKey)
        XCTAssertEqual(fixture.keychain.readCount, 0)

        let outcome = await fixture.store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertNil(fixture.provider.lastSuccessfulIdentityKey)
        XCTAssertNil(fixture.cache.producedByIdentityKey(providerID: "codex"))
        XCTAssertNil(fixture.store.localSnapshots["codex"]?.usageHistory)
        XCTAssertNil(
            fixture.store.localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac")
                .providers["codex"]
        )
        XCTAssertEqual(fixture.keychain.readCount, 1)
    }

    func testIdentifiedFileCredentialRetainsLaunchOwnerAfterMetadataDisappears() async throws {
        let history = historicalUsage()
        let fixture = try makeFixture(
            keychainAuth: authJSON(accountID: nil),
            fileAuth: authJSON(accessToken: "launch-file-token", accountID: "ACCOUNT-A"),
            includeHistory: false,
            initialIdentity: "account-a",
            cachedHistory: history
        )
        let initialFingerprint = fixture.provider.lastSuccessfulCredentialFingerprint
        XCTAssertNotNil(initialFingerprint)
        XCTAssertNil(fixture.provider.lastSuccessfulIdentityKey)
        fixture.files.files["/fixture-codex/auth.json"] = try authJSON(
            accessToken: "launch-file-token",
            accountID: nil
        )

        let outcome = await fixture.store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertNil(fixture.provider.lastSuccessfulIdentityKey)
        XCTAssertEqual(fixture.provider.lastSuccessfulCredentialFingerprint, initialFingerprint)
        XCTAssertEqual(fixture.cache.producedByIdentityKey(providerID: "codex"), "account-a")
        XCTAssertEqual(fixture.store.localSnapshots["codex"]?.usageHistory, history)
        XCTAssertEqual(fixture.keychain.readCount, 0)
    }

    func testEarlierIdentitylessFileCannotInheritLaterIdentifiedFileAccount() async throws {
        let history = historicalUsage()
        let fixture = try makeFixture(
            keychainAuth: authJSON(accountID: nil),
            fileAuthCandidates: [
                "~/.config/codex/auth.json": try authJSON(accessToken: "identityless-first", accountID: nil),
                "~/.codex/auth.json": try authJSON(accessToken: "identified-second", accountID: "ACCOUNT-A")
            ],
            includeHistory: false,
            initialIdentity: "account-a",
            cachedHistory: history
        )
        XCTAssertNotNil(fixture.provider.lastSuccessfulCredentialFingerprint)
        XCTAssertNil(fixture.provider.lastSuccessfulIdentityKey)

        let outcome = await fixture.store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertNil(fixture.provider.lastSuccessfulIdentityKey)
        XCTAssertNil(fixture.cache.producedByIdentityKey(providerID: "codex"))
        XCTAssertNil(fixture.store.localSnapshots["codex"]?.usageHistory)
        XCTAssertEqual(fixture.keychain.readCount, 0)
    }

    func testAccountChangeNeverCarriesForwardAnotherAccountsCachedHistory() async throws {
        let oldHistory = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2000-01-01", totalTokens: 987_654_321, costUSD: 1234)
            ]),
            modelUsage: nil,
            unknownModelsByDay: [:]
        )
        let fixture = try makeFixture(
            keychainAuth: authJSON(accountID: "ACCOUNT-B"),
            includeHistory: false,
            initialIdentity: "account-a",
            cachedHistory: oldHistory
        )
        XCTAssertEqual(
            fixture.store.localSnapshots["codex"]?.usageHistory?.series.daily.first?.totalTokens,
            987_654_321
        )

        let outcome = await fixture.store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertEqual(fixture.cache.producedByIdentityKey(providerID: "codex"), "account-b")
        let carriedOldHistory = fixture.store.localSnapshots["codex"]?.usageHistory?.series.daily
            .contains { $0.totalTokens == 987_654_321 } ?? false
        XCTAssertFalse(carriedOldHistory)
    }

    func testAccessTokenAccountClaimSwitchNeverCarriesForwardPreviousHistory() async throws {
        let history = historicalUsage()
        let accessToken = try makeIDToken(accountID: "ACCOUNT-B")
        let fixture = try makeFixture(
            keychainAuth: authJSON(accessToken: accessToken, accountID: nil),
            includeHistory: false,
            initialIdentity: "account-a",
            cachedHistory: history
        )

        let outcome = await fixture.store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertEqual(fixture.provider.lastSuccessfulIdentityKey, "account-b")
        XCTAssertEqual(fixture.cache.producedByIdentityKey(providerID: "codex"), "account-b")
        XCTAssertNil(fixture.store.localSnapshots["codex"]?.usageHistory)
    }

    func testSameCredentialLosingItsIdentityPreservesVerifiedCloudHistory() async throws {
        let history = historicalUsage()
        let fixture = try makeFixture(
            keychainAuth: authJSON(accountID: "ACCOUNT-A"),
            includeHistory: false,
            initialIdentity: "account-a",
            cachedHistory: history
        )
        _ = await fixture.store.refresh(providerID: "codex", force: true)
        XCTAssertEqual(fixture.cache.producedByIdentityKey(providerID: "codex"), "account-a")
        XCTAssertEqual(fixture.store.localSnapshots["codex"]?.usageHistory, history)

        fixture.keychain.value = try authJSON(accountID: nil)
        let outcome = await fixture.store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertNil(fixture.provider.lastSuccessfulIdentityKey)
        XCTAssertEqual(fixture.cache.producedByIdentityKey(providerID: "codex"), "account-a")
        XCTAssertEqual(fixture.store.localSnapshots["codex"]?.usageHistory, history)
        let document = fixture.store.localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac")
        XCTAssertEqual(document.providers["codex"], history)
        XCTAssertEqual(document.identities?["codex"], "account-a")
    }

    func testDifferentIdentitylessCredentialQuarantinesPreviousAccountHistory() async throws {
        let history = historicalUsage()
        let fixture = try makeFixture(
            keychainAuth: authJSON(
                accessToken: "account-a-token",
                refreshToken: "account-a-refresh",
                accountID: "ACCOUNT-A"
            ),
            includeHistory: false,
            initialIdentity: "account-a",
            cachedHistory: history
        )
        _ = await fixture.store.refresh(providerID: "codex", force: true)
        XCTAssertEqual(fixture.store.localSnapshots["codex"]?.usageHistory, history)

        fixture.keychain.value = try authJSON(
            accessToken: "different-account-token",
            refreshToken: "different-account-refresh",
            accountID: nil
        )
        let outcome = await fixture.store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertNil(fixture.provider.lastSuccessfulIdentityKey)
        XCTAssertNil(fixture.cache.producedByIdentityKey(providerID: "codex"))
        XCTAssertNil(fixture.store.localSnapshots["codex"]?.usageHistory)
        let document = fixture.store.localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac")
        XCTAssertNil(document.providers["codex"])
        XCTAssertNil(document.identities?["codex"])
    }

    func testRotatedAccessTokenPreservesHistoryWhenRefreshTokenMatches() async throws {
        let history = historicalUsage()
        let fixture = try makeFixture(
            keychainAuth: authJSON(
                accessToken: "original-access",
                refreshToken: "stable-refresh",
                accountID: "ACCOUNT-A"
            ),
            includeHistory: false,
            initialIdentity: "account-a",
            cachedHistory: history
        )
        _ = await fixture.store.refresh(providerID: "codex", force: true)
        let initialFingerprint = fixture.provider.lastSuccessfulCredentialFingerprint

        fixture.keychain.value = try authJSON(
            accessToken: "rotated-access",
            refreshToken: "stable-refresh",
            accountID: nil
        )
        let outcome = await fixture.store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertNil(fixture.provider.lastSuccessfulIdentityKey)
        XCTAssertEqual(fixture.provider.lastSuccessfulCredentialFingerprint, initialFingerprint)
        XCTAssertEqual(fixture.cache.producedByIdentityKey(providerID: "codex"), "account-a")
        XCTAssertEqual(fixture.store.localSnapshots["codex"]?.usageHistory, history)
        XCTAssertEqual(
            fixture.store.localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac")
                .identities?["codex"],
            "account-a"
        )
        XCTAssertEqual(fixture.keychain.readCount, 2)
    }

    func testProviderOAuthRefreshRotatingBothTokensPreservesAccountHistory() async throws {
        let history = historicalUsage()
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.refreshURL {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"access_token":"rotated-access","refresh_token":"rotated-refresh"}"#.utf8)
                )
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }
        let fixture = try makeFixture(
            keychainAuth: authJSON(
                accessToken: "original-access",
                refreshToken: "original-refresh",
                accountID: "ACCOUNT-A"
            ),
            includeHistory: false,
            initialIdentity: "account-a",
            cachedHistory: history,
            http: http
        )
        _ = await fixture.store.refresh(providerID: "codex", force: true)
        let initialFingerprint = fixture.provider.lastSuccessfulCredentialFingerprint

        fixture.keychain.value = try authJSON(
            accessToken: "original-access",
            refreshToken: "original-refresh",
            accountID: nil,
            lastRefresh: OpenUsageISO8601.string(from: instant.addingTimeInterval(-9 * 24 * 60 * 60))
        )
        let outcome = await fixture.store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertTrue(http.requests.contains { $0.url == CodexUsageClient.refreshURL })
        XCTAssertNil(fixture.provider.lastSuccessfulIdentityKey)
        XCTAssertEqual(fixture.provider.lastSuccessfulCredentialFingerprint, initialFingerprint)
        XCTAssertEqual(fixture.cache.producedByIdentityKey(providerID: "codex"), "account-a")
        XCTAssertEqual(fixture.store.localSnapshots["codex"]?.usageHistory, history)
    }

    func testUnauthorizedRetryRotatingBothTokensPreservesAccountHistory() async throws {
        let history = historicalUsage()
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.refreshURL {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"access_token":"retried-access","refresh_token":"retried-refresh"}"#.utf8)
                )
            }
            if request.url == CodexUsageClient.usageURL,
               request.headers["Authorization"] == "Bearer rejected-access"
            {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }
        let fixture = try makeFixture(
            keychainAuth: authJSON(
                accessToken: "original-access",
                refreshToken: "original-refresh",
                accountID: "ACCOUNT-A"
            ),
            includeHistory: false,
            initialIdentity: "account-a",
            cachedHistory: history,
            http: http
        )
        _ = await fixture.store.refresh(providerID: "codex", force: true)
        let initialFingerprint = fixture.provider.lastSuccessfulCredentialFingerprint

        fixture.keychain.value = try authJSON(
            accessToken: "rejected-access",
            refreshToken: "original-refresh",
            accountID: nil
        )
        let outcome = await fixture.store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertTrue(http.requests.contains { $0.url == CodexUsageClient.refreshURL })
        XCTAssertNil(fixture.provider.lastSuccessfulIdentityKey)
        XCTAssertEqual(fixture.provider.lastSuccessfulCredentialFingerprint, initialFingerprint)
        XCTAssertEqual(fixture.cache.producedByIdentityKey(providerID: "codex"), "account-a")
        XCTAssertEqual(fixture.store.localSnapshots["codex"]?.usageHistory, history)
    }

    func testReloadedUnrelatedIdentitylessCredentialBreaksTrustedLineage() async throws {
        let history = historicalUsage()
        let fixture = try makeFixture(
            keychainAuth: authJSON(
                accessToken: "account-a-access",
                refreshToken: "account-a-refresh",
                accountID: "ACCOUNT-A"
            ),
            includeHistory: false,
            initialIdentity: "account-a",
            cachedHistory: history
        )
        _ = await fixture.store.refresh(providerID: "codex", force: true)

        let replacedCredential = try authJSON(
            accessToken: "different-account-access",
            refreshToken: "different-account-refresh",
            accountID: nil
        )
        fixture.keychain.value = replacedCredential
        fixture.keychain.queuedReadValues = [
            try authJSON(
                accessToken: "account-a-access",
                refreshToken: "account-a-refresh",
                accountID: nil,
                lastRefresh: OpenUsageISO8601.string(from: instant.addingTimeInterval(-9 * 24 * 60 * 60))
            ),
            replacedCredential
        ]

        let outcome = await fixture.store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertNil(fixture.provider.lastSuccessfulIdentityKey)
        XCTAssertNil(fixture.cache.producedByIdentityKey(providerID: "codex"))
        XCTAssertNil(fixture.store.localSnapshots["codex"]?.usageHistory)
        XCTAssertNil(
            fixture.store.localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac")
                .providers["codex"]
        )
    }

    func testLaunchVerifiedIdentitySurvivesFirstCredentialMetadataMiss() async throws {
        let history = historicalUsage()
        let fixture = try makeFixture(
            keychainAuth: authJSON(accountID: nil),
            includeHistory: false,
            initialIdentity: "launch-account",
            cachedHistory: history
        )
        XCTAssertNil(fixture.provider.lastSuccessfulCredentialFingerprint)

        let outcome = await fixture.store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertNil(fixture.provider.lastSuccessfulIdentityKey)
        XCTAssertNotNil(fixture.provider.lastSuccessfulCredentialFingerprint)
        XCTAssertEqual(fixture.cache.producedByIdentityKey(providerID: "codex"), "launch-account")
        XCTAssertEqual(fixture.store.localSnapshots["codex"]?.usageHistory, history)
        let document = fixture.store.localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac")
        XCTAssertEqual(document.providers["codex"], history)
        XCTAssertEqual(document.identities?["codex"], "launch-account")
    }
}
