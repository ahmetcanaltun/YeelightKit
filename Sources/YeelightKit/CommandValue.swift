import Foundation

/// A single command parameter.
///
/// The protocol only ever carries integers and strings, so this is a closed set
/// rather than `Any` — which also keeps commands `Sendable` and lets them cross
/// actor boundaries safely.
public enum CommandValue: Sendable, Equatable {
    case int(Int)
    case string(String)

    var jsonValue: Any {
        switch self {
        case .int(let value): return value
        case .string(let value): return value
        }
    }
}

extension CommandValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension CommandValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension CommandValue {
    public init(_ effect: YeelightEffect) { self = .string(effect.rawValue) }
}
