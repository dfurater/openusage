import Foundation

/// Keeps Desktop credential ownership independent from Cowork spend-log routing. Desktop tokens
/// identify an organization but not a user, so every active source contributes ownership evidence.
struct ClaudeDesktopAccountPolicy {
    private let activeIdentities: Set<String>
    private let usersByOrganization: [String: Set<String>]

    init(
        records: [ProviderAccountRecord],
        defaultOutcome: DefaultAccountObserver.Outcome?,
        configFindings: [ClaudeConfigDirDiscovery.Finding],
        coworkScan: ClaudeCoworkDiscovery.Result?
    ) {
        var identities = Set(
            records
                .filter { $0.family == "claude" && !$0.removedTombstone }
                .flatMap { [$0.identityKey] + ($0.identityAliases ?? []) }
        )
        if case .resolved(let identityKey, _, _)? = defaultOutcome {
            identities.insert(identityKey)
        }
        for finding in configFindings {
            identities.insert(finding.identityKey)
        }
        // A partial walk cannot assign logs or create cards, but identities it positively observed
        // still disprove exclusive Desktop ownership and must remain usable as safety evidence.
        for sandbox in coworkScan?.sandboxes ?? [] {
            if let identityKey = sandbox.identityKey {
                identities.insert(identityKey)
            }
        }
        activeIdentities = identities
        usersByOrganization = identities.reduce(into: [:]) { users, identityKey in
            let components = identityKey.lowercased().split(separator: "|", maxSplits: 1)
            guard components.count == 2 else { return }
            users[String(components[1]), default: []].insert(String(components[0]))
        }
    }

    func hasAmbiguousOrganization(_ organization: String?) -> Bool {
        guard let organization = organization?.nilIfEmpty?.lowercased() else { return false }
        return (usersByOrganization[organization]?.count ?? 0) > 1
    }

    func allowsUnpinnedFallbackDuringIncompleteCoworkScan(
        defaultIdentity: String?,
        hasExactlyOneDefaultAccount: Bool,
        coworkScan: ClaudeCoworkDiscovery.Result?
    ) -> Bool {
        guard coworkScan?.truncated == true,
              hasExactlyOneDefaultAccount,
              let defaultIdentity,
              !defaultIdentity.contains("|")
        else { return false }

        var organizations: Set<String> = []
        for identityKey in activeIdentities {
            let components = identityKey.lowercased().split(separator: "|", maxSplits: 1)
            guard components.first.map(String.init) == defaultIdentity.lowercased() else {
                return false
            }
            if components.count == 2 {
                organizations.insert(String(components[1]))
                if organizations.count > 1 { return false }
            }
        }
        return true
    }
}
