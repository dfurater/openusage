import XCTest
@testable import OpenUsage

final class NousAuthStoreTests: XCTestCase {
    private let futureExpiry = "2099-01-01T00:00:00Z"
    private let pastExpiry = "2020-01-01T00:00:00Z"

    // Cases with associated values are functions, not properties — extract via pattern match.
    private func key(_ credential: NousCredential?) -> String? {
        if case .apiKey(let value) = credential { return value }
        return nil
    }

    private func token(_ credential: NousCredential?) -> String? {
        if case .accessToken(let value) = credential { return value }
        return nil
    }

    private func oauthJSON(token: String = "nous-jwt", expiresAt: String) -> String {
        #"{"access_token":"\#(token)","expires_at":"\#(expiresAt)"}"#
    }

    // MARK: - Precedence

    func testAPIKeyFileWinsOverEnvironmentAndOAuth() {
        let files = FakeFiles([
            NousAuthStore.configPaths[0]: #"{"apiKey":"npk-saved"}"#,
            NousAuthStore.sharedOAuthPath: oauthJSON(token: "nous-jwt", expiresAt: futureExpiry)
        ])
        let store = NousAuthStore(files: files, environment: FakeEnvironment(["NOUS_PORTAL_API_KEY": "npk-env"]))

        XCTAssertEqual(key(store.loadCredential()), "npk-saved")
    }

    func testEnvironmentKeyWinsOverOAuthState() {
        let files = FakeFiles([NousAuthStore.sharedOAuthPath: oauthJSON(expiresAt: futureExpiry)])
        let store = NousAuthStore(files: files, environment: FakeEnvironment(["NOUS_PORTAL_API_KEY": "npk-env"]))

        XCTAssertEqual(key(store.loadCredential()), "npk-env")
    }

    func testSharedOAuthStateBeatsProfileAuthJSON() {
        let files = FakeFiles([
            NousAuthStore.sharedOAuthPath: oauthJSON(token: "shared-token", expiresAt: futureExpiry),
            NousAuthStore.profileOAuthPath: oauthJSON(token: "profile-token", expiresAt: futureExpiry)
        ])

        XCTAssertEqual(token(NousAuthStore(files: files).loadCredential()), "shared-token")
    }

    func testProfileAuthJSONIsReadWhenSharedCopyIsAbsent() {
        let files = FakeFiles([NousAuthStore.profileOAuthPath: oauthJSON(token: "profile-token", expiresAt: futureExpiry)])

        XCTAssertEqual(token(NousAuthStore(files: files).loadCredential()), "profile-token")
    }

    // MARK: - Expiry handling

    func testExpiredAccessTokenIsReportedNotDropped() {
        // An expired token must still surface — as `.expiredAccessToken`, not nil — so refresh can
        // show a clean "start Hermes to renew" state and enablement probing still finds the login.
        let files = FakeFiles([NousAuthStore.sharedOAuthPath: oauthJSON(expiresAt: pastExpiry)])
        let store = NousAuthStore(files: files)

        XCTAssertEqual(store.loadCredential(), .expiredAccessToken)
        XCTAssertTrue(store.hasLocalCredentials())
    }

    func testTokenWithoutExpiresAtIsTreatedAsValid() {
        let files = FakeFiles([NousAuthStore.sharedOAuthPath: #"{"access_token":"nous-jwt"}"#])

        XCTAssertEqual(token(NousAuthStore(files: files).loadCredential()), "nous-jwt")
    }

    // MARK: - Absence

    func testReturnsNilWhenNothingExistsAnywhere() {
        XCTAssertNil(NousAuthStore(files: FakeFiles()).loadCredential())
        XCTAssertFalse(NousAuthStore(files: FakeFiles()).hasLocalCredentials())
    }

    func testUnparsableOAuthFileDoesNotMaskLaterSources() {
        let files = FakeFiles([
            NousAuthStore.sharedOAuthPath: "{not json",
            NousAuthStore.profileOAuthPath: oauthJSON(token: "profile-token", expiresAt: futureExpiry)
        ])

        XCTAssertEqual(token(NousAuthStore(files: files).loadCredential()), "profile-token")
    }

    func testBlankAccessTokenEntryIsSkipped() {
        let files = FakeFiles([NousAuthStore.sharedOAuthPath: oauthJSON(token: "", expiresAt: futureExpiry)])

        XCTAssertNil(NousAuthStore(files: files).loadCredential())
    }

    // MARK: - In-app API key management

    func testSaveAPIKeyWritesTrimmedJSONConfigFile() throws {
        let files = FakeFiles()
        let store = NousAuthStore(files: files)

        try store.saveAPIKey("  npk-new  ")

        XCTAssertEqual(files.files[NousAuthStore.configPaths[0]], #"{"apiKey":"npk-new"}"#)
        XCTAssertEqual(store.currentAPIKey(), "npk-new")
        XCTAssertEqual(store.keyStatus(), .saved)
    }

    func testSavedKeyOverridesEnvironmentKey() throws {
        let files = FakeFiles()
        let store = NousAuthStore(files: files, environment: FakeEnvironment(["NOUS_PORTAL_API_KEY": "npk-env"]))

        try store.saveAPIKey("npk-saved")

        XCTAssertEqual(store.keyStatus(), .overrideActive)
        XCTAssertEqual(store.currentAPIKey(), "npk-saved")

        try store.deleteAPIKey()

        XCTAssertEqual(store.keyStatus(), .fromEnvironment)
    }

    func testKeyStatusReportsAllFourStates() {
        let envKey = ["NOUS_PORTAL_API_KEY": "npk-env"]
        let file = [NousAuthStore.configPaths[0]: #"{"apiKey":"npk-file"}"#]

        XCTAssertEqual(NousAuthStore(files: FakeFiles()).keyStatus(), .notSet)
        XCTAssertEqual(NousAuthStore(files: FakeFiles(), environment: FakeEnvironment(envKey)).keyStatus(), .fromEnvironment)
        XCTAssertEqual(NousAuthStore(files: FakeFiles(file)).keyStatus(), .saved)
        XCTAssertEqual(NousAuthStore(files: FakeFiles(file), environment: FakeEnvironment(envKey)).keyStatus(), .overrideActive)
    }
}
