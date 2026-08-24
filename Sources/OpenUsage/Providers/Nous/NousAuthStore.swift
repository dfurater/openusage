import Foundation

/// One usable Nous Portal credential found on this machine.
enum NousCredential: Equatable {
    /// A user-supplied Portal API key (Settings card / env var).
    case apiKey(String)
    /// The short-lived OAuth access token Hermes mints and stores.
    case accessToken(String)
    /// An OAuth access token whose `expires_at` has passed. Hermes renews it whenever it runs;
    /// OpenUsage never refreshes on its own (see the no-refresh invariant in `NousAuthStore`).
    case expiredAccessToken
}

enum NousAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case tokenExpired
    case credentialRejected
    case unreadableState
    case saveFailed
    case deleteFailed

    init(_ failure: UserAPIKeyStore.Failure) {
        switch failure {
        case .missingKey: self = .notLoggedIn
        case .saveFailed: self = .saveFailed
        case .deleteFailed: self = .deleteFailed
        }
    }

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "No Nous Portal login found. Run `hermes setup --portal`, or add a Portal API key under Customize ▸ API Key."
        case .tokenExpired:
            return "Nous access token expired. Start Hermes once to renew it, then refresh again."
        case .credentialRejected:
            return "The Nous Portal rejected this credential (HTTP 401/403). Re-login with Hermes or replace the API key."
        case .unreadableState:
            return "Found Nous auth state but couldn't read it."
        case .saveFailed:
            return "Couldn't save the Nous Portal API key."
        case .deleteFailed:
            return "Couldn't remove the saved Nous Portal API key."
        }
    }
}

/// Reads the Nous Portal credentials already on this machine.
///
/// Two sources, checked in order:
/// 1. A user-supplied API key (`~/.config/openusage/nous.json`, then `NOUS_PORTAL_API_KEY`) via the
///    shared `UserAPIKeyStore`, exactly like OpenRouter/Z.ai.
/// 2. The OAuth access token the Hermes Agent keeps for its own Portal session: the cross-profile
///    shared copy first (`~/.hermes/shared/nous_auth.json`), then the active profile's
///    `~/.hermes/auth.json`.
///
/// Invariant: this store NEVER refreshes. Nous refresh tokens are single-use with rotation — an
/// external process refreshing them without persisting the rotated token back revokes Hermes's whole
/// session chain. OpenUsage therefore only ever *reads* the current access token and surfaces a clean
/// expired state for Hermes to heal.
struct NousAuthStore: Sendable {
    static let configPaths = ["~/.config/openusage/nous.json"]
    static let environmentNames = ["NOUS_PORTAL_API_KEY"]
    static let sharedOAuthPath = "~/.hermes/shared/nous_auth.json"
    static let profileOAuthPath = "~/.hermes/auth.json"

    private let store: UserAPIKeyStore
    private let files: TextFileAccessing

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        self.files = files
        self.store = UserAPIKeyStore(
            configPaths: Self.configPaths,
            environmentNames: Self.environmentNames,
            files: files,
            environment: environment,
            makeError: { NousAuthError($0) }
        )
    }

    /// The effective credential, following the precedence above. A single loader shared by
    /// `refresh()` and `hasLocalCredentials()` so enablement probing can't drift from real usage.
    func loadCredential(now: () -> Date = Date.init) -> NousCredential? {
        if let key = store.loadKey() { return .apiKey(key) }
        for path in [Self.sharedOAuthPath, Self.profileOAuthPath] {
            guard let text = try? files.readTextIfPresent(path),
                  let object = ProviderParse.jsonObject(Data(text.utf8)),
                  let token = object["access_token"] as? String, !token.isEmpty else { continue }
            if let expiryText = object["expires_at"] as? String,
               let expiry = OpenUsageISO8601.date(from: expiryText),
               expiry <= now() {
                return .expiredAccessToken
            }
            return .accessToken(token)
        }
        return nil
    }

    /// Cheap, local-only probe for `FirstRunSeeder` / `NewProviderSeeder`: mirrors every source
    /// `loadCredential()` reads (an expired token still proves a Nous login exists on this machine).
    func hasLocalCredentials() -> Bool {
        loadCredential() != nil
    }

    // MARK: - In-app API key management (Customize ▸ Nous ▸ API Key)

    func keyStatus() -> APIKeyStatus { store.keyStatus() }
    func currentAPIKey() -> String? { store.loadKey() }
    func saveAPIKey(_ key: String) throws { try store.saveKey(key) }
    func deleteAPIKey() throws { try store.deleteKey() }
}
