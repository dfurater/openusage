import Foundation

/// Builds metric lines from the Nous Portal `/api/billing/state` and `/api/billing/subscription`
/// payloads. Each endpoint maps independently so the provider shows whatever came back — matching
/// the OpenRouter pattern where one endpoint failing never blanks the other's rows.
///
/// Portal amounts arrive as JSON strings ("0.1", "1000") — `ProviderParse.number` handles both
/// strings and numbers.
enum NousUsageMapper {
    // MARK: - /api/billing/state

    /// The Monthly Cap meter from `monthlyCap` (`limitUsd` / `spentThisMonthUsd`). Empty when no
    /// usable limit is reported (the meter is meaningless without a positive ceiling).
    static func monthlyCapLine(from data: [String: Any]) -> [MetricLine] {
        guard let cap = data["monthlyCap"] as? [String: Any],
              let limit = ProviderParse.number(cap["limitUsd"]), limit > 0,
              let spent = ProviderParse.number(cap["spentThisMonthUsd"]) else { return [] }

        let resetsAt = (cap["resetsAt"] as? String).flatMap { OpenUsageISO8601.date(from: $0) }
        return [.progress(
            label: "Monthly Cap",
            used: max(0, spent),
            limit: limit,
            format: .dollars,
            resetsAt: resetsAt
        )]
    }

    /// Prepaid balance as an unbounded row. A real zero is a measured zero ("$0.00 left"), never
    /// "No data" — same convention as OpenRouter's Balance.
    static func balanceLine(from data: [String: Any]) -> [MetricLine] {
        guard let balance = ProviderParse.number(data["balanceUsd"]) else { return [] }
        return [.values(
            label: "Balance",
            values: [MetricValue(number: max(0, balance), kind: .dollars)]
        )]
    }

    // MARK: - /api/billing/subscription

    /// The plan name for the provider header (e.g. "Plus").
    static func planName(from data: [String: Any]) -> String? {
        guard let current = data["current"] as? [String: Any] else { return nil }
        return current["tierName"] as? String
    }

    /// Credits meter: `creditsRemaining` against `monthlyCredits`, resetting at `cycleEndsAt`.
    /// Skipped when the tier carries no monthly credit allotment (a 0-credit tier has no meaningful
    /// ceiling); the raw remaining amount still renders via `remainingLines`.
    static func creditsLine(from data: [String: Any]) -> [MetricLine] {
        guard let current = data["current"] as? [String: Any],
              let monthly = ProviderParse.number(current["monthlyCredits"]), monthly > 0,
              let remaining = ProviderParse.number(current["creditsRemaining"]) else { return [] }

        let resetsAt = (current["cycleEndsAt"] as? String).flatMap { OpenUsageISO8601.date(from: $0) }
        // Clamp into 0...monthly so a transiently negative or overshooting server value can't
        // render an impossible meter.
        let used = max(0, min(monthly, monthly - remaining))
        return [.progress(
            label: "Credits",
            used: used,
            limit: monthly,
            format: .dollars,
            resetsAt: resetsAt
        )]
    }

    /// Unbounded "credits left" row so even a 0-credit tier shows its real remaining amount.
    static func remainingLines(from data: [String: Any]) -> [MetricLine] {
        guard let current = data["current"] as? [String: Any],
              let remaining = ProviderParse.number(current["creditsRemaining"]) else { return [] }
        return [.values(
            label: "Credits Left",
            values: [MetricValue(number: max(0, remaining), kind: .dollars, label: "left")]
        )]
    }

    /// Map one endpoint payload into its metric lines; returns `(plan, lines)` for the subscription
    /// call and plain lines elsewhere.
    static func subscriptionMetrics(from data: [String: Any]) -> (plan: String?, lines: [MetricLine]) {
        var lines = creditsLine(from: data) + remainingLines(from: data)
        if lines.isEmpty {
            // Nothing usable in `current`: keep the payload's own notice visible through the local
            // API without inventing a widget-backed row.
            if let status = data["context"] as? String {
                lines.append(.text(label: "Status", value: status))
            }
        }
        return (planName(from: data), lines)
    }
}
