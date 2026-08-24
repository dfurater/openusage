import XCTest
@testable import OpenUsage

extension CodexAccountCloudSyncTests {
    struct Fixture {
        var provider: CodexProvider
        var store: WidgetDataStore
        var cache: ProviderSnapshotCache
        var keychain: CountingCodexCloudKeychain
        var files: FakeFiles
    }

    func historicalUsage() -> ProviderUsageHistory {
        ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2000-01-01", totalTokens: 987_654_321, costUSD: 1234)
            ]),
            modelUsage: nil,
            unknownModelsByDay: [:]
        )
    }

    func makeFixture(
        keychainAuth: String,
        fileAuth: String? = nil,
        fileAuthCandidates: [String: String]? = nil,
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
        let files = FakeFiles(fileAuthCandidates ?? fileAuth.map { ["/fixture-codex/auth.json": $0] } ?? [:])
        let client = http ?? FakeHTTPClient(response: HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data("{}".utf8)
        ))
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(fileAuthCandidates == nil ? ["CODEX_HOME": "/fixture-codex"] : [:]),
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
        return Fixture(provider: provider, store: store, cache: cache, keychain: keychain, files: files)
    }

    func authJSON(
        accessToken: String = "keychain-token",
        refreshToken: String? = nil,
        accountID: String?,
        idToken: String? = nil,
        lastRefresh: String? = nil
    ) throws -> String {
        var tokens: [String: Any] = ["access_token": accessToken]
        if let refreshToken { tokens["refresh_token"] = refreshToken }
        if let accountID { tokens["account_id"] = accountID }
        if let idToken { tokens["id_token"] = idToken }
        var auth: [String: Any] = ["tokens": tokens]
        if let lastRefresh { auth["last_refresh"] = lastRefresh }
        let data = try JSONSerialization.data(withJSONObject: auth)
        return String(decoding: data, as: UTF8.self)
    }

    func makeIDToken(accountID: String) throws -> String {
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

final class CountingCodexCloudKeychain: KeychainAccessing, @unchecked Sendable {
    var value: String?
    var queuedReadValues: [String] = []
    private(set) var readCount = 0

    init(value: String?) {
        self.value = value
    }

    func readGenericPassword(service: String) throws -> String? {
        readCount += 1
        if !queuedReadValues.isEmpty {
            return queuedReadValues.removeFirst()
        }
        return value
    }

    func writeGenericPassword(service: String, value: String) throws {
        self.value = value
    }
}
