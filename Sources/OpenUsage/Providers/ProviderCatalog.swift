import Foundation

/// The installed provider set and its canonical order. Both the menu-bar app and one-shot CLI build
/// their runtimes here so credentials, refresh behavior, pricing, and normalization can never drift.
@MainActor
enum ProviderCatalog {
    static func make(
        defaults: UserDefaults = .standard,
        claudeCards: [ClaudeAccountCard] = [],
        allowsUnboundClaudeFallback: Bool = true,
        defaultClaudeExtraLogRoots: [URL] = [],
        defaultClaudeCoworkRoots: [URL]? = nil,
        defaultClaudeOrganization: String? = nil
    ) -> [ProviderRuntime] {
        var runtimes: [ProviderRuntime] = []

        if claudeCards.isEmpty, allowsUnboundClaudeFallback {
            // Preserve the existing spend-only / unresolved-identity behavior when discovery
            // cannot prove any Claude account. Once an account is verified, every Claude runtime
            // comes from its record instead; there is never a second hardcoded default card.
            runtimes.append(ClaudeProvider(
                authStore: ClaudeAuthStore(
                    standardDesktopOrganization: defaultClaudeOrganization,
                    allowsUnpinnedStandardDesktopFallback: defaultClaudeCoworkRoots == nil
                ),
                logUsageScanner: ClaudeLogUsageScanner(
                    additionalRoots: defaultClaudeExtraLogRoots,
                    coworkRootsOverride: defaultClaudeCoworkRoots
                )
            ))
        } else if !claudeCards.isEmpty {
            let allowsUnpinnedDesktopFallback = claudeCards.count == 1
                && defaultClaudeCoworkRoots == nil
            for card in claudeCards {
                runtimes.append(claudeAccountRuntime(
                    card: card,
                    allowsUnpinnedDesktopFallback: allowsUnpinnedDesktopFallback
                ))
            }
        }

        // The three established families remain first, followed by the alphabetical provider tail.
        // Account instances sit together before Codex regardless of which one holds the default.
        runtimes += [
            CodexProvider(),
            CursorProvider(),
            AntigravityProvider(),
            CopilotProvider(defaults: defaults),
            DevinProvider(),
            GrokProvider(),
            OpenCodeProvider(),
            OpenRouterProvider(),
            ZAIProvider()
        ]
        return runtimes
    }

    private static func claudeAccountRuntime(
        card: ClaudeAccountCard,
        allowsUnpinnedDesktopFallback: Bool
    ) -> ClaudeProvider {
        let authStore: ClaudeAuthStore
        let scanner: ClaudeLogUsageScanner

        switch card.credential {
        case .defaultHome:
            let organization = card.identityKey.split(separator: "|", maxSplits: 1)
                .dropFirst().first.map(String.init)
            authStore = ClaudeAuthStore(
                scope: .standard,
                standardDesktopOrganization: organization,
                allowsUnpinnedStandardDesktopFallback: allowsUnpinnedDesktopFallback
            )
            scanner = ClaudeLogUsageScanner(
                cacheIdentityOverride: card.id == "claude" ? nil : "claude-account:\(card.id)",
                additionalRoots: card.additionalLogRoots,
                coworkRootsOverride: card.coworkRootsOverride
            )
        case .configDir(let path, let keychainLiteral):
            authStore = ClaudeAuthStore(
                scope: .configDir(path: path, keychainLiteral: keychainLiteral)
            )
            scanner = ClaudeLogUsageScanner(
                cacheIdentityOverride: "claude-account:\(card.id)",
                rootsOverride: card.logRoots
            )
        case .desktop(let organization):
            authStore = ClaudeAuthStore(scope: .desktopOnly(organization: organization))
            scanner = ClaudeLogUsageScanner(
                cacheIdentityOverride: "claude-account:\(card.id)",
                rootsOverride: card.logRoots
            )
        }

        return ClaudeProvider(
            provider: ClaudeProvider.makeProvider(id: card.id, displayName: card.displayName),
            authStore: authStore,
            logUsageScanner: scanner,
            expectedIdentityKey: card.identityKey
        )
    }
}
