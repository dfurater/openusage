import Foundation

@MainActor
final class NousProvider: ProviderRuntime {
    let provider = Provider(
        id: "nous",
        displayName: "Nous",
        icon: .providerMark("nous"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://portal.nousresearch.com")
        ]
    )

    let authStore: NousAuthStore
    let usageClient: NousUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: NousAuthStore = NousAuthStore(),
        usageClient: NousUsageClient = NousUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .boundedDollars(id: "nous.monthlyCap", provider: provider, title: "Monthly Cap",
                            metricLabel: "Monthly Cap", limit: 100, limitNoun: "cap")
                .exportingLimit("monthlyCap", unit: "usd"),
            .dollarBalance(id: "nous.balance", provider: provider, title: "Balance",
                           metricLabel: "Balance", valueWord: "left")
                .exportingLimit("balance", kind: .balance, unit: "usd", source: .value(kind: .dollars)),
            .boundedDollars(id: "nous.credits", provider: provider, title: "Credits",
                            metricLabel: "Credits", limit: 100, limitNoun: "monthly credits")
                .exportingLimit("credits", unit: "usd"),
            .values(id: "nous.creditsLeft", provider: provider, title: "Credits Left",
                    metricLabel: "Credits Left", selection: .kind(.dollars), valueWord: "left")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same loader as `refresh()`: an in-app API key, or the OAuth token Hermes keeps on disk.
        await loadOffMainActor { [authStore] in authStore.hasLocalCredentials() }
    }

    func refresh() async -> ProviderSnapshot {
        guard let credential = await loadOffMainActor({ [authStore, now] in authStore.loadCredential(now: now) }) else {
            return ProviderSnapshot.error(provider: provider, error: NousAuthError.notLoggedIn)
        }
        guard case .expiredAccessToken = credential else {
            return await fetchAll(credential: credential)
        }
        // The stored access token's `expires_at` has passed. Deliberately not refreshed here —
        // Nous refresh tokens are single-use with rotation and only the owner process (Hermes)
        // may mint new ones. Surface a clean state instead of risking revoking Hermes's session.
        return ProviderSnapshot.error(provider: provider, error: NousAuthError.tokenExpired)
    }

    /// Fetch both endpoints independently and map from whatever succeeds. Either one failing leaves
    /// the other's rows usable; only a joint 401/403 means the credential itself was rejected.
    private func fetchAll(credential: NousCredential) async -> ProviderSnapshot {
        let token: String
        switch credential {
        case .apiKey(let key): token = key
        case .accessToken(let tokenValue): token = tokenValue
        case .expiredAccessToken: return ProviderSnapshot.error(provider: provider, error: NousAuthError.tokenExpired)
        }

        // Both endpoints are fetched independently and mapped from whatever succeeds. Either one
        // failing leaves the other's rows usable; only a joint 401/403 means the credential itself
        // was rejected.
        var lines: [MetricLine] = []
        var plan: String?

        let state = await load { try await usageClient.fetchBillingState(credential: token) }
        if case .success(let data) = state {
            lines += NousUsageMapper.monthlyCapLine(from: data)
            lines += NousUsageMapper.balanceLine(from: data)
        }

        let subscription = await load { try await usageClient.fetchSubscription(credential: token) }
        if case .success(let data) = subscription {
            let mapped = NousUsageMapper.subscriptionMetrics(from: data)
            plan = mapped.plan
            lines += mapped.lines
        }

        if !lines.isEmpty {
            return ProviderSnapshot.make(provider: provider, plan: plan, lines: lines, refreshedAt: now())
        }

        if state.isAuthFailure && subscription.isAuthFailure {
            return ProviderSnapshot.error(provider: provider, error: NousAuthError.credentialRejected)
        }
        let error = state.failureError ?? subscription.failureError ?? NousUsageError.invalidResponse
        return ProviderSnapshot.error(provider: provider, error: error)
    }

    /// Run one endpoint call and classify the outcome: parsed JSON object on 2xx, an auth failure on
    /// 401/403, or a typed failure for any other non-2xx, transport error, or unparsable body.
    /// The closure parameter is deliberately not `@Sendable`: it runs in the caller's isolation
    /// (matching `OpenRouterProvider.load`), so it may touch MainActor state.
    private func load(_ call: () async throws -> HTTPResponse) async -> EndpointResult {
        do {
            let response = try await call()
            if response.statusCode == 401 || response.statusCode == 403 { return .authFailure }
            guard (200..<300).contains(response.statusCode) else {
                return .failed(.requestFailed(response.statusCode))
            }
            guard let data = ProviderParse.jsonObject(response.body) else {
                return .failed(.invalidResponse)
            }
            return .success(data)
        } catch {
            return .failed(.connectionFailed)
        }
    }
}

extension NousProvider: APIKeyManaging {
    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    func currentAPIKey() -> String? { authStore.currentAPIKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveAPIKey(key) }
    func deleteAPIKey() throws { try authStore.deleteAPIKey() }
}

private enum EndpointResult {
    case success([String: Any])
    case authFailure
    case failed(NousUsageError)

    var isAuthFailure: Bool {
        if case .authFailure = self { return true }
        return false
    }

    var failureError: NousUsageError? {
        if case .failed(let error) = self { return error }
        return nil
    }
}
