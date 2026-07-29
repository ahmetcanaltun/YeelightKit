import Foundation

public enum YeelightError: Error, Sendable, Equatable {
    /// The command could not be encoded as JSON.
    case encodingFailed
    /// The device did not answer within the timeout.
    case timeout
    case notConnected
    case connectionFailed(String)
    /// The device answered with an error object.
    case deviceRejected(code: Int, message: String)
    /// The device did not advertise this method in its support list, so it
    /// would reject it. Checked locally to save a round trip.
    case unsupportedMethod(YeelightMethod)
    /// A value fell outside the range the protocol allows.
    case invalidArgument(String)
}

extension YeelightError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode the command"
        case .timeout:
            return "The device did not answer in time"
        case .notConnected:
            return "Not connected to the device"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .deviceRejected(let code, let message):
            return "Device rejected the command (\(code)): \(message)"
        case .unsupportedMethod(let method):
            return "This device does not support \(method.rawValue)"
        case .invalidArgument(let detail):
            return "Invalid argument: \(detail)"
        }
    }
}
