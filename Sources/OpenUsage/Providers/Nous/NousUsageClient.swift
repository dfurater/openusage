import Foundation

struct NousUsageClient: Sendable {
    static let billingStateURL = "https://portal.nousresearch.com/api/billing/state"
    static let billingSubscriptionURL = "https://portal.nousresearch.com/api/billing/subscription"

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// Role-tiered account overview: balance, monthly cap, payment state. No scope required.
    func fetchBillingState(credential: String) async throws -> HTTPResponse {
        try await get(Self.billingStateURL, credential: credential)
    }

    /// Current subscription tier, credits remaining vs. monthly credits, cycle reset.
    func fetchSubscription(credential: String) async throws -> HTTPResponse {
        try await get(Self.billingSubscriptionURL, credential: credential)
    }

    private func get(_ urlString: String, credential: String) async throws -> HTTPResponse {
        guard let url = URL(string: urlString) else {
            throw NousUsageError.invalidResponse
        }

        return try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Authorization": "Bearer \(credential)",
                "Accept": "application/json"
            ],
            timeout: 15
        ))
    }
}

enum NousUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Couldn't reach the Nous Portal. Check your connection."
        case .invalidResponse:
            return "Nous Portal usage data unavailable. Try again later."
        case .requestFailed(let status):
            return "Nous Portal request failed (HTTP \(status))."
        }
    }
}
