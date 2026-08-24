import Foundation

/// One verified account-to-runtime binding. The credential source belongs to the account record,
/// never to the spelling of its id: the original `claude` record can move to Desktop or a custom
/// config dir while an `@`-suffixed record takes over the default home.
struct ClaudeAccountCard: Equatable, Sendable {
    enum Credential: Equatable, Sendable {
        case defaultHome
        case configDir(path: String, keychainLiteral: String)
        case desktop(organization: String)
    }

    var id: String
    var displayName: String
    var identityKey: String
    var credential: Credential
    /// Config-dir and Cowork roots that have been positively attributed to this account.
    var logRoots: [URL]
    /// A default-home runtime keeps its historical root resolution and adds only same-account dirs.
    var additionalLogRoots: [URL] = []
    /// Once multiple accounts exist, an explicit partition prevents foreign or unidentified Cowork
    /// sandboxes from leaking into the default-home runtime's standard scan.
    var coworkRootsOverride: [URL]?
}

/// Results collected away from the main actor before rebuilding the account graph.
/// The account registry itself remains main-actor-owned; only filesystem discovery is detached.
struct PreparedProviderAccountDiscovery: Sendable {
    var config: ClaudeConfigDirDiscovery.Result
    var cowork: ClaudeCoworkDiscovery.Result
}

/// Discovers verified account sources, reconciles their permanent records, and constructs exactly
/// one runtime binding per account observed this launch.
@MainActor
struct ProviderAccountAssembly {
    let identityKeysByCard: [String: String]
    /// Every observed Claude account, including the bare-id account when one exists.
    var claudeCards: [ClaudeAccountCard] = []
    /// Preserve historical spend-only behavior only before any Claude account has ever been named.
    /// Once a persisted account exists, an unbound fallback could borrow another account's login.
    var allowsUnboundClaudeFallback = true
    /// Compatibility accessors describe the actual default-home holder, not the bare-id record.
    var defaultClaudeExtraLogRoots: [URL] = []
    var defaultClaudeCoworkRoots: [URL]?

    var defaultClaudeOrganization: String? {
        guard let defaultCard = claudeCards.first(where: { $0.credential == .defaultHome }),
              let separator = defaultCard.identityKey.firstIndex(of: "|")
        else { return nil }
        return String(defaultCard.identityKey[defaultCard.identityKey.index(after: separator)...]).nilIfEmpty
    }

    static func make(
        defaults: UserDefaults = .standard,
        accountsStore: ProviderAccountsStore? = nil,
        waitsForLoginShell: Bool,
        preparedDiscovery: PreparedProviderAccountDiscovery? = nil
    ) -> ProviderAccountAssembly {
        let store = accountsStore ?? ProviderAccountsStore(defaults: defaults)
        let shellFactsReadable = !waitsForLoginShell
            || LoginShellEnvironment.shared.capturedSuccessfully
            || ShellEnvironmentSnapshotStore.launchSnapshot != nil
        let families = shellFactsReadable
            ? ProviderAccountID.families
            : ProviderAccountID.families.filter { family in
                guard let key = Self.homeOverrideKeys[family] else { return false }
                return ProcessInfo.processInfo.environment[key]?.nilIfEmpty != nil
            }
        if families.count < ProviderAccountID.families.count {
            AppLog.info(.config, "account identity read skipped for \(ProviderAccountID.families.subtracting(families).sorted().joined(separator: ", ")): login shell cold and no shell-environment snapshot exists yet")
        }
        guard !families.isEmpty else {
            return ProviderAccountAssembly(
                identityKeysByCard: [:],
                allowsUnboundClaudeFallback: !store.records.contains { $0.family == "claude" }
            )
        }
        return make(
            observer: DefaultAccountObserver(),
            accountsStore: store,
            families: families,
            claudeDiscovery: ClaudeConfigDirDiscovery(),
            coworkDiscovery: ClaudeCoworkDiscovery(),
            preparedDiscovery: preparedDiscovery
        )
    }

    private static let homeOverrideKeys: [String: String] = [
        "claude": "CLAUDE_CONFIG_DIR",
        "codex": "CODEX_HOME",
    ]

    static func make(
        observer: DefaultAccountObserver,
        accountsStore: ProviderAccountsStore,
        families: Set<String> = ProviderAccountID.families,
        claudeDiscovery: ClaudeConfigDirDiscovery? = nil,
        coworkDiscovery: ClaudeCoworkDiscovery? = nil,
        preparedDiscovery: PreparedProviderAccountDiscovery? = nil,
        hasDesktopCredentialMaterial: @Sendable () -> Bool = {
            ClaudeDesktopAuthStore().hasCredentialMaterial()
        }
    ) -> ProviderAccountAssembly {
        var identityKeys: [String: String] = [:]
        var observations: [ProviderAccountsStore.AccountObservation] = []
        let outcomes: [(family: String, outcome: DefaultAccountObserver.Outcome)] = [
            ("claude", { observer.observeClaude() }),
            ("codex", { observer.observeCodex() }),
        ].compactMap { family, observe in
            families.contains(family) ? (family, observe()) : nil
        }

        let claudeOutcome = outcomes.first { $0.family == "claude" }?.outcome
        let claudeCandidatesAllowed = claudeOutcome != nil
        if case .unresolved? = claudeOutcome {
            AppLog.info(.config, "discovery: claude default identity is unreadable; checking independently verified config-dir and Desktop accounts")
        }

        let configScan = claudeCandidatesAllowed
            ? preparedDiscovery?.config ?? claudeDiscovery?.run()
            : nil
        let coworkScan = claudeCandidatesAllowed
            ? preparedDiscovery?.cowork ?? coworkDiscovery?.run()
            : nil
        for note in (configScan?.notes ?? []) + (coworkScan?.notes ?? []) {
            AppLog.info(.config, "discovery: \(note)")
        }

        var knownClaudeIdentities = Set(
            accountsStore.records
                .filter { $0.family == "claude" }
                .flatMap { [$0.identityKey] + ($0.identityAliases ?? []) }
        )
        if case .resolved(let key, _, _)? = claudeOutcome {
            knownClaudeIdentities.insert(key)
        }
        for finding in configScan?.findings ?? [] {
            knownClaudeIdentities.insert(finding.identityKey)
        }
        if coworkScan?.truncated != true {
            for sandbox in coworkScan?.sandboxes ?? [] {
                if let identityKey = sandbox.identityKey {
                    knownClaudeIdentities.insert(identityKey)
                }
            }
        }

        // Credential-bearing CLI sources determine the identity spelling a bound provider can
        // actually verify. An org-less default/config state and its one known Cowork org may fold
        // together, but the card must retain the org-less key so strict source validation succeeds.
        var preferredClaudeIdentities: [String: String] = [:]
        if case .resolved(let identityKey, _, _)? = claudeOutcome {
            preferredClaudeIdentities[claudeUserID(identityKey)] = identityKey.lowercased()
        }
        for finding in configScan?.findings ?? [] {
            let userID = claudeUserID(finding.identityKey)
            if preferredClaudeIdentities[userID] == nil {
                preferredClaudeIdentities[userID] = finding.identityKey.lowercased()
            }
        }

        var plannedAccounts: [String: PlannedClaudeAccount] = [:]
        var plannedOrder: [String] = []
        var defaultClaudeKey: String?

        for (family, outcome) in outcomes {
            switch outcome {
            case .resolved(let rawIdentityKey, let label, let anchor):
                let identityKey: String
                if family == "claude" {
                    guard let resolved = canonicalClaudeIdentity(
                        rawIdentityKey,
                        among: knownClaudeIdentities,
                        preferred: preferredClaudeIdentities
                    ) else {
                        AppLog.warn(.config, "accounts: claude default identity omits its organization while multiple organizations share that login; source quarantined")
                        continue
                    }
                    identityKey = resolved
                    defaultClaudeKey = resolved
                    let source = ProviderAccountSource(
                        kind: .defaultHome,
                        anchor: anchor,
                        holdsDefaultSource: true
                    )
                    plannedOrder.append(identityKey)
                    plannedAccounts[identityKey] = PlannedClaudeAccount(
                        identityKey: identityKey,
                        label: label,
                        sources: [source],
                        credential: .defaultHome,
                        logRoots: [URL(fileURLWithPath: anchor)]
                    )
                } else {
                    identityKey = rawIdentityKey
                    observations.append(ProviderAccountsStore.AccountObservation(
                        family: family,
                        identityKey: identityKey,
                        label: label,
                        sources: [ProviderAccountSource(
                            kind: .defaultHome,
                            anchor: anchor,
                            holdsDefaultSource: true
                        )]
                    ))
                    identityKeys[family] = identityKey
                }
                AppLog.info(.config, "accounts: \(family) default identity resolved (\(ProviderAccountID.make(family: family, identityKey: identityKey)))")
            case .unresolved(let reason):
                AppLog.info(.config, "accounts: \(family) default identity unresolved — \(reason)")
            case .absent:
                AppLog.debug(.config, "accounts: \(family) has no default login")
            }
        }

        for finding in configScan?.findings ?? [] {
            guard let identityKey = canonicalClaudeIdentity(
                finding.identityKey,
                among: knownClaudeIdentities,
                preferred: preferredClaudeIdentities
            ) else {
                AppLog.warn(.config, "discovery: claude config-dir identity omits its organization while multiple organizations share that login; source quarantined")
                continue
            }
            let source = ProviderAccountSource(
                kind: .configDir,
                anchor: finding.anchorPath,
                holdsDefaultSource: false,
                keychainLiteral: finding.keychainLiteral
            )
            let root = URL(fileURLWithPath: finding.anchorPath)
            if var account = plannedAccounts[identityKey] {
                appendUnique(source, to: &account.sources)
                appendUnique(root, to: &account.logRoots)
                if account.credential == .defaultHome {
                    appendUnique(root, to: &account.additionalLogRoots)
                }
                if account.label == nil { account.label = finding.label }
                plannedAccounts[identityKey] = account
            } else {
                plannedOrder.append(identityKey)
                plannedAccounts[identityKey] = PlannedClaudeAccount(
                    identityKey: identityKey,
                    label: finding.label,
                    sources: [source],
                    credential: .configDir(
                        path: finding.anchorPath,
                        keychainLiteral: finding.keychainLiteral
                    ),
                    logRoots: [root]
                )
            }
        }

        var defaultCoworkRoots: [URL] = []
        var unidentifiedCoworkRoots: [URL] = []
        var needsCoworkPartition = false
        var desktopCredentialMaterial: Bool?
        if let coworkScan, !coworkScan.truncated {
            let desktopUsersByOrganization = coworkScan.sandboxes.reduce(
                into: [String: Set<String>]()
            ) { users, sandbox in
                guard let organization = sandbox.organization?.nilIfEmpty,
                      let identityKey = sandbox.identityKey
                else { return }
                users[organization, default: []].insert(claudeUserID(identityKey))
            }
            for sandbox in coworkScan.sandboxes {
                guard let sandboxKey = sandbox.identityKey else {
                    unidentifiedCoworkRoots.append(sandbox.root)
                    continue
                }
                guard let identityKey = canonicalClaudeIdentity(
                    sandboxKey,
                    among: knownClaudeIdentities,
                    preferred: preferredClaudeIdentities
                ) else {
                    needsCoworkPartition = true
                    AppLog.warn(.config, "discovery: cowork sandbox identity omits its organization while multiple organizations share that login; sandbox quarantined")
                    continue
                }
                if identityKey == defaultClaudeKey {
                    appendUnique(sandbox.root, to: &defaultCoworkRoots)
                    continue
                }

                needsCoworkPartition = true
                let hasAmbiguousDesktopOwner = sandbox.organization.map {
                    (desktopUsersByOrganization[$0]?.count ?? 0) > 1
                } ?? false
                let desktopSource = ProviderAccountSource(
                    kind: .desktop,
                    anchor: nil,
                    holdsDefaultSource: false
                )
                if var account = plannedAccounts[identityKey] {
                    appendUnique(sandbox.root, to: &account.logRoots)
                    if sandbox.organization != nil && !hasAmbiguousDesktopOwner {
                        appendUnique(desktopSource, to: &account.sources)
                    } else if hasAmbiguousDesktopOwner {
                        AppLog.warn(.config, "discovery: cowork organization names multiple account owners; Desktop credential source quarantined")
                    }
                    if account.label == nil { account.label = sandbox.label }
                    plannedAccounts[identityKey] = account
                    continue
                }

                guard let organization = sandbox.organization?.nilIfEmpty else {
                    AppLog.warn(.config, "discovery: cowork account \(ProviderAccountID.make(family: "claude", identityKey: identityKey)) has no organization pin; sandbox quarantined")
                    continue
                }
                guard !hasAmbiguousDesktopOwner else {
                    AppLog.warn(.config, "discovery: cowork organization names multiple account owners; Desktop-only account quarantined")
                    continue
                }
                if desktopCredentialMaterial == nil {
                    desktopCredentialMaterial = hasDesktopCredentialMaterial()
                }
                guard desktopCredentialMaterial == true else {
                    AppLog.info(.config, "discovery: cowork account \(ProviderAccountID.make(family: "claude", identityKey: identityKey)) has no current Desktop credential material; historical sandbox skipped")
                    continue
                }
                plannedOrder.append(identityKey)
                plannedAccounts[identityKey] = PlannedClaudeAccount(
                    identityKey: identityKey,
                    label: sandbox.label,
                    sources: [desktopSource],
                    credential: .desktop(organization: organization),
                    logRoots: [sandbox.root]
                )
            }
        }

        let multipleClaudeAccounts = plannedAccounts.count > 1
        if multipleClaudeAccounts {
            needsCoworkPartition = true
        }
        if !unidentifiedCoworkRoots.isEmpty, needsCoworkPartition {
            AppLog.warn(.config, "discovery: \(unidentifiedCoworkRoots.count) unidentified cowork sandbox(es) quarantined because account ownership cannot be proven")
        }
        if coworkScan?.truncated == true {
            needsCoworkPartition = true
            defaultCoworkRoots = []
            AppLog.warn(.config, "discovery: cowork scan truncated; cowork spend withheld until a complete scan proves account ownership")
        }

        // The default observation must be reconciled first, preserving the existing bare-id
        // migration rule; every later source attaches to its own stable account record.
        if claudeOutcome != nil, defaultClaudeKey == nil {
            accountsStore.clearDefaultSource(family: "claude")
        }
        let claudeObservations = plannedOrder.compactMap { identityKey -> ProviderAccountsStore.AccountObservation? in
            guard let account = plannedAccounts[identityKey] else { return nil }
            return ProviderAccountsStore.AccountObservation(
                family: "claude",
                identityKey: account.identityKey,
                label: account.label,
                sources: account.sources
            )
        }
        observations = claudeObservations + observations
        let records = accountsStore.reconcile(with: observations)

        var claudeCards: [ClaudeAccountCard] = []
        for identityKey in plannedOrder {
            guard let planned = plannedAccounts[identityKey],
                  let record = records.first(where: {
                      $0.family == "claude"
                          && $0.identityKey == identityKey
                          && !$0.removedTombstone
                  })
            else { continue }
            let isDefaultHome = planned.credential == .defaultHome
            let card = ClaudeAccountCard(
                id: record.id,
                displayName: accountsStore.derivedDisplayName(cardID: record.id)
                    ?? record.derivedDisplayName,
                identityKey: record.identityKey,
                credential: planned.credential,
                logRoots: planned.logRoots,
                additionalLogRoots: planned.additionalLogRoots,
                coworkRootsOverride: isDefaultHome && needsCoworkPartition ? defaultCoworkRoots : nil
            )
            claudeCards.append(card)
            identityKeys[record.id] = record.identityKey
            AppLog.info(.config, "accounts: claude card \(record.id) bound to \(sourceDescription(planned.credential)); \(planned.logRoots.count) verified log root(s)")
        }
        claudeCards.sort {
            if $0.id == "claude" { return true }
            if $1.id == "claude" { return false }
            return $0.id < $1.id
        }

        let defaultCard = claudeCards.first { $0.credential == .defaultHome }
        return ProviderAccountAssembly(
            identityKeysByCard: identityKeys,
            claudeCards: claudeCards,
            allowsUnboundClaudeFallback: !records.contains { $0.family == "claude" },
            defaultClaudeExtraLogRoots: defaultCard?.additionalLogRoots ?? [],
            defaultClaudeCoworkRoots: defaultCard?.coworkRootsOverride
        )
    }

    /// An org-less identity can inherit an organization only when exactly one organization is
    /// known for that user. With personal and work orgs present, assigning it to either is unsafe.
    private static func canonicalClaudeIdentity(
        _ rawIdentityKey: String,
        among knownIdentityKeys: Set<String>,
        preferred preferredIdentities: [String: String] = [:]
    ) -> String? {
        let identityKey = rawIdentityKey.lowercased()
        let parts = identityKey.split(separator: "|", maxSplits: 1)
        let organizations = Set(knownIdentityKeys.compactMap { candidate -> String? in
            let components = candidate.lowercased().split(separator: "|", maxSplits: 1)
            guard components.count == 2, components[0] == parts[0] else { return nil }
            return String(components[1])
        })
        if parts.count == 2 {
            if organizations.count == 1,
               let preferred = preferredIdentities[String(parts[0])],
               !preferred.contains("|")
            {
                return preferred
            }
            return identityKey
        }
        guard organizations.count <= 1 else { return nil }
        if let preferred = preferredIdentities[String(parts[0])], !preferred.contains("|") {
            return preferred
        }
        guard let organization = organizations.first else { return identityKey }
        return "\(parts[0])|\(organization)"
    }

    private static func claudeUserID(_ identityKey: String) -> String {
        String(identityKey.lowercased().split(separator: "|", maxSplits: 1).first ?? "")
    }

    static func sameClaudeAccount(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = canonicalClaudeIdentity(lhs, among: [lhs, rhs]),
              let right = canonicalClaudeIdentity(rhs, among: [lhs, rhs])
        else { return false }
        return left == right
    }

    private static func appendUnique<Value: Equatable>(_ value: Value, to values: inout [Value]) {
        if !values.contains(value) { values.append(value) }
    }

    private static func sourceDescription(_ credential: ClaudeAccountCard.Credential) -> String {
        switch credential {
        case .defaultHome: "default home"
        case .configDir: "config dir"
        case .desktop: "desktop"
        }
    }

    private struct PlannedClaudeAccount {
        var identityKey: String
        var label: String?
        var sources: [ProviderAccountSource]
        var credential: ClaudeAccountCard.Credential
        var logRoots: [URL]
        var additionalLogRoots: [URL] = []
    }
}
