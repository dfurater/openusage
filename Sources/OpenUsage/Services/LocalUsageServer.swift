import Foundation
import Network

/// The listener boundary keeps asynchronous port-release races testable without binding a real port.
@MainActor
protocol LocalUsageListening: AnyObject {
    func setStateHandler(_ handler: (@Sendable (NWListener.State) -> Void)?)
    func setConnectionHandler(_ handler: (@Sendable (NWConnection) -> Void)?)
    func start(queue: DispatchQueue)
    func cancel()
}

@MainActor
private final class NetworkLocalUsageListener: LocalUsageListening {
    private let listener: NWListener

    init(parameters: NWParameters) throws {
        listener = try NWListener(using: parameters)
    }

    func setStateHandler(_ handler: (@Sendable (NWListener.State) -> Void)?) {
        listener.stateUpdateHandler = handler
    }

    func setConnectionHandler(_ handler: (@Sendable (NWConnection) -> Void)?) {
        listener.newConnectionHandler = handler
    }

    func start(queue: DispatchQueue) {
        listener.start(queue: queue)
    }

    func cancel() {
        listener.cancel()
    }
}

/// Loopback-only HTTP/1.1 listener for the read-only usage API on `127.0.0.1:6736`. Starts with
/// the app; bounded retries bridge Network's asynchronous port release after an account graph
/// reload. At most 16 requests are served concurrently — beyond that a connection gets
/// `503 {"error":"server_busy"}` immediately.
@MainActor
final class LocalUsageServer {
    static let port: UInt16 = 6736
    private static let maxConcurrentConnections = 16
    private static let headLimit = 8192

    private let state: @MainActor () -> LocalUsageAPI.State
    private let makeListener: @MainActor (NWParameters) throws -> any LocalUsageListening
    private let retryDelay: Duration
    private let maxStartupAttempts: Int
    private let queue = DispatchQueue(label: "openusage.local-api")
    private var listener: (any LocalUsageListening)?
    private var listenerGeneration: UUID?
    private var retryTask: Task<Void, Never>?
    private var startupAttempts = 0
    private var shouldRun = false
    private var activeConnections = 0

    init(
        state: @escaping @MainActor () -> LocalUsageAPI.State,
        makeListener: (@MainActor (NWParameters) throws -> any LocalUsageListening)? = nil,
        retryDelay: Duration = .milliseconds(150),
        maxStartupAttempts: Int = 12
    ) {
        precondition(maxStartupAttempts > 0)
        self.state = state
        self.makeListener = makeListener ?? { try NetworkLocalUsageListener(parameters: $0) }
        self.retryDelay = retryDelay
        self.maxStartupAttempts = maxStartupAttempts
    }

    func start() {
        guard !shouldRun else { return }
        shouldRun = true
        startupAttempts = 0
        startListener()
    }

    private func startListener() {
        guard shouldRun else { return }
        startupAttempts += 1
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: Self.port)!
        )

        let listener: any LocalUsageListening
        do {
            listener = try makeListener(parameters)
        } catch {
            handleStartupFailure(error)
            return
        }

        let generation = UUID()
        listenerGeneration = generation
        listener.setStateHandler { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self,
                      self.shouldRun,
                      self.listenerGeneration == generation
                else { return }
                if case .failed(let error) = state {
                    self.retireListener()
                    self.handleStartupFailure(error)
                }
            }
        }
        listener.setConnectionHandler { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self,
                      self.shouldRun,
                      self.listenerGeneration == generation
                else {
                    connection.cancel()
                    return
                }
                self.accept(connection)
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func handleStartupFailure(_ error: Error) {
        guard shouldRun else { return }
        guard Self.isAddressInUse(error), startupAttempts < maxStartupAttempts else {
            shouldRun = false
            AppLog.error(.localAPI, "listener failed after \(startupAttempts) attempt(s): \(error.localizedDescription)")
            return
        }

        AppLog.warn(
            .localAPI,
            "listener port is still in use; retrying startup (attempt \(startupAttempts + 1)/\(maxStartupAttempts))"
        )
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: retryDelay)
            } catch {
                return
            }
            guard !Task.isCancelled, shouldRun else { return }
            startListener()
        }
    }

    private static func isAddressInUse(_ error: Error) -> Bool {
        if case NWError.posix(let code) = error {
            return code == .EADDRINUSE
        }
        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EADDRINUSE)
    }

    /// Release the loopback port before replacing the account-owned runtime graph. Waiting for
    /// deallocation is insufficient because Network retains its listener handlers asynchronously.
    /// Cancellation itself is asynchronous; the replacement listener retries until the port is free.
    func stop() {
        shouldRun = false
        retryTask?.cancel()
        retryTask = nil
        retireListener()
    }

    private func retireListener() {
        listenerGeneration = nil
        listener?.setStateHandler(nil)
        listener?.setConnectionHandler(nil)
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        guard activeConnections < Self.maxConcurrentConnections else {
            Self.send(LocalUsageAPI.busy, over: connection)
            return
        }
        activeConnections += 1
        receiveHead(connection, buffered: Data())
    }

    /// Reads until the end of the request head (`\r\n\r\n`). GET/OPTIONS bodies are irrelevant,
    /// so the head is all the router needs.
    private func receiveHead(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.headLimit) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else {
                    connection.cancel()
                    return
                }
                var buffered = buffered
                if let data {
                    buffered.append(data)
                }
                if let headEnd = buffered.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(data: buffered[..<headEnd.lowerBound], encoding: .utf8) ?? ""
                    self.finish(connection, with: self.route(head: head))
                } else if error != nil || isComplete || buffered.count >= Self.headLimit {
                    self.finish(connection, with: nil)
                } else {
                    self.receiveHead(connection, buffered: buffered)
                }
            }
        }
    }

    private func route(head: String) -> LocalUsageAPI.Response {
        let (method, path) = Self.parseRequestLine(head)
        // Path is secret-free (the loopback API serves only normalized usage); Debug-only.
        AppLog.debug(.localAPI, "\(method) \(path)")
        return LocalUsageAPI.respond(method: method, path: path, state: state())
    }

    /// Parse the HTTP request line into `(method, path)`. Tolerates an empty/malformed head: a
    /// request that begins with `\r\n\r\n`, or carries invalid UTF-8 (decoded to `""` at the call
    /// site), yields no request line — which must route to a normal `404` rather than trap. The
    /// previous `head.split(...)[0]` force-index crashed the whole `@MainActor` menu-bar process on
    /// any such loopback payload. `nonisolated` + pure so it's unit-testable without the listener.
    nonisolated static func parseRequestLine(_ head: String) -> (method: String, path: String) {
        guard let requestLine = head.split(separator: "\r\n", maxSplits: 1).first else {
            return ("", "/")
        }
        let parts = requestLine.split(separator: " ")
        let method = parts.indices.contains(0) ? String(parts[0]) : ""
        let path = parts.indices.contains(1) ? String(parts[1]) : "/"
        return (method, path)
    }

    private func finish(_ connection: NWConnection, with response: LocalUsageAPI.Response?) {
        activeConnections -= 1
        if let response {
            Self.send(response, over: connection)
        } else {
            connection.cancel()
        }
    }

    private nonisolated static func send(_ response: LocalUsageAPI.Response, over connection: NWConnection) {
        let reason: String = switch response.status {
        case 200: "OK"
        case 204: "No Content"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 503: "Service Unavailable"
        default: "OK"
        }
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Methods: GET, OPTIONS\r\n"
        head += "Access-Control-Allow-Headers: Content-Type\r\n"
        head += "Connection: close\r\n"
        if let body = response.body {
            head += "Content-Type: application/json\r\n"
            head += "Content-Length: \(body.count)\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } else {
            head += "Content-Length: 0\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
