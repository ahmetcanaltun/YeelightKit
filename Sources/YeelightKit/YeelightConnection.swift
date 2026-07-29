import Foundation
import Network

/// A control connection to one Yeelight device.
///
/// An actor rather than a class: the protocol requires correlating replies to
/// in-flight requests by id, and actor isolation gives that for free instead of
/// the lock-and-serial-queue arrangement a shared class would need.
///
/// ## Limits the protocol imposes
///
/// - A device accepts **at most 4 simultaneous TCP connections** and silently
///   refuses to answer beyond that. Always ``close()`` a connection you are
///   done with; an abandoned one keeps its slot until the device is power
///   cycled, which looks exactly like a broken light.
/// - Each connection has a quota of **60 commands per minute**. Anything that
///   animates must pace itself; see ``minimumCommandInterval``.
/// - `set_bright`, `set_ct_abx` and `set_rgb` are only accepted **while the
///   light is on**.
public actor YeelightConnection {

    /// Slowest safe cadence for repeated commands: 60 per minute per connection.
    public static let minimumCommandInterval: Duration = .seconds(1)

    public let device: YeelightDevice

    private var connection: NWConnection?
    private var nextRequestID = 0
    private var pending: [Int: CheckedContinuation<[String], Error>] = [:]
    private var buffer = Data()

    private var stateContinuations: [UUID: AsyncStream<YeelightState>.Continuation] = [:]
    private var lastState = YeelightState()

    /// How long to wait for a reply before giving up.
    public var timeout: Duration = .seconds(5)

    public init(device: YeelightDevice) {
        self.device = device
    }

    deinit {
        // An NWConnection lives until cancelled; dropping the reference alone
        // would leak one of the device's four slots.
        connection?.cancel()
    }

    // MARK: - Lifecycle

    public var isConnected: Bool {
        connection?.state == .ready
    }

    public func connect() async throws {
        if connection?.state == .ready { return }
        close()

        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = 5
            tcp.noDelay = true
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(device.host),
            port: NWEndpoint.Port(integerLiteral: device.port),
            using: parameters
        )
        self.connection = connection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = OSAllocatedUnfairLockBox(false)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.testAndSet() { continuation.resume() }
                case .failed(let error):
                    if resumed.testAndSet() {
                        continuation.resume(throwing: YeelightError.connectionFailed(error.localizedDescription))
                    }
                case .cancelled:
                    if resumed.testAndSet() {
                        continuation.resume(throwing: YeelightError.notConnected)
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }

        receiveLoop(on: connection)
    }

    /// Cancels the connection and releases the device slot it holds.
    public func close() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil

        for continuation in pending.values {
            continuation.resume(throwing: YeelightError.notConnected)
        }
        pending.removeAll()
        buffer.removeAll()
    }

    // MARK: - State

    /// Emits a merged snapshot every time the device reports a change.
    ///
    /// Notifications are partial, so each element is the full known state
    /// rather than only what changed.
    public func states() -> AsyncStream<YeelightState> {
        AsyncStream { continuation in
            let id = UUID()
            stateContinuations[id] = continuation
            continuation.yield(lastState)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateContinuation(id) }
            }
        }
    }

    private func removeStateContinuation(_ id: UUID) {
        stateContinuations[id] = nil
    }

    private func publish(_ update: YeelightState) {
        lastState = lastState.merging(update)
        for continuation in stateContinuations.values {
            continuation.yield(lastState)
        }
    }

    /// Reads the device's current state. Unsupported properties come back empty
    /// and are simply left `nil`.
    @discardableResult
    public func refreshState() async throws -> YeelightState {
        let names = YeelightProperty.allCases.map(\.rawValue)
        let values = try await send(.getProp, parameters: names.map { .string($0) })

        var properties: [String: String] = [:]
        for (name, value) in zip(names, values) {
            properties[name] = value
        }

        publish(YeelightState(properties: properties))
        return lastState
    }

    // MARK: - Sending

    /// Sends a raw command and waits for the matching reply.
    ///
    /// Throws ``YeelightError/unsupportedMethod(_:)`` without touching the
    /// network when the device never advertised the method.
    /// - Returns: the strings of the device's `result` array, e.g. `["ok"]`.
    @discardableResult
    public func send(_ method: YeelightMethod, parameters: [CommandValue] = []) async throws -> [String] {
        guard device.supports(method) else {
            throw YeelightError.unsupportedMethod(method)
        }
        guard let connection, connection.state == .ready else {
            throw YeelightError.notConnected
        }

        nextRequestID += 1
        let id = nextRequestID

        let payload: [String: Any] = ["id": id,
                                      "method": method.rawValue,
                                      "params": parameters.map(\.jsonValue)]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8),
              let line = (text + "\r\n").data(using: .utf8) else {
            throw YeelightError.encodingFailed
        }

        return try await withThrowingTaskGroup(of: [String].self) { group in
            group.addTask { [timeout] in
                try await Task.sleep(for: timeout)
                throw YeelightError.timeout
            }
            group.addTask {
                try await self.awaitReply(id: id, sending: line, on: connection)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw YeelightError.timeout }
            return result
        }
    }

    private func awaitReply(id: Int, sending payload: Data, on connection: NWConnection) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { await self?.fail(id: id, with: .connectionFailed(error.localizedDescription)) }
            })
        }
    }

    private func fail(id: Int, with error: YeelightError) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    // MARK: - Receiving

    private nonisolated func receiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                Task { await self.handleDisconnect(reason: error.localizedDescription) }
                return
            }
            if let data, !data.isEmpty {
                Task { await self.ingest(data) }
            }
            if isComplete {
                Task { await self.handleDisconnect(reason: "closed by device") }
            } else {
                self.receiveLoop(on: connection)
            }
        }
    }

    private func handleDisconnect(reason: String) {
        for continuation in pending.values {
            continuation.resume(throwing: YeelightError.connectionFailed(reason))
        }
        pending.removeAll()
    }

    private func ingest(_ data: Data) {
        buffer.append(data)

        // Messages are newline terminated but may arrive coalesced or split.
        while let range = buffer.range(of: Data("\r\n".utf8)) {
            let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard !line.isEmpty else { continue }
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }

        if let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                continuation.resume(throwing: YeelightError.deviceRejected(
                    code: error["code"] as? Int ?? -1,
                    message: error["message"] as? String ?? "unknown"
                ))
            } else {
                // Results are always an array of scalars; normalise to strings so
                // nothing untyped escapes the actor.
                let values = (message["result"] as? [Any] ?? []).map { value -> String in
                    if let text = value as? String { return text }
                    if let number = value as? NSNumber { return number.stringValue }
                    return ""
                }
                continuation.resume(returning: values)
            }
            return
        }

        // Unsolicited state change.
        if message["method"] as? String == "props",
           let params = message["params"] as? [String: Any] {
            var properties: [String: String] = [:]
            for (key, value) in params {
                properties[key] = String(describing: value)
            }
            publish(YeelightState(properties: properties))
        }
    }
}

/// Minimal lock used only to make a connection continuation resume once.
private final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private var value: Bool
    private let lock = NSLock()

    init(_ value: Bool) { self.value = value }

    /// Returns true exactly once.
    func testAndSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}
