import Network
import XCTest
@testable import OpenUsage

@MainActor
final class LocalUsageServerTests: XCTestCase {
    func testListenerRetriesAddressInUseUntilReplacementBinds() async throws {
        let first = FakeLocalUsageListener()
        let replacement = FakeLocalUsageListener()
        var listeners = [first, replacement]
        let server = LocalUsageServer(
            state: Self.emptyState,
            makeListener: { _ in listeners.removeFirst() },
            retryDelay: .milliseconds(1),
            maxStartupAttempts: 3
        )

        server.start()
        XCTAssertEqual(first.startCount, 1)

        first.send(.failed(.posix(.EADDRINUSE)))
        try await waitUntil { replacement.startCount == 1 }
        replacement.send(.ready)

        XCTAssertEqual(first.cancelCount, 1, "the failed generation must release its listener")
        XCTAssertEqual(replacement.cancelCount, 0, "the replacement listener remains available")
        XCTAssertTrue(listeners.isEmpty)
        server.stop()
        XCTAssertEqual(replacement.cancelCount, 1)
    }

    func testStopCancelsPendingRetryAndNeverRestartsOldGraph() async throws {
        let first = FakeLocalUsageListener()
        let replacement = FakeLocalUsageListener()
        var attempts = 0
        let server = LocalUsageServer(
            state: Self.emptyState,
            makeListener: { _ in
                defer { attempts += 1 }
                return attempts == 0 ? first : replacement
            },
            retryDelay: .milliseconds(40),
            maxStartupAttempts: 3
        )
        server.start()
        first.send(.failed(.posix(.EADDRINUSE)))
        try await waitUntil { first.cancelCount == 1 }

        server.stop()
        try await Task.sleep(for: .milliseconds(90))

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(replacement.startCount, 0)
    }

    func testAddressInUseRetriesAreBounded() async throws {
        var created: [FakeLocalUsageListener] = []
        let server = LocalUsageServer(
            state: Self.emptyState,
            makeListener: { _ in
                let listener = FakeLocalUsageListener()
                listener.onStart = { $0.send(.failed(.posix(.EADDRINUSE))) }
                created.append(listener)
                return listener
            },
            retryDelay: .milliseconds(1),
            maxStartupAttempts: 3
        )

        server.start()
        try await waitUntil { created.count == 3 && created.allSatisfy { $0.cancelCount == 1 } }
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(created.count, 3, "a permanently occupied port must not retry forever")
    }

    private nonisolated static func emptyState() -> LocalUsageAPI.State {
        LocalUsageAPI.State(enabledOrderedIDs: [], knownIDs: [], snapshots: [:])
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition was not met before timeout")
    }
}

@MainActor
private final class FakeLocalUsageListener: LocalUsageListening {
    private var stateHandler: (@Sendable (NWListener.State) -> Void)?
    private var connectionHandler: (@Sendable (NWConnection) -> Void)?
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    var onStart: (@MainActor (FakeLocalUsageListener) -> Void)?

    func setStateHandler(_ handler: (@Sendable (NWListener.State) -> Void)?) {
        stateHandler = handler
    }

    func setConnectionHandler(_ handler: (@Sendable (NWConnection) -> Void)?) {
        connectionHandler = handler
    }

    func start(queue: DispatchQueue) {
        startCount += 1
        onStart?(self)
    }

    func cancel() {
        cancelCount += 1
    }

    func send(_ state: NWListener.State) {
        stateHandler?(state)
    }
}
