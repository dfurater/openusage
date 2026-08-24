import XCTest
@testable import OpenUsage

/// Keychain-mode Codex cannot expose an account during prompt-free launch discovery. Its first
/// successful refresh already owns the selected credential, so cloud history learns the verified
/// account without another keychain read or any cross-account history carry-forward.
@MainActor
final class CodexAccountCloudSyncTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)
    private let authPath = "/fixture-codex/auth.json"

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
            keychainAuth: authJSON(accessToken: "account-a-token", accountID: "ACCOUNT-A"),
            includeHistory: false,
            initialIdentity: "account-a",
            cachedHistory: history
        )
        _ = await fixture.store.refresh(providerID: "codex", force: true)
        XCTAssertEqual(fixture.store.localSnapshots["codex"]?.usageHistory, history)

        fixture.keychain.value = try authJSON(accessToken: "different-account-token", accountID: nil)
        let outcome = await fixture.store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertNil(fixture.provider.lastSuccessfulIdentityKey)
        XCTAssertNil(fixture.cache.producedByIdentityKey(providerID: "codex"))
        XCTAssertNil(fixture.store.localSnapshots["codex"]?.usageHistory)
        let document = fixture.store.localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac")
        XCTAssertNil(document.providers["codex"])
        XCTAssertNil(document.identities?["codex"])
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

    private func historicalUsage() -> ProviderUsageHistory {
        ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2000-01-01", totalTokens: 987_654_321, costUSD: 1234)
            ]),
            modelUsage: nil,
            unknownModelsByDay: [:]
        )
    }

    private struct Fixture {
        var provider: CodexProvider
        var store: WidgetDataStore
        var cache: ProviderSnapshotCache
        var keychain: CountingCodexCloudKeychain
    }

    private func makeFixture(
        keychainAuth: String,
        fileAuth: String? = nil,
        includeHistory: Bool,
        initialIdentity: String? = nil,
        cachedHistory: ProviderUsageHistory? = nil,
        http: (any HTTPClient)? = nil
    ) throws -> Fixture {
        let now = instant
        let timestamp = OpenUsageISO8601.string(from: now)
        let home = includeHistory
            ? try CodexLogFixture.makeHome(files: [
                "sessions/rollout.jsonl": [
                    CodexLogFixture.turnContext(timestamp: timestamp, model: "gpt-5.2"),
                    CodexLogFixture.tokenCount(
                        timestamp: timestamp,
                        last: CodexLogFixture.usage(input: 100, output: 50)
                    )
                ].joined(separator: "\n")
            ])
            : nil
        if let home {
            addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        }
        let keychain = CountingCodexCloudKeychain(value: keychainAuth)
        let files = FakeFiles(fileAuth.map { [authPath: $0] } ?? [:])
        let client = http ?? FakeHTTPClient(response: HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data("{}".utf8)
        ))
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(["CODEX_HOME": "/fixture-codex"]),
                files: files,
                keychain: keychain,
                now: { now }
            ),
            usageClient: CodexUsageClient(http: client),
            logUsageScanner: CodexLogFixture.scanner(home: home),
            now: { now },
            pricing: { TestPricing.bundled }
        )
        let defaults = try makeDefaults()
        let cache = ProviderSnapshotCache(
            userDefaults: defaults,
            storageKey: "codex-cloud-snapshots",
            ttl: 600,
            now: { now }
        )
        if let cachedHistory {
            cache.store(
                ProviderSnapshot(
                    providerID: "codex",
                    displayName: "Codex",
                    lines: [.progress(label: "Session", used: 10, limit: 100, format: .percent)],
                    refreshedAt: now,
                    usageHistory: cachedHistory
                ),
                producedByIdentityKey: initialIdentity
            )
        }
        let store = WidgetDataStore(
            registry: WidgetRegistry.from([provider]),
            providers: [provider],
            cache: cache,
            defaults: defaults,
            providerIdentityKeys: initialIdentity.map { ["codex": $0] } ?? [:]
        )
        return Fixture(provider: provider, store: store, cache: cache, keychain: keychain)
    }

    private func authJSON(
        accessToken: String = "keychain-token",
        accountID: String?,
        idToken: String? = nil
    ) throws -> String {
        var tokens: [String: Any] = ["access_token": accessToken]
        if let accountID { tokens["account_id"] = accountID }
        if let idToken { tokens["id_token"] = idToken }
        let data = try JSONSerialization.data(withJSONObject: ["tokens": tokens])
        return String(decoding: data, as: UTF8.self)
    }

    private func makeIDToken(accountID: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "https://api.openai.com/auth": ["chatgpt_account_id": accountID]
        ])
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "OpenUsageTests.CodexAccountCloudSync.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}

private final class CountingCodexCloudKeychain: KeychainAccessing, @unchecked Sendable {
    var value: String?
    private(set) var readCount = 0

    init(value: String?) {
        self.value = value
    }

    func readGenericPassword(service: String) throws -> String? {
        readCount += 1
        return value
    }

    func writeGenericPassword(service: String, value: String) throws {
        self.value = value
    }
}
