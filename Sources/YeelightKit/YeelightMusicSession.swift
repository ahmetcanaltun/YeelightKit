import Foundation
import Network

/// A quota-free control channel, for anything that needs to update the light
/// many times a second — matching screen colour, reacting to audio.
///
/// The protocol calls this "music mode" and inverts the usual direction: we
/// listen, hand the device our address, and **the device dials in**. Once it
/// has, commands on that socket are not counted against the 60-per-minute quota
/// that applies to a normal connection.
///
/// Two consequences worth knowing:
///
/// - **The device stops reporting state** while music mode is active, so a UI
///   driving this should show what it last commanded rather than wait to be
///   told.
/// - Commands are **fire-and-forget**. Waiting for a reply per frame would
///   defeat the point, so failures surface as the session ending rather than as
///   a thrown error per command.
///
/// Not every model supports it: of the two devices this package was developed
/// against, only the colour bulb advertises `set_music`. Check
/// ``YeelightDevice/supports(_:)`` first.
public actor YeelightMusicSession {

    public enum State: Sendable, Equatable {
        case idle
        case waitingForDevice
        case active
        case ended(String)
    }

    public private(set) var state: State = .idle

    private let device: YeelightDevice
    private let control: YeelightConnection

    private var listener: NWListener?
    private var deviceConnection: NWConnection?
    private var nextRequestID = 0

    /// - Parameter control: an already-connected normal connection, used only to
    ///   send the `set_music` handshake.
    public init(device: YeelightDevice, control: YeelightConnection) {
        self.device = device
        self.control = control
    }

    deinit {
        deviceConnection?.cancel()
        listener?.cancel()
    }

    public var isActive: Bool { state == .active }

    // MARK: - Lifecycle

    /// Opens the listener, tells the device where to find us, and waits for it
    /// to connect.
    ///
    /// - Parameter timeout: how long to wait for the device to dial back.
    public func start(timeout: Duration = .seconds(5)) async throws {
        guard device.supports(.setMusic) else {
            throw YeelightError.unsupportedMethod(.setMusic)
        }
        guard let host = LocalAddress.forReaching(host: device.host, port: device.port) else {
            throw YeelightError.connectionFailed("could not determine a local address reachable by \(device.host)")
        }

        stop()

        let listener = try NWListener(using: .tcp)
        self.listener = listener

        // The connection handler has to be installed *before* `start()`. A
        // listener started without one does not sit there waiting for a peer —
        // it fails immediately with EINVAL, which reads as "invalid argument"
        // and looks nothing like the ordering mistake it actually is.
        let handoff = ConnectionHandoff()
        listener.newConnectionHandler = { handoff.arrived($0) }

        let port = try await startListening(listener)
        state = .waitingForDevice

        do {
            // The device connects back to this address, so it has to be the one
            // it can actually route to — not merely "our IP".
            try await control.send(.setMusic, parameters: [.int(1), .string(host), .int(Int(port))])
            try await waitForDevice(handoff, timeout: timeout)
        } catch {
            // The device may already believe it is in music mode, in which case
            // it has stopped reporting state and is waiting on a peer that will
            // never arrive. Tell it to come back out.
            await stopAndNotifyDevice()
            throw error
        }

        state = .active
    }

    /// Ends music mode and lets the device resume reporting state.
    public func stop() {
        deviceConnection?.cancel()
        deviceConnection = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        if state != .idle { state = .idle }
    }

    /// Tells the device to leave music mode over the normal channel too.
    ///
    /// Closing the socket is enough on its own, but being explicit avoids
    /// leaving the device waiting on a peer that is gone.
    public func stopAndNotifyDevice() async {
        stop()
        _ = try? await control.send(.setMusic, parameters: [.int(0)])
    }

    // MARK: - Sending

    /// Writes a command without waiting for a reply.
    ///
    /// Throws only when the session is not active; a write that fails ends the
    /// session, which is reported through ``state``.
    public func send(_ method: YeelightMethod, parameters: [CommandValue] = []) throws {
        guard state == .active, let connection = deviceConnection else {
            throw YeelightError.notConnected
        }
        guard device.supports(method) else {
            throw YeelightError.unsupportedMethod(method)
        }

        nextRequestID += 1
        let payload: [String: Any] = ["id": nextRequestID,
                                      "method": method.rawValue,
                                      "params": parameters.map(\.jsonValue)]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8),
              let line = (text + "\r\n").data(using: .utf8) else {
            throw YeelightError.encodingFailed
        }

        connection.send(content: line, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { await self?.end(reason: error.localizedDescription) }
        })
    }

    /// Convenience for the common case of pushing a colour at a high rate.
    public func setColor(rgb: Int, brightness: Int? = nil) throws {
        // Colour lives on whichever endpoint the device advertised: the main
        // light on a bulb, the background light on a light bar.
        guard let method = device.colorMethod else {
            throw YeelightError.unsupportedMethod(.setRGB)
        }
        // "sudden" with no duration: a transition would smear consecutive frames
        // into each other.
        try send(method, parameters: [.int(rgb), .string(YeelightEffect.sudden.rawValue), .int(0)])

        if let brightness {
            let brightnessMethod: YeelightMethod = method == .backgroundSetRGB
                ? .backgroundSetBright : .setBright
            try send(brightnessMethod, parameters: [
                .int(brightness), .string(YeelightEffect.sudden.rawValue), .int(0)
            ])
        }
    }

    // MARK: - Internals

    private func startListening(_ listener: NWListener) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else { return }
                    if resumed.claim() { continuation.resume(returning: port) }
                case .failed(let error):
                    if resumed.claim() {
                        continuation.resume(throwing: YeelightError.connectionFailed(error.localizedDescription))
                    }
                case .cancelled:
                    if resumed.claim() {
                        continuation.resume(throwing: YeelightError.notConnected)
                    }
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    /// Waits for the device to dial in on the listener that ``start(timeout:)``
    /// already armed.
    ///
    /// The connection travels through `handoff` rather than out of the task
    /// group: `NWConnection` only became `Sendable` in macOS 14, and this
    /// package still supports 13.
    private func waitForDevice(_ handoff: ConnectionHandoff, timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(for: timeout)
                throw YeelightError.timeout
            }
            group.addTask {
                // Cancellation has to reach this one. A task group waits for
                // every child before it rethrows, so a continuation that only
                // ever resumes from `newConnectionHandler` would hang the whole
                // group the moment the timeout wins.
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        handoff.attach(continuation)
                    }
                } onCancel: {
                    handoff.fail(CancellationError())
                }
            }
            defer { group.cancelAll() }
            try await group.next()
        }

        guard let connection = handoff.connection else { throw YeelightError.timeout }
        deviceConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                Task { await self?.end(reason: error.localizedDescription) }
            case .cancelled:
                Task { await self?.end(reason: "device closed the music channel") }
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    private func end(reason: String) {
        guard state == .active || state == .waitingForDevice else { return }
        stop()
        state = .ended(reason)
    }
}

/// Carries the incoming connection from `NWListener`'s callback to the waiting
/// task, resuming exactly once whichever of the two arrives first — the device
/// dialling in, or cancellation.
private final class ConnectionHandoff: @unchecked Sendable {
    private var stored: NWConnection?
    private var continuation: CheckedContinuation<Void, Error>?
    private var outcome: Result<Void, Error>?
    private var finished = false
    private let lock = NSLock()

    /// The connection the device opened, once ``arrived(_:)`` has run. The lock
    /// is what publishes it to the reading task.
    var connection: NWConnection? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// Cancellation can land before the continuation exists, so an outcome that
    /// arrives first is held until someone is there to receive it.
    func attach(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let outcome {
            lock.unlock()
            continuation.resume(with: outcome)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func arrived(_ connection: NWConnection) {
        finish(.success(()), connection: connection)
    }

    func fail(_ error: Error) {
        finish(.failure(error), connection: nil)
    }

    private func finish(_ outcome: Result<Void, Error>, connection: NWConnection?) {
        lock.lock()
        guard !finished else { return lock.unlock() }
        finished = true
        stored = connection
        let waiting = continuation
        continuation = nil
        if waiting == nil { self.outcome = outcome }
        lock.unlock()
        waiting?.resume(with: outcome)
    }
}

/// Guards a continuation against a second resume from another callback.
private final class ResumeOnce: @unchecked Sendable {
    private var used = false
    private let lock = NSLock()

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
