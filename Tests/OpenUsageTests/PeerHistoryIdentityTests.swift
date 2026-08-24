import XCTest
@testable import OpenUsage

/// Identity-keyed iCloud matching: the same account merges into the same card across Macs regardless
/// of which machine calls it the default and which shows it as an extra account card, and accounts
/// with no local card surface as remote-only Total Spend entries.
@MainActor
final class PeerHistoryIdentityTests: XCTestCase {
    private let teamKey = "uuid-me|org-team"
    private let maxKey = "uuid-me|org-max"

    func testDocumentV2AllowsAccountCardsAndV1StaysStrict() throws {
        var v2 = makeDocument(providers: [
            "claude": history(day: "2026-07-16", tokens: 10, cost: 1),
            "claude@ab12cd34": history(day: "2026-07-16", tokens: 20, cost: 2),
        ], identities: ["claude": maxKey, "claude@ab12cd34": teamKey])
        XCTAssertNoThrow(try v2.validate())

        v2.schema = UsageHistoryDocument.legacySchemaV1
        XCTAssertThrowsError(try v2.validate()) // account-card ids are a v2 concept

        let v1 = UsageHistoryDocument(
            schema: UsageHistoryDocument.legacySchemaV1,
            deviceID: "d", deviceName: "n", updatedAt: Date(),
            providers: ["claude": history(day: "2026-07-16", tokens: 10, cost: 1)],
            identities: nil
        )
        XCTAssertNoThrow(try v1.validate())
    }

    func testRemapMatchesAccountsAcrossDefaultAndExtraCardRoles() {
        // The mini↔MacBook case: mini's DEFAULT card is the Team account (claude), its extra card is
        // Max. This Mac is the mirror image (default = Max, extra = Team). Every peer history must
        // land on the LOCAL card with the same account.
        let miniDoc = makeDocument(
            deviceName: "Mac mini",
            providers: [
                "claude": history(day: "2026-07-16", tokens: 100, cost: 502.34),
                "claude@b2d3867d": history(day: "2026-07-16", tokens: 90, cost: 494.27),
            ],
            identities: ["claude": teamKey, "claude@b2d3867d": maxKey]
        )
        let localMap = ["claude": maxKey, "claude@f15456b0": teamKey]

        let remapped = PeerHistoryRemapper.remap(documents: [miniDoc], localIdentityByCardID: localMap)

        XCTAssertTrue(remapped.remoteOnly.isEmpty)
        let byCard = Dictionary(grouping: remapped.histories, by: { $0.cardID })
        XCTAssertEqual(byCard["claude"]?.first?.history.series.daily.first?.costUSD, 494.27, "mini's Max spend belongs to this Mac's default (Max) card")
        XCTAssertEqual(byCard["claude@f15456b0"]?.first?.history.series.daily.first?.costUSD, 502.34, "mini's Team spend belongs to this Mac's Team card")
    }

    func testRemapCollectsRemoteOnlyAccounts() {
        let doc = makeDocument(
            deviceName: "Mac mini",
            providers: ["claude@ab12cd34": history(day: "2026-07-16", tokens: 50, cost: 42)],
            identities: ["claude@ab12cd34": "uuid-other|org-x"]
        )
        let remapped = PeerHistoryRemapper.remap(
            documents: [doc],
            localIdentityByCardID: ["claude": maxKey]
        )
        XCTAssertTrue(remapped.histories.isEmpty)
        XCTAssertEqual(remapped.remoteOnly.count, 1)
        XCTAssertEqual(remapped.remoteOnly.first?.family, "claude")
        XCTAssertEqual(
            remapped.remoteOnly.first?.cardID,
            ProviderAccountID.make(family: "claude", identityKey: "uuid-other|org-x"),
            "the slice uses a stable identity-derived code even when a Mac retained a bare card id"
        )
    }

    func testUnresolvedLocalIdentityQuarantinesPeerHistoryInsteadOfGuessing() {
        // A matching bare card id says nothing about the login: each Mac independently assigned
        // that id to its first account. Without a verified local identity, neither a local merge
        // nor a remote-only slice is safe.
        let doc = makeDocument(
            deviceName: "Mac mini",
            providers: ["claude": history(day: "2026-07-16", tokens: 10, cost: 1)],
            identities: ["claude": teamKey]
        )
        let remapped = PeerHistoryRemapper.remap(documents: [doc], localIdentityByCardID: [:])

        XCTAssertTrue(remapped.histories.isEmpty)
        XCTAssertTrue(remapped.remoteOnly.isEmpty)
        XCTAssertEqual(remapped.quarantined.map(\.reason), [.unresolvedLocalIdentity])
    }

    func testRemapLegacyV1AccountHistoryIsQuarantined() {
        let v1 = UsageHistoryDocument(
            schema: UsageHistoryDocument.legacySchemaV1,
            deviceID: "d", deviceName: "old Mac", updatedAt: Date(),
            providers: ["claude": history(day: "2026-07-16", tokens: 10, cost: 1)],
            identities: nil
        )
        let remapped = PeerHistoryRemapper.remap(
            documents: [v1],
            localIdentityByCardID: ["claude": maxKey]
        )
        XCTAssertTrue(remapped.histories.isEmpty)
        XCTAssertTrue(remapped.remoteOnly.isEmpty)
        XCTAssertEqual(remapped.quarantined.map(\.reason), [.missingPeerIdentity])
    }

    func testRemapLegacyV1NonAccountHistoryStillMerges() {
        let v1 = UsageHistoryDocument(
            schema: UsageHistoryDocument.legacySchemaV1,
            deviceID: "d", deviceName: "old Mac", updatedAt: Date(),
            providers: ["grok": history(day: "2026-07-16", tokens: 10, cost: 1)],
            identities: nil
        )

        let remapped = PeerHistoryRemapper.remap(documents: [v1], localIdentityByCardID: [:])

        XCTAssertEqual(remapped.histories.map(\.cardID), ["grok"])
        XCTAssertTrue(remapped.quarantined.isEmpty)
    }

    func testDuplicateLocalIdentityQuarantinesInsteadOfChoosingBareCard() {
        let doc = makeDocument(
            providers: ["claude": history(day: "2026-07-16", tokens: 10, cost: 1)],
            identities: ["claude": teamKey]
        )

        let remapped = PeerHistoryRemapper.remap(
            documents: [doc],
            localIdentityByCardID: ["claude": teamKey, "claude@ab12cd34": teamKey]
        )

        XCTAssertTrue(remapped.histories.isEmpty)
        XCTAssertTrue(remapped.remoteOnly.isEmpty)
        XCTAssertEqual(remapped.quarantined.map(\.reason), [.ambiguousLocalIdentity])
    }

    func testDuplicatePeerIdentityIsQuarantinedWithoutDoubleCounting() {
        let doc = makeDocument(
            providers: [
                "claude": history(day: "2026-07-16", tokens: 10, cost: 1),
                "claude@ab12cd34": history(day: "2026-07-16", tokens: 20, cost: 2),
            ],
            identities: ["claude": teamKey, "claude@ab12cd34": teamKey]
        )

        let remapped = PeerHistoryRemapper.remap(
            documents: [doc],
            localIdentityByCardID: ["claude": teamKey]
        )

        XCTAssertTrue(remapped.histories.isEmpty)
        XCTAssertTrue(remapped.remoteOnly.isEmpty)
        XCTAssertEqual(remapped.quarantined.map(\.reason), [.ambiguousPeerIdentity, .ambiguousPeerIdentity])
    }

    func testEqualIdentityStringsNeverCrossProviderFamilies() {
        let sharedIdentity = "shared-account-id"
        let doc = makeDocument(
            providers: ["codex": history(day: "2026-07-16", tokens: 10, cost: 1)],
            identities: ["codex": sharedIdentity]
        )

        let remapped = PeerHistoryRemapper.remap(
            documents: [doc],
            localIdentityByCardID: ["claude": sharedIdentity]
        )

        XCTAssertTrue(remapped.histories.isEmpty)
        XCTAssertTrue(remapped.remoteOnly.isEmpty)
        XCTAssertEqual(remapped.quarantined.map(\.reason), [.unresolvedLocalIdentity])
    }

    func testUnresolvedSiblingPreventsUnsafeRemoteOnlySlice() {
        let doc = makeDocument(
            providers: ["claude": history(day: "2026-07-16", tokens: 10, cost: 1)],
            identities: ["claude": teamKey]
        )

        let remapped = PeerHistoryRemapper.remap(
            documents: [doc],
            localIdentityByCardID: ["claude": maxKey],
            localAccountCardIDs: ["claude", "claude@ab12cd34"]
        )

        XCTAssertTrue(remapped.histories.isEmpty)
        XCTAssertTrue(remapped.remoteOnly.isEmpty)
        XCTAssertEqual(remapped.quarantined.map(\.reason), [.unresolvedLocalIdentity])
    }

    func testLocalDocumentPublishesAccountCardsWithIdentities() {
        let registry = makeRegistry()
        // Preload the cache; the store's init adopts cached snapshots as its local set. The entries
        // carry the same account stamp the store is launched with, or the swap guard discards them.
        let cache = scratchCache()
        cache.store(
            snapshot(providerID: "claude", history: history(day: "2026-07-16", tokens: 10, cost: 1)),
            producedByIdentityKey: maxKey
        )
        cache.store(
            snapshot(providerID: "claude@f15456b0", history: history(day: "2026-07-16", tokens: 20, cost: 2)),
            producedByIdentityKey: teamKey
        )
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: [],
            cache: cache,
            defaults: makeScratchDefaults("PublishDoc"),
            providerIdentityKeys: ["claude": maxKey, "claude@f15456b0": teamKey]
        )

        let document = dataStore.localHistoryDocument(deviceID: "dev", deviceName: "This Mac")
        XCTAssertEqual(document.schema, UsageHistoryDocument.currentSchema)
        XCTAssertNotNil(document.providers["claude@f15456b0"], "account cards sync now")
        XCTAssertEqual(document.identities?["claude"], maxKey)
        XCTAssertEqual(document.identities?["claude@f15456b0"], teamKey)
        XCTAssertNoThrow(try document.validate())
    }

    func testRemoteOnlyAccountFeedsTotalSpend() {
        let registry = makeRegistry()
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: [],
            cache: scratchCache(),
            defaults: makeScratchDefaults("RemoteTotal"),
            providerIdentityKeys: ["claude": maxKey, "claude@f15456b0": teamKey]
        )
        let today = dayKey(Date())
        let doc = makeDocument(
            deviceName: "Mac mini",
            providers: ["claude@ab12cd34": history(day: today, tokens: 1_000_000, cost: 42)],
            identities: ["claude@ab12cd34": "uuid-other|org-x"]
        )
        dataStore.setPeerHistoryDocuments([doc], ownDeviceID: "this-mac")

        XCTAssertEqual(dataStore.remoteOnlySpend.count, 1)
        let entry = dataStore.remoteOnlySpend[0]
        let expectedCardID = ProviderAccountID.make(family: "claude", identityKey: "uuid-other|org-x")
        XCTAssertEqual(entry.provider.displayName, expectedCardID, "the slice is named by the account code alone — the source Mac is irrelevant")

        let total = TotalSpendAggregator.total(
            for: .today,
            providers: [entry.provider],
            snapshots: [entry.provider.id: entry.snapshot]
        )
        XCTAssertEqual(total.slices.count, 1)
        XCTAssertEqual(total.slices[0].amountUSD, 42, accuracy: 0.001)
    }

    func testDisabledFamilyNeverIncludesRemoteOnlySpend() {
        let dataStore = WidgetDataStore(
            registry: makeRegistry(),
            providers: [],
            cache: scratchCache(),
            defaults: makeScratchDefaults("DisabledRemote"),
            isProviderEnabled: { _ in false },
            providerIdentityKeys: ["claude": maxKey, "claude@f15456b0": teamKey]
        )
        let doc = makeDocument(
            providers: ["claude@ab12cd34": history(day: dayKey(Date()), tokens: 10, cost: 1)],
            identities: ["claude@ab12cd34": "uuid-other|org-x"]
        )

        dataStore.setPeerHistoryDocuments([doc], ownDeviceID: "this-mac")

        XCTAssertTrue(dataStore.remoteOnlySpend.isEmpty)
    }

    func testRemoteOnlySpendWorksWhenNoBareFamilyCardExists() {
        let dataStore = WidgetDataStore(
            registry: makeRegistry(includeDefault: false),
            providers: [],
            cache: scratchCache(),
            defaults: makeScratchDefaults("RemoteWithoutBareCard"),
            providerIdentityKeys: ["claude@f15456b0": teamKey]
        )
        let doc = makeDocument(
            providers: ["claude@ab12cd34": history(day: dayKey(Date()), tokens: 10, cost: 1)],
            identities: ["claude@ab12cd34": "uuid-other|org-x"]
        )

        dataStore.setPeerHistoryDocuments([doc], ownDeviceID: "this-mac")

        XCTAssertEqual(dataStore.remoteOnlySpend.count, 1)
        XCTAssertEqual(dataStore.remoteOnlySpend.first?.provider.icon, .providerMark("claude"))
    }

    func testRemoteOnlySpendUsesEnabledExtraWhenBareCardIsDisabled() {
        let dataStore = WidgetDataStore(
            registry: makeRegistry(),
            providers: [],
            cache: scratchCache(),
            defaults: makeScratchDefaults("RemoteWithDisabledBareCard"),
            isProviderEnabled: { $0 != "claude" },
            providerIdentityKeys: ["claude": maxKey, "claude@f15456b0": teamKey]
        )
        let doc = makeDocument(
            providers: ["claude@ab12cd34": history(day: dayKey(Date()), tokens: 10, cost: 1)],
            identities: ["claude@ab12cd34": "uuid-other|org-x"]
        )

        dataStore.setPeerHistoryDocuments([doc], ownDeviceID: "this-mac")

        XCTAssertEqual(dataStore.remoteOnlySpend.count, 1)
    }

    func testUnresolvedLocalAccountHistoryIsNotPublished() {
        let cache = scratchCache()
        cache.store(snapshot(
            providerID: "claude",
            history: history(day: "2026-07-16", tokens: 10, cost: 1)
        ))
        let dataStore = WidgetDataStore(
            registry: makeRegistry(),
            providers: [],
            cache: cache,
            defaults: makeScratchDefaults("UnresolvedPublish")
        )

        let document = dataStore.localHistoryDocument(deviceID: "dev", deviceName: "This Mac")

        XCTAssertNil(document.providers["claude"])
        XCTAssertNil(document.identities)
    }

    func testSeveralRemoteOnlyAccountsFromOneDeviceStayTellableApart() {
        // Many accounts on the mini, none on this Mac: each must keep its own slice with its own
        // identity-derived name — never several identical "Claude · Mac mini" legend rows.
        let dataStore = WidgetDataStore(
            registry: makeRegistry(),
            providers: [],
            cache: scratchCache(),
            defaults: makeScratchDefaults("ManyRemote"),
            providerIdentityKeys: ["claude": maxKey, "claude@f15456b0": teamKey]
        )
        let today = dayKey(Date())
        let doc = makeDocument(
            deviceName: "Mac mini",
            providers: [
                "claude@11111111": history(day: today, tokens: 10, cost: 1),
                "claude@22222222": history(day: today, tokens: 20, cost: 2),
            ],
            identities: [
                "claude@11111111": "uuid-a|org-a",
                "claude@22222222": "uuid-b|org-b",
            ]
        )
        dataStore.setPeerHistoryDocuments([doc], ownDeviceID: "this-mac")

        XCTAssertEqual(dataStore.remoteOnlySpend.count, 2)
        let names = Set(dataStore.remoteOnlySpend.map(\.provider.displayName))
        XCTAssertEqual(names.count, 2, "every remote-only account carries a unique display name")
        for name in names {
            XCTAssertTrue(name.hasPrefix("claude@"), "unexpected slice name: \(name)")
        }
    }

    func testClearingPeersDropsRemoteOnlyEntries() {
        let dataStore = WidgetDataStore(
            registry: makeRegistry(),
            providers: [],
            cache: scratchCache(),
            defaults: makeScratchDefaults("ClearPeers"),
            providerIdentityKeys: ["claude": maxKey, "claude@f15456b0": teamKey]
        )
        let doc = makeDocument(
            deviceName: "Mac mini",
            providers: ["claude@ab12cd34": history(day: dayKey(Date()), tokens: 10, cost: 1)],
            identities: ["claude@ab12cd34": "uuid-other|org-x"]
        )
        dataStore.setPeerHistoryDocuments([doc], ownDeviceID: "this-mac")
        XCTAssertEqual(dataStore.remoteOnlySpend.count, 1)

        dataStore.clearPeerHistoryDocuments()
        XCTAssertTrue(dataStore.remoteOnlySpend.isEmpty, "sync off returns Total Spend to local-only")
    }

    // MARK: - Fixtures

    private func makeRegistry(includeDefault: Bool = true) -> WidgetRegistry {
        let claude = ClaudeProvider.makeProvider()
        let extraCard = ClaudeProvider.makeProvider(id: "claude@f15456b0", displayName: "Claude — Team")
        let providers = includeDefault ? [claude, extraCard] : [extraCard]
        let descriptors = providers.map {
            WidgetDescriptor.usageTrend(provider: $0)
                .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "test")
        }
        return WidgetRegistry(providers: providers, descriptors: descriptors)
    }

    private func scratchCache() -> ProviderSnapshotCache {
        ProviderSnapshotCache(userDefaults: makeScratchDefaults("Cache"), storageKey: "snapshots", ttl: 600)
    }

    private func makeScratchDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.PeerIdentity.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func makeDocument(
        deviceName: String = "Peer",
        providers: [String: ProviderUsageHistory],
        identities: [String: String]?
    ) -> UsageHistoryDocument {
        UsageHistoryDocument(
            deviceID: UUID().uuidString,
            deviceName: deviceName,
            updatedAt: Date(),
            providers: providers,
            identities: identities
        )
    }

    private func history(day: String, tokens: Int, cost: Double) -> ProviderUsageHistory {
        ProviderUsageHistory(
            series: DailyUsageSeries(daily: [DailyUsageEntry(date: day, totalTokens: tokens, costUSD: cost)]),
            modelUsage: nil,
            unknownModelsByDay: [:]
        )
    }

    private func snapshot(providerID: String, history: ProviderUsageHistory) -> ProviderSnapshot {
        var snapshot = ProviderSnapshot(
            providerID: providerID,
            displayName: providerID,
            lines: [],
            refreshedAt: Date()
        )
        snapshot.usageHistory = history
        return snapshot
    }

    private func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
