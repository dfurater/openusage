import XCTest
@testable import OpenUsage

@MainActor
final class ProviderAccountsStoreTests: XCTestCase {
    private struct LegacyMirrorRecord: Codable {
        struct Source: Codable {
            enum Kind: String, Codable { case defaultHome }

            var kind: Kind
            var anchor: String?
            var holdsDefaultSource: Bool
        }

        var id: String
        var family: String
        var identityKey: String
        var label: String?
        var sources: [Source]
        var removedTombstone: Bool
    }

    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.ProviderAccounts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func defaultHomeObservation(
        family: String,
        identityKey: String,
        label: String? = nil,
        anchor: String = "/Users/dev/.claude"
    ) -> ProviderAccountsStore.AccountObservation {
        ProviderAccountsStore.AccountObservation(
            family: family,
            identityKey: identityKey,
            label: label,
            sources: [ProviderAccountSource(kind: .defaultHome, anchor: anchor, holdsDefaultSource: true)]
        )
    }

    func testFirstAccountOfAFamilyGetsTheBareID() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())

        let records = store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "a@example.com"),
        ])

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, "claude", "the migration-killing rule: the first account IS the existing card")
        XCTAssertEqual(records[0].identityKey, "acct-a")
        XCTAssertEqual(records[0].label, "a@example.com")
        XCTAssertTrue(records[0].sources.contains(where: \.holdsDefaultSource))
    }

    func testSwappedDefaultMintsAHashIDAndTakesTheBadge() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-a")])

        let records = store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-b")])

        XCTAssertEqual(records.count, 2, "the swapped-out account's record survives")
        let old = records.first { $0.identityKey == "acct-a" }
        let new = records.first { $0.identityKey == "acct-b" }
        XCTAssertEqual(old?.id, "claude", "the original keeps its minted id")
        XCTAssertEqual(new?.id, ProviderAccountID.make(family: "claude", identityKey: "acct-b"))
        XCTAssertEqual(store.defaultBadgeHolder(family: "claude")?.identityKey, "acct-b")
        XCTAssertEqual(old?.sources.contains(where: \.holdsDefaultSource), false, "the badge is exclusive per family")
    }

    func testCodexRuntimePresentationFollowsTheCurrentDefaultAccount() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [
            defaultHomeObservation(family: "codex", identityKey: "account-a", label: "alice@example.com")
        ])
        store.rename(cardID: "codex", to: "Alice's Codex")

        store.reconcile(with: [
            defaultHomeObservation(family: "codex", identityKey: "account-b", label: "bob@example.com")
        ])

        let active = try XCTUnwrap(store.runtimeRecord(for: "codex"))
        XCTAssertEqual(active.identityKey, "account-b")
        XCTAssertNotEqual(active.id, "codex", "the runtime alias must not change permanent account ids")
        XCTAssertEqual(store.record(for: "codex")?.identityKey, "account-a")
        XCTAssertEqual(store.record(for: "codex")?.customLabel, "Alice's Codex")
        XCTAssertEqual(store.derivedDisplayName(cardID: "codex"), "Codex — bob@example.com")
        XCTAssertEqual(store.resolvedDisplayName(cardID: "codex"), "Codex — bob@example.com")
        XCTAssertEqual(store.resolvedDisplayNamesByCardID["codex"], "Codex — bob@example.com")
    }

    func testRenamingCodexRuntimeUpdatesOnlyItsCurrentAccountAndSurvivesSwitchBack() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        store.reconcile(with: [
            defaultHomeObservation(family: "codex", identityKey: "account-a", label: "alice@example.com")
        ])
        store.rename(cardID: "codex", to: "Alice")
        store.reconcile(with: [
            defaultHomeObservation(family: "codex", identityKey: "account-b", label: "bob@example.com")
        ])

        store.rename(cardID: "codex", to: "Bob")

        let accountBID = try XCTUnwrap(store.runtimeRecord(for: "codex")?.id)
        XCTAssertEqual(store.record(for: "codex")?.customLabel, "Alice")
        XCTAssertEqual(store.record(for: accountBID)?.customLabel, "Bob")
        XCTAssertEqual(store.resolvedDisplayName(cardID: "codex"), "Bob")
        XCTAssertEqual(store.resolvedDisplayNamesByCardID["codex"], "Bob")
        XCTAssertEqual(ProviderAccountsStore(defaults: defaults).record(for: accountBID)?.customLabel, "Bob")

        store.reconcile(with: [
            defaultHomeObservation(family: "codex", identityKey: "account-a", label: "alice@example.com")
        ])

        XCTAssertEqual(store.runtimeRecord(for: "codex")?.identityKey, "account-a")
        XCTAssertEqual(store.resolvedDisplayName(cardID: "codex"), "Alice")
        XCTAssertEqual(store.record(for: accountBID)?.customLabel, "Bob")
    }

    func testUnverifiedCodexRuntimeCannotBorrowAPreviousAccountsName() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [
            defaultHomeObservation(family: "codex", identityKey: "account-a", label: "alice@example.com")
        ])
        store.rename(cardID: "codex", to: "Alice")
        store.clearDefaultSource(family: "codex")

        XCTAssertNil(store.runtimeRecord(for: "codex"))
        XCTAssertNil(store.resolvedDisplayName(cardID: "codex"))
        XCTAssertNil(store.resolvedDisplayNamesByCardID["codex"])

        store.rename(cardID: "codex", to: "Another Account")
        XCTAssertEqual(store.record(for: "codex")?.customLabel, "Alice")
    }

    func testClaudeRuntimePresentationKeepsItsPermanentCardAfterDefaultMoves() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "account-a", label: "alice@example.com")
        ])
        store.rename(cardID: "claude", to: "Alice")
        store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "account-b", label: "bob@example.com")
        ])

        XCTAssertEqual(store.runtimeRecord(for: "claude")?.identityKey, "account-a")
        XCTAssertEqual(store.resolvedDisplayName(cardID: "claude"), "Alice")

        store.rename(cardID: "claude", to: "Alice's Claude")
        XCTAssertEqual(store.record(for: "claude")?.customLabel, "Alice's Claude")
        XCTAssertNil(store.defaultBadgeHolder(family: "claude")?.customLabel)
    }

    func testOrganizationAppearingPreservesTheOriginalCardAndCustomName() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "before@example.com"),
        ])
        store.rename(cardID: "claude", to: "My Claude")

        let records = store.reconcile(with: [
            defaultHomeObservation(
                family: "claude",
                identityKey: "acct-a|org-work",
                label: "after@example.com (Work)"
            ),
        ])

        XCTAssertEqual(records.count, 1, "a newly reported organization must not mint a duplicate card")
        XCTAssertEqual(records[0].id, "claude")
        XCTAssertEqual(records[0].identityKey, "acct-a|org-work")
        XCTAssertEqual(records[0].identityAliases, ["acct-a"])
        XCTAssertEqual(records[0].customLabel, "My Claude")
        XCTAssertEqual(store.defaultBadgeHolder(family: "claude")?.id, "claude")

        let reloaded = ProviderAccountsStore(defaults: defaults)
        XCTAssertEqual(reloaded.record(for: "claude")?.identityKey, "acct-a|org-work")
        XCTAssertEqual(reloaded.resolvedDisplayName(cardID: "claude"), "My Claude")
    }

    func testOrganizationDisappearingPreservesTheOriginalCardAndKnownOrganization() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a|org-work"),
        ])
        store.rename(cardID: "claude", to: "Work Account")

        let records = store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a"),
        ])

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, "claude")
        XCTAssertEqual(records[0].identityKey, "acct-a")
        XCTAssertEqual(records[0].identityAliases, ["acct-a|org-work"])
        XCTAssertEqual(records[0].customLabel, "Work Account")

        let reloaded = ProviderAccountsStore(defaults: defaults)
        XCTAssertEqual(reloaded.record(for: "claude")?.identityAliases, ["acct-a|org-work"])
        XCTAssertEqual(reloaded.resolvedDisplayName(cardID: "claude"), "Work Account")
    }

    func testTwoExplicitOrganizationsForTheSameUserRemainDistinct() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a|org-work"),
        ])
        store.rename(cardID: "claude", to: "Work")

        let records = store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a|org-personal"),
        ])

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(store.record(for: "claude")?.identityKey, "acct-a|org-work")
        XCTAssertEqual(store.record(for: "claude")?.customLabel, "Work")
        XCTAssertEqual(
            records.first { $0.identityKey == "acct-a|org-personal" }?.id,
            ProviderAccountID.make(family: "claude", identityKey: "acct-a|org-personal")
        )
    }

    func testOrganizationLessObservationIsQuarantinedWhenMultipleOrganizationsExist() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a|org-work"),
            ProviderAccountsStore.AccountObservation(
                family: "claude",
                identityKey: "acct-a|org-personal",
                label: nil,
                sources: [ProviderAccountSource(kind: .desktop, anchor: nil, holdsDefaultSource: false)]
            ),
        ])
        let original = store.records

        let records = store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a"),
        ])

        XCTAssertEqual(records, original, "an unidentified organization must not claim either account")
        XCTAssertEqual(store.defaultBadgeHolder(family: "claude")?.identityKey, "acct-a|org-work")
    }

    func testMultipleIncomingOrganizationsCannotClaimAnExistingOrganizationLessAccount() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a"),
        ])

        let records = store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a|org-work"),
            ProviderAccountsStore.AccountObservation(
                family: "claude",
                identityKey: "acct-a|org-personal",
                label: nil,
                sources: [ProviderAccountSource(kind: .desktop, anchor: nil, holdsDefaultSource: false)]
            ),
        ])

        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(store.record(for: "claude")?.identityKey, "acct-a")
        XCTAssertNotNil(records.first { $0.identityKey == "acct-a|org-work" })
        XCTAssertNotNil(records.first { $0.identityKey == "acct-a|org-personal" })
    }

    func testRememberedOrganizationPreventsLaterDifferentOrganizationFromTakingTheCard() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a|org-work"),
        ])
        store.rename(cardID: "claude", to: "Work")
        store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a"),
        ])

        let records = store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a|org-personal"),
        ])

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(store.record(for: "claude")?.identityKey, "acct-a")
        XCTAssertEqual(store.record(for: "claude")?.customLabel, "Work")
        XCTAssertEqual(store.record(for: "claude")?.identityAliases, ["acct-a|org-work"])
        XCTAssertNotNil(records.first { $0.identityKey == "acct-a|org-personal" })
    }

    func testUnobservedFamilyIsLeftUntouched() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        store.reconcile(with: [defaultHomeObservation(family: "codex", identityKey: "acct-c")])

        // A launch that could not observe codex (logged out, unreadable identity) reports nothing.
        let records = store.reconcile(with: [])

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(store.defaultBadgeHolder(family: "codex")?.identityKey, "acct-c")
    }

    func testReconcileUpdatesLabelButKeepsItWhenObservationHasNone() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "a@example.com")])

        var records = store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-a")])
        XCTAssertEqual(records[0].label, "a@example.com", "a label-less observation must not erase the known label")

        records = store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "a@new.example.com"),
        ])
        XCTAssertEqual(records[0].label, "a@new.example.com")
    }

    func testTombstonedRecordIsNeverResurrected() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "old")])
        // Simulate a future "Remove Account…" by tombstoning the persisted record directly.
        var records = store.records
        records[0].removedTombstone = true
        defaults.set(try! JSONEncoder().encode(records), forKey: ProviderAccountsStore.storageKey)

        let reloaded = ProviderAccountsStore(defaults: defaults)
        let after = reloaded.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "new"),
        ])

        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].label, "old", "a tombstoned account ignores rescan observations")
        XCTAssertNil(reloaded.defaultBadgeHolder(family: "claude"), "a tombstoned record never answers the badge")
    }

    func testRecordsPersistAcrossInstances() {
        let defaults = makeScratchDefaults()
        ProviderAccountsStore(defaults: defaults).reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "a@example.com"),
            defaultHomeObservation(family: "codex", identityKey: "acct-c", anchor: "/Users/dev/.codex"),
        ])

        let reloaded = ProviderAccountsStore(defaults: defaults)

        XCTAssertEqual(reloaded.records.count, 2)
        XCTAssertEqual(reloaded.defaultBadgeHolder(family: "claude")?.label, "a@example.com")
        XCTAssertEqual(reloaded.defaultBadgeHolder(family: "codex")?.sources.first?.anchor, "/Users/dev/.codex")
    }

    func testUndecodableRegistryStartsFresh() {
        let defaults = makeScratchDefaults()
        defaults.set(Data("not json".utf8), forKey: ProviderAccountsStore.storageKey)

        XCTAssertTrue(ProviderAccountsStore(defaults: defaults).records.isEmpty)
    }

    func testRenamePersistsAndFollowsTheAccountAcrossSourceChanges() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "old@example.com"),
        ])
        store.rename(cardID: "claude", to: "  Personal  ")

        let records = store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-b"),
            ProviderAccountsStore.AccountObservation(
                family: "claude",
                identityKey: "acct-a",
                label: "new@example.com",
                sources: [ProviderAccountSource(
                    kind: .configDir,
                    anchor: "/Users/dev/.claude-personal",
                    holdsDefaultSource: false,
                    keychainLiteral: "~/.claude-personal"
                )]
            ),
        ])

        let original = records.first { $0.id == "claude" }
        XCTAssertEqual(original?.identityKey, "acct-a")
        XCTAssertEqual(original?.sources.map(\.kind), [.configDir])
        XCTAssertEqual(original?.sources.first?.keychainLiteral, "~/.claude-personal")
        XCTAssertEqual(original?.customLabel, "Personal")
        XCTAssertEqual(original?.resolvedDisplayName, "Personal")
        XCTAssertEqual(store.defaultBadgeHolder(family: "claude")?.identityKey, "acct-b")
        XCTAssertEqual(
            ProviderAccountsStore(defaults: defaults).record(for: "claude")?.customLabel,
            "Personal"
        )
    }

    func testBlankRenameRestoresDerivedName() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a"),
        ])

        store.setCustomLabel("Work", for: "claude")
        XCTAssertEqual(store.resolvedDisplayName(cardID: "claude"), "Work")

        store.rename(cardID: "claude", to: "   ")
        XCTAssertNil(store.record(for: "claude")?.customLabel)
        XCTAssertEqual(store.resolvedDisplayName(cardID: "claude"), "Claude")
    }

    func testSingleBareAccountKeepsTheHistoricalClaudeTitle() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [
            defaultHomeObservation(
                family: "claude",
                identityKey: "acct-a|org-a",
                label: "rob@example.com (Sunstory)"
            ),
        ])

        XCTAssertEqual(store.derivedDisplayName(cardID: "claude"), "Claude")
        XCTAssertEqual(store.resolvedDisplayName(cardID: "claude"), "Claude")
    }

    func testMultipleAccountsLabelBareCardAndNormalizePersonalOrganization() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [
            defaultHomeObservation(
                family: "claude",
                identityKey: "acct-work|org-work",
                label: "rob@example.com (SUNSTORY)"
            ),
            ProviderAccountsStore.AccountObservation(
                family: "claude",
                identityKey: "acct-personal|org-personal",
                label: "rob@example.com (rob@example.com's Organization)",
                sources: [ProviderAccountSource(
                    kind: .desktop,
                    anchor: nil,
                    holdsDefaultSource: false
                )]
            ),
        ])

        let personal = try XCTUnwrap(store.records.first { $0.id != "claude" })
        XCTAssertEqual(store.derivedDisplayName(cardID: "claude"), "Claude — SUNSTORY")
        XCTAssertEqual(store.resolvedDisplayName(cardID: "claude"), "Claude — SUNSTORY")
        XCTAssertEqual(store.derivedDisplayName(cardID: personal.id), "Claude — Personal")
        XCTAssertEqual(store.resolvedDisplayNamesByCardID[personal.id], "Claude — Personal")
    }

    func testDuplicateAutomaticNamesGainStableSuffixesWithoutOverridingCustomNames() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [
            defaultHomeObservation(
                family: "claude",
                identityKey: "acct-a|org-a",
                label: "same@example.com (Shared)"
            ),
            ProviderAccountsStore.AccountObservation(
                family: "claude",
                identityKey: "acct-b|org-b",
                label: "same@example.com (Shared)",
                sources: [ProviderAccountSource(
                    kind: .desktop,
                    anchor: nil,
                    holdsDefaultSource: false
                )]
            ),
        ])

        let second = try XCTUnwrap(store.records.first { $0.id != "claude" })
        let firstExpected = "Claude — Shared · \(ProviderAccountID.hash8("acct-a|org-a").prefix(4))"
        let secondExpected = "Claude — Shared · \(ProviderAccountID.hash8("acct-b|org-b").prefix(4))"
        XCTAssertEqual(store.derivedDisplayName(cardID: "claude"), firstExpected)
        XCTAssertEqual(store.derivedDisplayName(cardID: second.id), secondExpected)
        XCTAssertNotEqual(firstExpected, secondExpected)

        store.rename(cardID: "claude", to: "My Custom Name")
        XCTAssertEqual(store.resolvedDisplayName(cardID: "claude"), "My Custom Name")
        XCTAssertEqual(store.resolvedDisplayName(cardID: second.id), "Claude — Shared")
        XCTAssertEqual(store.resolvedDisplayNamesByCardID["claude"], "My Custom Name")
    }

    func testUnknownSourceKindsSurviveDecodeAndReconciliation() throws {
        let defaults = makeScratchDefaults()
        let persisted = #"[{"id":"claude","family":"claude","identityKey":"acct-a","label":"Personal","sources":[{"kind":"futureVault","anchor":"vault-a","holdsDefaultSource":false}],"removedTombstone":false}]"#
        defaults.set(Data(persisted.utf8), forKey: ProviderAccountsStore.storageKey)
        let store = ProviderAccountsStore(defaults: defaults)

        XCTAssertEqual(store.records.count, 1, "a forward source must not wipe the entire registry")
        XCTAssertEqual(store.records[0].sources.first?.kind.rawValue, "futureVault")

        store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a"),
        ])

        let reloaded = ProviderAccountsStore(defaults: defaults)
        XCTAssertEqual(
            Set(reloaded.records[0].sources.map(\.kind.rawValue)),
            ["defaultHome", "futureVault"]
        )
        XCTAssertEqual(reloaded.records[0].sources.last?.anchor, "vault-a")
    }

    func testConfigDirectoryOnlyAccountDoesNotClaimReservedBareID() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let records = store.reconcile(with: [
            ProviderAccountsStore.AccountObservation(
                family: "claude",
                identityKey: "acct-side",
                label: nil,
                sources: [ProviderAccountSource(
                    kind: .configDir,
                    anchor: "/Users/dev/.claude-side",
                    holdsDefaultSource: false
                )]
            ),
        ])

        XCTAssertEqual(records.first?.id, ProviderAccountID.make(family: "claude", identityKey: "acct-side"))
    }

    func testLegacyRegistryMigratesToV2AndRepairsDowngradeMirrorWithoutLosingNames() throws {
        let defaults = makeScratchDefaults()
        let unsafeLegacy = #"[{"id":"claude","family":"claude","identityKey":"acct-a|org-a","label":"a@example.com","customLabel":"Personal","sources":[{"kind":"defaultHome","anchor":"/Users/dev/.claude","holdsDefaultSource":true},{"kind":"configDir","anchor":"/Users/dev/.claude-side","holdsDefaultSource":false,"keychainLiteral":"~/.claude-side"}],"removedTombstone":false},{"id":"claude@12345678","family":"claude","identityKey":"acct-b|org-b","label":"b@example.com","customLabel":"Work","sources":[{"kind":"desktop","anchor":null,"holdsDefaultSource":false}],"removedTombstone":false}]"#
        defaults.set(Data(unsafeLegacy.utf8), forKey: ProviderAccountsStore.legacyStorageKey)

        let migrated = ProviderAccountsStore(defaults: defaults)

        XCTAssertEqual(migrated.records.count, 2)
        XCTAssertEqual(migrated.record(for: "claude")?.customLabel, "Personal")
        XCTAssertEqual(migrated.record(for: "claude@12345678")?.customLabel, "Work")
        XCTAssertNotNil(defaults.data(forKey: ProviderAccountsStore.storageKey))

        let mirrorData = try XCTUnwrap(defaults.data(forKey: ProviderAccountsStore.legacyStorageKey))
        let downgradeRecords = try JSONDecoder().decode([LegacyMirrorRecord].self, from: mirrorData)
        XCTAssertEqual(downgradeRecords.count, 2)
        XCTAssertEqual(downgradeRecords[0].sources.map(\.kind), [.defaultHome])
        XCTAssertTrue(downgradeRecords[1].sources.isEmpty)

        // An old release may rewrite its own mirror; v2 remains authoritative on re-upgrade.
        defaults.set(try JSONEncoder().encode([downgradeRecords[0]]), forKey: ProviderAccountsStore.legacyStorageKey)
        let upgradedAgain = ProviderAccountsStore(defaults: defaults)
        XCTAssertEqual(upgradedAgain.records.count, 2)
        XCTAssertEqual(upgradedAgain.record(for: "claude@12345678")?.customLabel, "Work")
        XCTAssertEqual(upgradedAgain.record(for: "claude@12345678")?.sources.map(\.kind), [.desktop])
    }

    func testClearingDefaultSourcePreservesAccountAndOtherSources() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [
            ProviderAccountsStore.AccountObservation(
                family: "claude",
                identityKey: "acct-a",
                label: "Personal",
                sources: [
                    ProviderAccountSource(kind: .defaultHome, anchor: "/Users/dev/.claude", holdsDefaultSource: true),
                    ProviderAccountSource(kind: .desktop, anchor: nil, holdsDefaultSource: false),
                ]
            ),
        ])
        store.rename(cardID: "claude", to: "Saved Name")

        store.clearDefaultSource(family: "claude")

        XCTAssertNil(store.defaultBadgeHolder(family: "claude"))
        XCTAssertEqual(store.record(for: "claude")?.sources.map(\.kind), [.desktop])
        XCTAssertEqual(store.record(for: "claude")?.customLabel, "Saved Name")
    }

    func testFamilyHelperSplitsCardIDs() {
        XCTAssertEqual(ProviderAccountID.family(of: "claude"), "claude")
        XCTAssertEqual(ProviderAccountID.family(of: "claude@ab12cd34"), "claude")
        XCTAssertEqual(ProviderAccountID.family(of: "cursor"), "cursor")
    }
}
