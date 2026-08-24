import Foundation

/// Matches synced peer histories to this Mac's cards by ACCOUNT identity instead of by card id.
///
/// Account-card ids don't necessarily describe the same login on different Macs: the first account
/// observed on each machine keeps the bare family id. An account history therefore enters a local
/// card only when both machines identify the same account unambiguously. Older v1 account histories
/// and unresolved identities are quarantined rather than guessed from a matching provider id.
enum PeerHistoryRemapper {
    struct Remapped {
        /// Peer histories addressed to a LOCAL card id, ready for the same-id day merge.
        var histories: [(cardID: String, history: ProviderUsageHistory)] = []
        /// Peer accounts with no local card, keyed by identity.
        var remoteOnly: [RemoteOnlyHistory] = []
        /// Histories whose owner cannot be established safely. These never reach a concrete card,
        /// Total Spend, or a subsequently published local history document.
        var quarantined: [QuarantinedHistory] = []
    }

    struct QuarantinedHistory {
        enum Reason: Equatable {
            case missingPeerIdentity
            case ambiguousPeerIdentity
            case unresolvedLocalIdentity
            case ambiguousLocalIdentity
        }

        var cardID: String
        var family: String
        var reason: Reason
    }

    struct RemoteOnlyHistory {
        var identityKey: String
        var family: String
        /// The account's identity-derived display code (`claude@ab12cd34`). A card may retain the
        /// historical bare family id on another Mac, so this is a presentation/grouping key rather
        /// than a claim that card ids are globally identical.
        var cardID: String
        var histories: [ProviderUsageHistory]
    }

    /// `localIdentityByCardID` is this Mac's card → identity map (the launch account pass's
    /// `identityKeysByCard`).
    static func remap(
        documents: [UsageHistoryDocument],
        localIdentityByCardID: [String: String],
        localAccountCardIDs: Set<String>? = nil
    ) -> Remapped {
        struct FamilyIdentity: Hashable {
            var family: String
            var identity: String
        }

        var localCardsByIdentity: [FamilyIdentity: [String]] = [:]
        for (cardID, identity) in localIdentityByCardID {
            let family = ProviderAccountID.family(of: cardID)
            guard ProviderAccountID.families.contains(family), !identity.isEmpty else { continue }
            localCardsByIdentity[FamilyIdentity(family: family, identity: identity), default: []]
                .append(cardID)
        }
        let localCardIDs = localAccountCardIDs ?? Set(localIdentityByCardID.keys)

        var result = Remapped()
        var remoteByIdentity: [FamilyIdentity: RemoteOnlyHistory] = [:]
        func collectRemoteOnly(identity: String, family: String, cardID: String, history: ProviderUsageHistory) {
            let key = FamilyIdentity(family: family, identity: identity)
            var entry = remoteByIdentity[key] ?? RemoteOnlyHistory(
                identityKey: identity, family: family, cardID: cardID, histories: []
            )
            entry.histories.append(history)
            remoteByIdentity[key] = entry
        }

        for document in UsageHistoryDocument.newestByDevice(documents) {
            let peerIdentityCounts = Dictionary(
                (document.identities ?? [:]).map { cardID, identity in
                    (FamilyIdentity(family: ProviderAccountID.family(of: cardID), identity: identity), 1)
                },
                uniquingKeysWith: +
            )
            for (peerCardID, history) in document.providers.sorted(by: { $0.key < $1.key }) {
                let family = ProviderAccountID.family(of: peerCardID)

                guard ProviderAccountID.families.contains(family) else {
                    result.histories.append((peerCardID, history))
                    continue
                }

                guard let identity = document.identities?[peerCardID], !identity.isEmpty else {
                    result.quarantined.append(QuarantinedHistory(
                        cardID: peerCardID, family: family, reason: .missingPeerIdentity
                    ))
                    continue
                }

                let identityKey = FamilyIdentity(family: family, identity: identity)
                guard peerIdentityCounts[identityKey] == 1 else {
                    result.quarantined.append(QuarantinedHistory(
                        cardID: peerCardID, family: family, reason: .ambiguousPeerIdentity
                    ))
                    continue
                }

                let localMatches = localCardsByIdentity[identityKey] ?? []
                if localMatches.count == 1 {
                    result.histories.append((localMatches[0], history))
                    continue
                }
                if localMatches.count > 1 {
                    result.quarantined.append(QuarantinedHistory(
                        cardID: peerCardID, family: family, reason: .ambiguousLocalIdentity
                    ))
                    continue
                }

                let knownFamilyCards = localCardIDs.filter {
                    ProviderAccountID.family(of: $0) == family
                }
                let hasUnresolvedLocalCard = knownFamilyCards.contains {
                    localIdentityByCardID[$0] == nil
                }
                let hasResolvedLocalFamily = localIdentityByCardID.keys.contains {
                    ProviderAccountID.family(of: $0) == family
                }
                guard hasResolvedLocalFamily, !hasUnresolvedLocalCard else {
                    result.quarantined.append(QuarantinedHistory(
                        cardID: peerCardID, family: family, reason: .unresolvedLocalIdentity
                    ))
                    continue
                }

                collectRemoteOnly(
                    identity: identity,
                    family: family,
                    cardID: ProviderAccountID.make(family: family, identityKey: identity),
                    history: history
                )
            }
        }

        result.remoteOnly = remoteByIdentity.values.sorted {
            ($0.family, $0.identityKey) < ($1.family, $1.identityKey)
        }
        return result
    }
}
