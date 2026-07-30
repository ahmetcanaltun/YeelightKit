import Foundation

/// A programmed sequence of light changes that the **device** runs by itself.
///
/// This is what the spec calls its most powerful command, and it is almost
/// always the right way to animate. Driving an animation from the app means one
/// command per step against a 60-per-minute quota; a flow is a single command,
/// so it can step as fast as 50ms, keeps running after the app quits, and can
/// put the light back the way it was when it stops.
///
/// ```swift
/// try await connection.start(.police)          // runs until stopped
/// try await connection.stopColorFlow()         // restores the previous state
/// ```
public struct ColorFlow: Sendable, Equatable {

    /// What a single step does.
    public enum Transition: Sendable, Equatable {
        /// Fade to a packed 0xRRGGBB colour. `brightness` of `nil` leaves the
        /// current brightness alone.
        case color(rgb: Int, brightness: Int? = nil)
        /// Fade to a colour temperature in Kelvin.
        case colorTemperature(kelvin: Int, brightness: Int? = nil)
        /// Hold the current state.
        case wait

        /// Protocol mode number.
        var mode: Int {
            switch self {
            case .color: return 1
            case .colorTemperature: return 2
            case .wait: return 7
            }
        }

        var value: Int {
            switch self {
            case .color(let rgb, _): return rgb
            case .colorTemperature(let kelvin, _): return kelvin
            case .wait: return 0 // ignored
            }
        }

        /// -1 tells the device to keep the brightness it already has.
        var brightnessValue: Int {
            switch self {
            case .color(_, let brightness), .colorTemperature(_, let brightness):
                return brightness ?? -1
            case .wait:
                return -1 // ignored
            }
        }
    }

    public struct Step: Sendable, Equatable {
        /// Time to reach the target, or to wait. The device rejects anything
        /// under 50ms.
        public var duration: Duration
        public var transition: Transition

        public init(duration: Duration = .milliseconds(500), _ transition: Transition) {
            self.duration = duration
            self.transition = transition
        }

        var milliseconds: Int {
            let components = duration.components
            return Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
        }
    }

    /// What the light does once the flow ends. Irrelevant for an endless flow.
    public enum Completion: Int, Sendable {
        /// Go back to the state from before the flow started.
        case restorePrevious = 0
        /// Stay wherever the last step left it.
        case keepLast = 1
        case turnOff = 2
    }

    public var steps: [Step]

    /// Number of individual state changes before stopping. `0` runs forever,
    /// which is the usual choice — note this counts *steps*, not passes through
    /// the sequence.
    public var changeCount: Int

    public var completion: Completion

    public init(steps: [Step], changeCount: Int = 0, completion: Completion = .restorePrevious) {
        self.steps = steps
        self.changeCount = changeCount
        self.completion = completion
    }

    /// Minimum step the firmware accepts.
    public static let minimumStepDuration: Duration = .milliseconds(50)

    /// The `flow_expression` string: flat groups of
    /// `duration, mode, value, brightness`.
    public var expression: String {
        steps.flatMap { step in
            [step.milliseconds, step.transition.mode,
             step.transition.value, step.transition.brightnessValue]
        }
        .map(String.init)
        .joined(separator: ",")
    }

    func validated() throws -> ColorFlow {
        guard !steps.isEmpty else {
            throw YeelightError.invalidArgument("a colour flow needs at least one step")
        }
        guard changeCount >= 0 else {
            throw YeelightError.invalidArgument("changeCount cannot be negative")
        }
        for step in steps {
            guard step.duration >= Self.minimumStepDuration else {
                throw YeelightError.invalidArgument("step duration must be at least 50ms")
            }
            let brightness = step.transition.brightnessValue
            guard brightness == -1 || (1...100).contains(brightness) else {
                throw YeelightError.invalidArgument("step brightness must be 1...100, got \(brightness)")
            }
        }
        return self
    }
}

// MARK: - Ready-made flows

extension ColorFlow {

    /// Alternating red and blue at the fastest useful rate.
    public static var police: ColorFlow {
        ColorFlow(steps: [
            Step(duration: .milliseconds(300), .color(rgb: 0xFF0000, brightness: 100)),
            Step(duration: .milliseconds(300), .color(rgb: 0x0000FF, brightness: 100))
        ])
    }

    /// A slow cycle through the hue wheel.
    public static var rainbow: ColorFlow {
        let colors = [0xFF0000, 0xFF8000, 0xFFFF00, 0x00FF00, 0x00FFFF, 0x0000FF, 0x8000FF]
        return ColorFlow(steps: colors.map {
            Step(duration: .milliseconds(800), .color(rgb: $0, brightness: 100))
        })
    }

    /// Warm, dim breathing — the light equivalent of a candle.
    public static var candle: ColorFlow {
        ColorFlow(steps: [
            Step(duration: .milliseconds(800), .colorTemperature(kelvin: 1700, brightness: 30)),
            Step(duration: .milliseconds(600), .colorTemperature(kelvin: 2000, brightness: 15)),
            Step(duration: .milliseconds(900), .colorTemperature(kelvin: 1700, brightness: 25))
        ])
    }

    /// Fades to warm and dim over `duration`, then turns the light off. Runs
    /// once rather than forever.
    public static func sunset(over duration: Duration = .seconds(600)) -> ColorFlow {
        let half = duration / 2
        return ColorFlow(
            steps: [
                Step(duration: half, .colorTemperature(kelvin: 2700, brightness: 40)),
                Step(duration: half, .colorTemperature(kelvin: 1700, brightness: 1))
            ],
            changeCount: 2,
            completion: .turnOff
        )
    }
}
