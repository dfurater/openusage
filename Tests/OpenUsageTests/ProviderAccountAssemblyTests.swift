import XCTest
@testable import OpenUsage

/// The launch account pass end to end: observer outcomes → account registry records → the per-card
/// identity map consumed by the snapshot cache stamp and the bare-id resolver.
@MainActor
final class ProviderAccountAssemblyTests: XCTestCase {
    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.ProviderAccountAssembly.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testResolvedFamiliesFeedIdentityKeysAndTheRegistry() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                // Claude resolved at the default home; Codex has credentials that name no account.
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1", "emailAddress": "dev@example.com"}}"#,
                "/Users/dev/.codex/auth.json": #"{"tokens": {"access_token": "at-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(observer: observer, accountsStore: store)

        XCTAssertEqual(assembly.identityKeysByCard, ["claude": "acct-1"])
        // The registry recorded the resolved account under the bare id, holding the default badge.
        let record = try XCTUnwrap(store.defaultBadgeHolder(family: "claude"))
        XCTAssertEqual(record.id, "claude")
        XCTAssertEqual(record.label, "dev@example.com")
        XCTAssertEqual(record.sources.map(\.kind), [.defaultHome])
        XCTAssertEqual(assembly.claudeCards.map(\.id), ["claude"])
        XCTAssertEqual(assembly.claudeCards.first?.credential, .defaultHome)
        XCTAssertEqual(assembly.claudeCards.first?.identityKey, "acct-1")
        // An unresolved family claims no account: no record, no identity key.
        XCTAssertNil(store.defaultBadgeHolder(family: "codex"))
    }

    /// A family whose home facts aren't readable this launch (first Finder/Dock launch racing a
    /// slow shell) is left out of the pass entirely: not observed, not reconciled — while a family
    /// whose home override is already in the process environment still resolves.
    func testFamiliesOutsideThePassAreNeitherObservedNorReconciled() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1"}}"#,
                "/Users/dev/.codex/auth.json": #"{"tokens": {"access_token": "at-1", "account_id": "CODEX-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(observer: observer, accountsStore: store, families: ["codex"])

        XCTAssertEqual(assembly.identityKeysByCard, ["codex": "codex-1"])
        XCTAssertNil(store.defaultBadgeHolder(family: "claude"), "an out-of-pass family must not be reconciled")
    }

    func testNothingObservedLeavesRegistryAndKeysEmpty() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(observer: observer, accountsStore: store)

        XCTAssertTrue(assembly.identityKeysByCard.isEmpty)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(defaults.data(forKey: ProviderAccountsStore.storageKey), "no observations, no write")
    }

    private func makeClaudeObserver(_ state: String?) -> DefaultAccountObserver {
        var files: [String: String] = [:]
        if let state { files["/Users/dev/.claude.json"] = state }
        return DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles(files),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
    }

    private func makeDiscovery(
        files: [String: String],
        subdirectories: [String]
    ) -> ClaudeConfigDirDiscovery {
        ClaudeConfigDirDiscovery(
            environment: FakeEnvironment([:]),
            files: FakeFiles(files),
            keychain: ServiceKeychain(),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") },
            listSubdirectories: { url in
                subdirectories
                    .map { URL(fileURLWithPath: $0) }
                    .filter { $0.deletingLastPathComponent().path == url.path }
            }
        )
    }

    private func makeCoworkDiscovery(
        files: [String: String],
        sandboxes: [String],
        timeBudget: TimeInterval = 3
    ) -> ClaudeCoworkDiscovery {
        ClaudeCoworkDiscovery(
            files: FakeFiles(files),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") },
            listSandboxes: { _ in sandboxes.map { URL(fileURLWithPath: $0) } },
            timeBudget: timeBudget
        )
    }

    func testDistinctConfigAccountProducesTwoRecordBoundRuntimes() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let observer = makeClaudeObserver(
            #"{"oauthAccount":{"accountUuid":"PERSONAL","organizationUuid":"ORG-PERSONAL"}}"#
        )
        let config = "/Users/dev/.claude-work"
        let discovery = makeDiscovery(
            files: [
                config + "/.claude.json":
                    #"{"oauthAccount":{"accountUuid":"WORK","organizationUuid":"ORG-WORK","organizationName":"Sunstory"}}"#,
                config + "/.credentials.json":
                    #"{"claudeAiOauth":{"accessToken":"work-token"}}"#,
            ],
            subdirectories: [config]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            claudeDiscovery: discovery
        )

        XCTAssertEqual(assembly.claudeCards.count, 2)
        let personal = try XCTUnwrap(assembly.claudeCards.first { $0.id == "claude" })
        let work = try XCTUnwrap(assembly.claudeCards.first { $0.id != "claude" })
        XCTAssertEqual(personal.credential, .defaultHome)
        XCTAssertEqual(work.credential, .configDir(path: config, keychainLiteral: config))
        XCTAssertEqual(work.identityKey, "work|org-work")
        XCTAssertEqual(work.displayName, "Claude — Sunstory")
        XCTAssertEqual(assembly.identityKeysByCard[work.id], "work|org-work")
    }

    func testDefaultSwapKeepsBareAccountBoundToItsMovedConfigDirectory() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let firstObserver = makeClaudeObserver(
            #"{"oauthAccount":{"accountUuid":"ACCOUNT-A","organizationUuid":"ORG-A"}}"#
        )
        let first = ProviderAccountAssembly.make(observer: firstObserver, accountsStore: store)
        XCTAssertEqual(first.claudeCards.map(\.id), ["claude"])
        store.rename(cardID: "claude", to: "Personal")

        let secondObserver = makeClaudeObserver(
            #"{"oauthAccount":{"accountUuid":"ACCOUNT-B","organizationUuid":"ORG-B"}}"#
        )
        let oldHome = "/Users/dev/.claude-personal"
        let discovery = makeDiscovery(
            files: [
                oldHome + "/.claude.json":
                    #"{"oauthAccount":{"accountUuid":"ACCOUNT-A","organizationUuid":"ORG-A"}}"#,
                oldHome + "/.credentials.json":
                    #"{"claudeAiOauth":{"accessToken":"personal-token"}}"#,
            ],
            subdirectories: [oldHome]
        )

        let swapped = ProviderAccountAssembly.make(
            observer: secondObserver,
            accountsStore: store,
            claudeDiscovery: discovery
        )

        XCTAssertEqual(swapped.claudeCards.count, 2)
        let oldAccount = try XCTUnwrap(swapped.claudeCards.first { $0.id == "claude" })
        let newAccount = try XCTUnwrap(swapped.claudeCards.first { $0.id != "claude" })
        XCTAssertEqual(oldAccount.identityKey, "account-a|org-a")
        XCTAssertEqual(
            oldAccount.credential,
            .configDir(path: oldHome, keychainLiteral: oldHome)
        )
        XCTAssertEqual(newAccount.identityKey, "account-b|org-b")
        XCTAssertEqual(newAccount.credential, .defaultHome)
        XCTAssertEqual(store.defaultBadgeHolder(family: "claude")?.id, newAccount.id)
        XCTAssertEqual(store.resolvedDisplayName(cardID: "claude"), "Personal")
        XCTAssertEqual(swapped.identityKeysByCard["claude"], "account-a|org-a")
        XCTAssertEqual(swapped.identityKeysByCard[newAccount.id], "account-b|org-b")

        let runtimes = ProviderCatalog.make(claudeCards: swapped.claudeCards)
            .compactMap { $0 as? ClaudeProvider }
        let oldRuntime = try XCTUnwrap(runtimes.first { $0.provider.id == "claude" })
        let newRuntime = try XCTUnwrap(runtimes.first { $0.provider.id == newAccount.id })
        XCTAssertEqual(oldRuntime.authStore.scope, .configDir(path: oldHome, keychainLiteral: oldHome))
        XCTAssertEqual(oldRuntime.expectedIdentityKey, "account-a|org-a")
        XCTAssertEqual(newRuntime.authStore.scope, .standard)
        XCTAssertEqual(newRuntime.expectedIdentityKey, "account-b|org-b")
    }

    func testDefaultSwapKeepsBareAccountBoundToItsDesktopOrganization() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let original = makeClaudeObserver(
            #"{"oauthAccount":{"accountUuid":"ACCOUNT-A","organizationUuid":"ORG-A"}}"#
        )
        _ = ProviderAccountAssembly.make(observer: original, accountsStore: store)

        let replacement = makeClaudeObserver(
            #"{"oauthAccount":{"accountUuid":"ACCOUNT-B","organizationUuid":"ORG-B"}}"#
        )
        let oldSandbox = "/Users/dev/cowork/personal/.claude"
        let cowork = makeCoworkDiscovery(
            files: [
                oldSandbox + "/.claude.json":
                    #"{"oauthAccount":{"accountUuid":"ACCOUNT-A","organizationUuid":"ORG-A"}}"#,
            ],
            sandboxes: [oldSandbox]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: replacement,
            accountsStore: store,
            coworkDiscovery: cowork,
            hasDesktopCredentialMaterial: { true }
        )

        let originalCard = try XCTUnwrap(assembly.claudeCards.first { $0.id == "claude" })
        let replacementCard = try XCTUnwrap(assembly.claudeCards.first { $0.id != "claude" })
        XCTAssertEqual(originalCard.credential, .desktop(organization: "org-a"))
        XCTAssertEqual(originalCard.logRoots.map(\.path), [oldSandbox])
        XCTAssertEqual(replacementCard.credential, .defaultHome)
        XCTAssertEqual(replacementCard.coworkRootsOverride, [])
        XCTAssertEqual(store.defaultBadgeHolder(family: "claude")?.id, replacementCard.id)
    }

    func testSharedEmailAccountsBakeDistinctOrganizationAndPersonalNames() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let original = makeClaudeObserver(
            #"{"oauthAccount":{"accountUuid":"WORK-ACCOUNT","emailAddress":"rob@example.com","organizationUuid":"ORG-WORK","organizationName":"SUNSTORY"}}"#
        )
        _ = ProviderAccountAssembly.make(observer: original, accountsStore: store)

        let personalDefault = makeClaudeObserver(
            #"{"oauthAccount":{"accountUuid":"PERSONAL-ACCOUNT","emailAddress":"rob@example.com","organizationUuid":"ORG-PERSONAL","organizationName":"rob@example.com's Organization"}}"#
        )
        let coworkRoot = "/Users/dev/cowork/work/.claude"
        let cowork = makeCoworkDiscovery(
            files: [
                coworkRoot + "/.claude.json":
                    #"{"oauthAccount":{"accountUuid":"WORK-ACCOUNT","emailAddress":"rob@example.com","organizationUuid":"ORG-WORK","organizationName":"SUNSTORY"}}"#,
            ],
            sandboxes: [coworkRoot]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: personalDefault,
            accountsStore: store,
            coworkDiscovery: cowork,
            hasDesktopCredentialMaterial: { true }
        )

        let work = try XCTUnwrap(assembly.claudeCards.first { $0.id == "claude" })
        let personal = try XCTUnwrap(assembly.claudeCards.first { $0.id != "claude" })
        XCTAssertEqual(work.displayName, "Claude — SUNSTORY")
        XCTAssertEqual(personal.displayName, "Claude — Personal")
        XCTAssertEqual(store.resolvedDisplayNamesByCardID[work.id], "Claude — SUNSTORY")
        XCTAssertEqual(store.resolvedDisplayNamesByCardID[personal.id], "Claude — Personal")
    }

    func testSameAccountConfigDirectoryAttachesWithoutDuplicatingItsRuntime() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let observer = makeClaudeObserver(
            #"{"oauthAccount":{"accountUuid":"ACCOUNT-A","organizationUuid":"ORG-A"}}"#
        )
        let sideHome = "/Users/dev/.claude-side"
        let discovery = makeDiscovery(
            files: [
                sideHome + "/.claude.json":
                    #"{"oauthAccount":{"accountUuid":"ACCOUNT-A","organizationUuid":"ORG-A"}}"#,
                sideHome + "/.credentials.json":
                    #"{"claudeAiOauth":{"accessToken":"side-token"}}"#,
            ],
            subdirectories: [sideHome]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            claudeDiscovery: discovery
        )

        let card = try XCTUnwrap(assembly.claudeCards.first)
        XCTAssertEqual(assembly.claudeCards.count, 1)
        XCTAssertEqual(card.credential, .defaultHome)
        XCTAssertEqual(card.additionalLogRoots.map(\.path), [sideHome])
        XCTAssertEqual(Set(store.records[0].sources.map(\.kind)), [.defaultHome, .configDir])
    }

    func testSameUserOrganizationsStaySeparateAndUnidentifiedSandboxIsQuarantined() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let observer = makeClaudeObserver(
            #"{"oauthAccount":{"accountUuid":"SAME-USER","organizationUuid":"ORG-PERSONAL"}}"#
        )
        let personalRoot = "/Users/dev/cowork/personal/.claude"
        let workRoot = "/Users/dev/cowork/work/.claude"
        let unidentifiedRoot = "/Users/dev/cowork/unknown/.claude"
        let cowork = makeCoworkDiscovery(
            files: [
                personalRoot + "/.claude.json":
                    #"{"oauthAccount":{"accountUuid":"SAME-USER","organizationUuid":"ORG-PERSONAL"}}"#,
                workRoot + "/.claude.json":
                    #"{"oauthAccount":{"accountUuid":"SAME-USER","organizationUuid":"ORG-WORK","organizationName":"Work"}}"#,
                unidentifiedRoot + "/.claude.json":
                    #"{"oauthAccount":{"accountUuid":"SAME-USER"}}"#,
            ],
            sandboxes: [personalRoot, workRoot, unidentifiedRoot]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            coworkDiscovery: cowork,
            hasDesktopCredentialMaterial: { true }
        )

        XCTAssertEqual(assembly.claudeCards.count, 2)
        let personal = try XCTUnwrap(assembly.claudeCards.first { $0.id == "claude" })
        let work = try XCTUnwrap(assembly.claudeCards.first { $0.id != "claude" })
        XCTAssertEqual(personal.identityKey, "same-user|org-personal")
        XCTAssertEqual(personal.coworkRootsOverride?.map(\.path), [personalRoot])
        XCTAssertEqual(work.identityKey, "same-user|org-work")
        XCTAssertEqual(work.credential, .desktop(organization: "org-work"))
        XCTAssertEqual(work.logRoots.map(\.path), [workRoot])
        XCTAssertFalse(personal.logRoots.map(\.path).contains(unidentifiedRoot))
        XCTAssertFalse(work.logRoots.map(\.path).contains(unidentifiedRoot))
    }

    func testOrglessDefaultRetainsItsSourceVerifiableIdentityWhenOnlyOneOrganizationExists() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let observer = makeClaudeObserver(
            #"{"oauthAccount":{"accountUuid":"ACCOUNT-A"}}"#
        )
        let sandbox = "/Users/dev/cowork/personal/.claude"
        let cowork = makeCoworkDiscovery(
            files: [
                sandbox + "/.claude.json":
                    #"{"oauthAccount":{"accountUuid":"ACCOUNT-A","organizationUuid":"ORG-A"}}"#,
            ],
            sandboxes: [sandbox]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            coworkDiscovery: cowork,
            hasDesktopCredentialMaterial: { true }
        )

        let card = try XCTUnwrap(assembly.claudeCards.first)
        XCTAssertEqual(assembly.claudeCards.count, 1)
        XCTAssertEqual(card.identityKey, "account-a")
        XCTAssertEqual(card.credential, .defaultHome)
        XCTAssertEqual(assembly.identityKeysByCard["claude"], "account-a")
        XCTAssertNil(card.coworkRootsOverride)
    }

    func testOrglessDefaultIsQuarantinedWhenMultipleOrganizationsExist() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let observer = makeClaudeObserver(
            #"{"oauthAccount":{"accountUuid":"SAME-USER"}}"#
        )
        let personal = "/Users/dev/cowork/personal/.claude"
        let work = "/Users/dev/cowork/work/.claude"
        let cowork = makeCoworkDiscovery(
            files: [
                personal + "/.claude.json":
                    #"{"oauthAccount":{"accountUuid":"SAME-USER","organizationUuid":"ORG-PERSONAL"}}"#,
                work + "/.claude.json":
                    #"{"oauthAccount":{"accountUuid":"SAME-USER","organizationUuid":"ORG-WORK"}}"#,
            ],
            sandboxes: [personal, work]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            coworkDiscovery: cowork,
            hasDesktopCredentialMaterial: { true }
        )

        XCTAssertEqual(assembly.claudeCards.count, 2)
        XCTAssertFalse(assembly.claudeCards.contains { $0.credential == .defaultHome })
        XCTAssertEqual(
            Set(assembly.claudeCards.map(\.identityKey)),
            ["same-user|org-personal", "same-user|org-work"]
        )
        XCTAssertNil(store.defaultBadgeHolder(family: "claude"))
    }

    func testConfigOnlyAccountCreatesNoUnboundPhantomClaudeRuntime() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let config = "/Users/dev/.claude-work"
        let discovery = makeDiscovery(
            files: [
                config + "/.claude.json":
                    #"{"oauthAccount":{"accountUuid":"ACCOUNT-B","organizationUuid":"ORG-B"}}"#,
                config + "/.credentials.json":
                    #"{"claudeAiOauth":{"accessToken":"work-token"}}"#,
            ],
            subdirectories: [config]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: makeClaudeObserver(nil),
            accountsStore: store,
            claudeDiscovery: discovery
        )

        let card = try XCTUnwrap(assembly.claudeCards.first)
        XCTAssertTrue(card.id.hasPrefix("claude@"))
        let runtimes = ProviderCatalog.make(claudeCards: assembly.claudeCards)
            .compactMap { $0 as? ClaudeProvider }
        XCTAssertEqual(runtimes.count, 1)
        XCTAssertEqual(runtimes.first?.provider.id, card.id)
        XCTAssertEqual(runtimes.first?.expectedIdentityKey, "account-b|org-b")
    }

    func testTruncatedCoworkWalkWithMultipleAccountsWithholdsUnverifiedSandboxes() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let observer = makeClaudeObserver(
            #"{"oauthAccount":{"accountUuid":"ACCOUNT-A","organizationUuid":"ORG-A"}}"#
        )
        let config = "/Users/dev/.claude-work"
        let discovery = makeDiscovery(
            files: [
                config + "/.claude.json":
                    #"{"oauthAccount":{"accountUuid":"ACCOUNT-B","organizationUuid":"ORG-B"}}"#,
                config + "/.credentials.json":
                    #"{"claudeAiOauth":{"accessToken":"work-token"}}"#,
            ],
            subdirectories: [config]
        )
        let truncatedCowork = makeCoworkDiscovery(
            files: [:],
            sandboxes: ["/Users/dev/cowork/unknown/.claude"],
            timeBudget: -1
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            claudeDiscovery: discovery,
            coworkDiscovery: truncatedCowork,
            hasDesktopCredentialMaterial: { true }
        )

        let defaultCard = try XCTUnwrap(assembly.claudeCards.first { $0.id == "claude" })
        XCTAssertEqual(defaultCard.coworkRootsOverride, [])
        XCTAssertEqual(assembly.defaultClaudeCoworkRoots, [])
    }

    func testDistinctCoworkAccountWithoutOrganizationNeverBorrowsDefaultSpend() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let observer = makeClaudeObserver(
            #"{"oauthAccount":{"accountUuid":"ACCOUNT-A","organizationUuid":"ORG-A"}}"#
        )
        let sandbox = "/Users/dev/cowork/other/.claude"
        let cowork = makeCoworkDiscovery(
            files: [
                sandbox + "/.claude.json":
                    #"{"oauthAccount":{"accountUuid":"ACCOUNT-B"}}"#,
            ],
            sandboxes: [sandbox]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            coworkDiscovery: cowork,
            hasDesktopCredentialMaterial: { true }
        )

        XCTAssertEqual(assembly.claudeCards.count, 1)
        XCTAssertEqual(assembly.claudeCards.first?.coworkRootsOverride, [])
        XCTAssertEqual(store.records.count, 1)
    }

    func testUnresolvedDefaultLogoutKeepsIndependentlyVerifiedDesktopAndConfigAccounts() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let original = makeClaudeObserver(
            #"{"oauthAccount":{"accountUuid":"ACCOUNT-A","organizationUuid":"ORG-A"}}"#
        )
        _ = ProviderAccountAssembly.make(observer: original, accountsStore: store)

        let loggedOut = makeClaudeObserver(#"{"oauthAccount":null}"#)
        let config = "/Users/dev/.claude-work"
        let discovery = makeDiscovery(
            files: [
                config + "/.claude.json":
                    #"{"oauthAccount":{"accountUuid":"ACCOUNT-B","organizationUuid":"ORG-B"}}"#,
                config + "/.credentials.json":
                    #"{"claudeAiOauth":{"accessToken":"work-token"}}"#,
            ],
            subdirectories: [config]
        )
        let personalSandbox = "/Users/dev/cowork/personal/.claude"
        let cowork = makeCoworkDiscovery(
            files: [
                personalSandbox + "/.claude.json":
                    #"{"oauthAccount":{"accountUuid":"ACCOUNT-A","organizationUuid":"ORG-A"}}"#,
            ],
            sandboxes: [personalSandbox]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: loggedOut,
            accountsStore: store,
            claudeDiscovery: discovery,
            coworkDiscovery: cowork,
            hasDesktopCredentialMaterial: { true }
        )

        XCTAssertEqual(assembly.claudeCards.count, 2)
        XCTAssertEqual(
            assembly.claudeCards.first { $0.id == "claude" }?.credential,
            .desktop(organization: "org-a")
        )
        XCTAssertEqual(
            assembly.claudeCards.first { $0.identityKey == "account-b|org-b" }?.credential,
            .configDir(path: config, keychainLiteral: config)
        )
        XCTAssertFalse(assembly.allowsUnboundClaudeFallback)
        XCTAssertNil(store.defaultBadgeHolder(family: "claude"))
    }

    func testUnresolvedDefaultCanNeverResurrectAnUnboundKnownAccount() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        _ = ProviderAccountAssembly.make(
            observer: makeClaudeObserver(
                #"{"oauthAccount":{"accountUuid":"ACCOUNT-A","organizationUuid":"ORG-A"}}"#
            ),
            accountsStore: store
        )

        let loggedOut = ProviderAccountAssembly.make(
            observer: makeClaudeObserver(#"{"oauthAccount":null}"#),
            accountsStore: store
        )

        XCTAssertTrue(loggedOut.claudeCards.isEmpty)
        XCTAssertFalse(loggedOut.allowsUnboundClaudeFallback)
        XCTAssertNil(store.defaultBadgeHolder(family: "claude"))
        XCTAssertEqual(store.record(for: "claude")?.sources, [])
        let runtimes = ProviderCatalog.make(
            claudeCards: loggedOut.claudeCards,
            allowsUnboundClaudeFallback: loggedOut.allowsUnboundClaudeFallback
        )
        XCTAssertFalse(runtimes.contains { $0 is ClaudeProvider })
        XCTAssertEqual(ProviderAccountsStore(defaults: defaults).record(for: "claude")?.identityKey, "account-a|org-a")
    }

    func testAllKnownAccountsAbsentHideEveryClaudeRuntimeButPreserveTheirRecords() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        _ = ProviderAccountAssembly.make(
            observer: makeClaudeObserver(
                #"{"oauthAccount":{"accountUuid":"ACCOUNT-A","organizationUuid":"ORG-A"}}"#
            ),
            accountsStore: store
        )
        store.rename(cardID: "claude", to: "Personal")

        let absent = ProviderAccountAssembly.make(
            observer: makeClaudeObserver(nil),
            accountsStore: store
        )

        XCTAssertTrue(absent.claudeCards.isEmpty)
        XCTAssertFalse(absent.allowsUnboundClaudeFallback)
        XCTAssertNil(store.defaultBadgeHolder(family: "claude"))
        XCTAssertEqual(store.resolvedDisplayName(cardID: "claude"), "Personal")
        XCTAssertFalse(
            ProviderCatalog.make(
                claudeCards: absent.claudeCards,
                allowsUnboundClaudeFallback: absent.allowsUnboundClaudeFallback
            ).contains { $0 is ClaudeProvider }
        )
    }

    func testNeverIdentifiedClaudeAccountKeepsLegacySpendOnlyFallback() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let assembly = ProviderAccountAssembly.make(
            observer: makeClaudeObserver(#"{"oauthAccount":null}"#),
            accountsStore: store
        )

        XCTAssertTrue(assembly.allowsUnboundClaudeFallback)
        let runtime = try XCTUnwrap(
            ProviderCatalog.make(
                claudeCards: assembly.claudeCards,
                allowsUnboundClaudeFallback: assembly.allowsUnboundClaudeFallback
            ).compactMap { $0 as? ClaudeProvider }.first
        )
        XCTAssertEqual(runtime.provider.id, "claude")
        XCTAssertNil(runtime.expectedIdentityKey)
    }

    func testDesktopLogoutHidesHistoricalAccountsUntilCredentialMaterialReturns() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let observer = makeClaudeObserver(
            #"{"oauthAccount":{"accountUuid":"ACCOUNT-A","organizationUuid":"ORG-A"}}"#
        )
        let sandbox = "/Users/dev/cowork/work/.claude"
        let cowork = makeCoworkDiscovery(
            files: [
                sandbox + "/.claude.json":
                    #"{"oauthAccount":{"accountUuid":"ACCOUNT-B","organizationUuid":"ORG-B"}}"#,
            ],
            sandboxes: [sandbox]
        )

        let signedIn = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            coworkDiscovery: cowork,
            hasDesktopCredentialMaterial: { true }
        )
        let desktopID = try XCTUnwrap(signedIn.claudeCards.first { $0.id != "claude" }?.id)

        let signedOut = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            coworkDiscovery: cowork,
            hasDesktopCredentialMaterial: { false }
        )
        XCTAssertEqual(signedOut.claudeCards.map(\.id), ["claude"])
        XCTAssertNotNil(store.record(for: desktopID))

        let restored = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            coworkDiscovery: cowork,
            hasDesktopCredentialMaterial: { true }
        )
        XCTAssertEqual(restored.claudeCards.first { $0.id != "claude" }?.id, desktopID)
    }

    func testOneDefaultAndThreeDesktopOrganizationsBecomeFourIndependentCards() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let observer = makeClaudeObserver(
            #"{"oauthAccount":{"accountUuid":"SHARED-USER","organizationUuid":"ORG-PERSONAL"}}"#
        )
        let roots = [
            "/Users/dev/cowork/work/.claude",
            "/Users/dev/cowork/client/.claude",
            "/Users/dev/cowork/other/.claude",
        ]
        let cowork = makeCoworkDiscovery(
            files: [
                roots[0] + "/.claude.json":
                    #"{"oauthAccount":{"accountUuid":"SHARED-USER","organizationUuid":"ORG-WORK"}}"#,
                roots[1] + "/.claude.json":
                    #"{"oauthAccount":{"accountUuid":"SHARED-USER","organizationUuid":"ORG-CLIENT"}}"#,
                roots[2] + "/.claude.json":
                    #"{"oauthAccount":{"accountUuid":"OTHER-USER","organizationUuid":"ORG-OTHER"}}"#,
            ],
            sandboxes: roots
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            coworkDiscovery: cowork,
            hasDesktopCredentialMaterial: { true }
        )

        XCTAssertEqual(assembly.claudeCards.count, 4)
        XCTAssertEqual(
            Set(assembly.claudeCards.map(\.identityKey)),
            [
                "shared-user|org-personal",
                "shared-user|org-work",
                "shared-user|org-client",
                "other-user|org-other",
            ]
        )
        XCTAssertEqual(Set(assembly.claudeCards.map(\.id)).count, 4)
        XCTAssertEqual(
            Set(
                ProviderCatalog.make(
                    claudeCards: assembly.claudeCards,
                    allowsUnboundClaudeFallback: assembly.allowsUnboundClaudeFallback
                )
                .compactMap { ($0 as? ClaudeProvider)?.expectedIdentityKey }
            ),
            Set(assembly.claudeCards.map(\.identityKey))
        )
    }
}
