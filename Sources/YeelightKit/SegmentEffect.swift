import Foundation

/// A palette an effect draws its colours from.
///
/// Separating the palette from the movement is what the addressable-LED
/// projects settle on, and it is why they ship a hundred effects without a
/// hundred sets of hand-tuned colours: any pattern can be drawn in any palette,
/// so the two multiply instead of adding.
public struct Palette: Sendable, Equatable {

    /// A colour at a position along the palette, in HSV so a pattern can dim it
    /// without leaving the palette.
    public struct Stop: Sendable, Equatable {
        public var hue: Double
        public var saturation: Double
        public var value: Double

        public init(hue: Double, saturation: Double = 1, value: Double = 1) {
            self.hue = hue
            self.saturation = saturation
            self.value = value
        }
    }

    /// Identifies the palette, and is what a UI keys its label on.
    public let name: String
    public let stops: [Stop]

    public init(name: String, stops: [Stop]) {
        self.name = name
        self.stops = stops
    }

    /// The colour at `position` (0...1), interpolated between stops.
    ///
    /// The palette wraps, so a pattern that walks off the end arrives back at
    /// the start rather than sticking.
    public func stop(at position: Double) -> Stop {
        guard stops.count > 1 else { return stops.first ?? Stop(hue: 0, saturation: 0) }

        let wrapped = position - position.rounded(.down)
        let scaled = wrapped * Double(stops.count)
        let index = min(stops.count - 1, Int(scaled))
        let next = (index + 1) % stops.count
        let fraction = scaled - Double(index)

        let a = stops[index], b = stops[next]
        // Hue takes the short way round, or a red-to-magenta step would sweep
        // backwards through the whole wheel.
        var delta = b.hue - a.hue
        if delta > 0.5 { delta -= 1 } else if delta < -0.5 { delta += 1 }

        return Stop(hue: a.hue + delta * fraction,
                    saturation: a.saturation + (b.saturation - a.saturation) * fraction,
                    value: a.value + (b.value - a.value) * fraction)
    }
}

extension Palette {
    public static let rainbow = Palette(name: "rainbow", stops: (0..<6).map {
        Stop(hue: Double($0) / 6)
    })

    public static let ocean = Palette(name: "ocean", stops: [
        Stop(hue: 0.60), Stop(hue: 0.50, saturation: 0.9), Stop(hue: 0.66), Stop(hue: 0.45, saturation: 0.8)
    ])

    /// Dark red through orange to a pale yellow, the shape every fire effect
    /// uses: the value ramp is what makes embers read as embers.
    public static let fire = Palette(name: "fire", stops: [
        Stop(hue: 0.00, saturation: 1, value: 0.25),
        Stop(hue: 0.03, saturation: 1, value: 0.7),
        Stop(hue: 0.09, saturation: 1, value: 1),
        Stop(hue: 0.13, saturation: 0.55, value: 1)
    ])

    public static let forest = Palette(name: "forest", stops: [
        Stop(hue: 0.28), Stop(hue: 0.35, saturation: 0.85), Stop(hue: 0.22, saturation: 0.95)
    ])

    public static let sunset = Palette(name: "sunset", stops: [
        Stop(hue: 0.95, saturation: 0.85), Stop(hue: 0.02), Stop(hue: 0.08), Stop(hue: 0.12, saturation: 0.8)
    ])

    public static let ice = Palette(name: "ice", stops: [
        Stop(hue: 0.52, saturation: 0.45), Stop(hue: 0.58, saturation: 0.7), Stop(hue: 0.62, saturation: 0.35)
    ])

    public static let party = Palette(name: "party", stops: [
        Stop(hue: 0.00), Stop(hue: 0.85), Stop(hue: 0.66), Stop(hue: 0.33)
    ])

    /// Two stops, so patterns that alternate between the ends of a palette come
    /// out as the thing everyone means by "police".
    public static let police = Palette(name: "police", stops: [
        Stop(hue: 0.00), Stop(hue: 2.0 / 3.0)
    ])

    public static let all: [Palette] = [
        .rainbow, .ocean, .fire, .forest, .sunset, .ice, .party, .police
    ]

    /// Looks a palette up by ``name``, for restoring a stored choice.
    public static func named(_ name: String) -> Palette? {
        all.first { $0.name == name }
    }
}

/// An animation generated frame by frame, one colour per section of the light.
///
/// The counterpart to ``ColorFlow``, and the trade between them is exact:
///
/// - A `ColorFlow` runs **on the device**. One command, unaffected by the
///   command quota, and it keeps going after the app quits — but it drives the
///   whole light as a single colour, because the protocol has no per-segment
///   flow and no way to define one.
/// - This runs **here**. It can colour each section differently, which is the
///   only way to make light travel along a bar, but it needs a quota-free
///   channel to send at all — and it stops when the app does.
///
/// ## Why it is three knobs and not thirty constants
///
/// Every pattern takes the same ``speed`` and ``intensity`` and any
/// ``Palette``, rather than carrying its own tuned numbers. That is the shape
/// the addressable-LED projects converged on, and the reason is practical:
/// nobody can pick the one right speed for a comet, because the right speed
/// depends on the light, the room and the person. So the pattern says what its
/// knobs mean, ships a default that is not embarrassing, and lets them be
/// moved.
///
/// ``intensity`` deliberately means something different per pattern — trail
/// length on a comet, spark rate on fire, how many sections are lit on twinkle.
/// A pattern that has no use for it says so with ``usesIntensity``, so a UI can
/// hide the control rather than show one that does nothing.
///
/// The generator is a pure function of time, so a caller picks its own frame
/// rate and a dropped frame does not make the animation drift.
///
/// ```swift
/// var effect = SegmentEffect(pattern: .comet, palette: .ocean)
/// effect.speed = 0.8
/// try await session.setSegmentColors(effect.colors(zones: 3, at: elapsed))
/// ```
public struct SegmentEffect: Sendable, Equatable {

    /// How the light moves. What colour it moves in is the palette's business.
    public enum Pattern: String, Sendable, CaseIterable {
        /// A bright head travelling in one direction, trailing off behind it.
        case comet
        /// The same head, but bouncing off both ends instead of wrapping.
        case scanner
        /// One section at a time, stepping along. The oldest LED effect there is.
        case chase
        /// Neighbouring sections take opposite ends of the palette and swap.
        case alternate
        /// Sections light at random and fade.
        case twinkle
        /// Flickering embers, brightest low down and cooling as they rise.
        case fire
        /// Two slow waves crossing, so the colour drifts without a beat.
        case plasma
        /// Everything brightens and dims together, rippling across the sections.
        case breathe

        /// Where the default speed sits between ``slowestPeriod`` and
        /// ``fastestPeriod``, chosen so each pattern looks like itself out of
        /// the box.
        var defaultSpeed: Double {
            switch self {
            case .comet: return 0.55
            case .scanner: return 0.5
            case .chase: return 0.45
            case .alternate: return 0.7
            case .twinkle: return 0.5
            case .fire: return 0.6
            case .plasma: return 0.25
            case .breathe: return 0.3
            }
        }

        var defaultIntensity: Double {
            switch self {
            case .comet: return 0.5      // trail length
            case .scanner: return 0.45   // trail length
            case .chase: return 0.7      // how dark the unlit sections go
            case .alternate: return 0.5  // unused
            case .twinkle: return 0.5    // how many are lit at once
            case .fire: return 0.55      // spark rate
            case .plasma: return 0.6     // how far apart the sections drift
            case .breathe: return 0.7    // how deep the dip goes
            }
        }

        /// Whether ``SegmentEffect/intensity`` does anything here.
        public var usesIntensity: Bool { self != .alternate }

        /// The palette that suits this pattern when nothing else is chosen.
        public var defaultPalette: Palette {
            switch self {
            case .fire: return .fire
            case .alternate: return .police
            case .plasma, .breathe: return .ocean
            default: return .rainbow
            }
        }

        /// One cycle at ``speed`` 0 and at 1. A pattern's slowest has to be
        /// genuinely slow — a plasma at four seconds is a strobe, not a plasma.
        var slowestPeriod: Duration {
            switch self {
            case .comet, .scanner, .chase: return .seconds(12)
            case .alternate: return .seconds(4)
            case .twinkle: return .seconds(8)
            case .fire: return .seconds(3)
            case .plasma: return .seconds(60)
            case .breathe: return .seconds(20)
            }
        }

        var fastestPeriod: Duration {
            switch self {
            case .comet, .scanner, .chase: return .milliseconds(600)
            case .alternate: return .milliseconds(300)
            case .twinkle: return .milliseconds(700)
            case .fire: return .milliseconds(400)
            case .plasma: return .seconds(6)
            case .breathe: return .seconds(2)
            }
        }
    }

    public var pattern: Pattern
    public var palette: Palette
    /// 0 slowest, 1 fastest.
    public var speed: Double
    /// 0...1, meaning per pattern. See ``Pattern/usesIntensity``.
    public var intensity: Double

    public init(pattern: Pattern,
                palette: Palette? = nil,
                speed: Double? = nil,
                intensity: Double? = nil) {
        self.pattern = pattern
        self.palette = palette ?? pattern.defaultPalette
        self.speed = speed ?? pattern.defaultSpeed
        self.intensity = intensity ?? pattern.defaultIntensity
    }

    /// How long one cycle takes at the current ``speed``.
    ///
    /// Interpolated on a log scale, because speed is heard as a ratio: halfway
    /// between one second and twelve should feel like the middle, and linearly
    /// that lands at six and a half, which does not.
    public var period: Duration {
        let slow = pattern.slowestPeriod.seconds
        let fast = pattern.fastestPeriod.seconds
        let t = min(1, max(0, speed))
        return .seconds(slow * pow(fast / slow, t))
    }

    /// Colours for `zones` sections, `time` seconds into the effect.
    ///
    /// Index 0 is the first section. On a Monitor Light Bar that is the
    /// screen-left end, so a pattern moving from 0 upwards moves left to right.
    ///
    /// A `zones` of 1 is meaningful: a light with no segments still gets the
    /// animation, just without anything travelling.
    public func colors(zones: Int, at time: Double) -> [Int] {
        let count = max(1, zones)
        let cycles = time / period.seconds
        let phase = Self.cycle(cycles)
        let level = min(1, max(0, intensity))

        return (0..<count).map { index in
            // Sections are points at their own centres, so the ends of the
            // light sit half a section in from 0 and 1 rather than on them.
            let position = (Double(index) + 0.5) / Double(count)

            switch pattern {
            case .comet:
                let distance = Self.wrappedDistance(from: position, to: phase)
                return color(at: phase, brightness: Self.head(distance, trail: level))

            case .scanner:
                // A triangle wave instead of a sawtooth: the head reaches the
                // end and comes back rather than reappearing at the start.
                let sweep = phase < 0.5 ? phase * 2 : (1 - phase) * 2
                let distance = abs(position - sweep)
                return color(at: sweep, brightness: Self.head(distance, trail: level))

            case .chase:
                let lit = Int(phase * Double(count)) % count
                let brightness = index == lit ? 1 : (1 - level)
                return color(at: position, brightness: brightness)

            case .alternate:
                let flipped = phase >= 0.5
                let end = (index % 2 == 0) != flipped ? 0.0 : 0.5
                return color(at: end, brightness: 1)

            case .twinkle:
                // Each section gets its own moment in the cycle, fixed by a
                // hash rather than a random number so a frame is reproducible.
                let turn = Int(cycles.rounded(.down))
                let mine = Self.noise(index, turn)
                let window = 0.2 + 0.7 * level
                let distance = abs(phase - mine)
                let brightness = max(0, 1 - distance / (window / 2))
                return color(at: mine, brightness: brightness)

            case .fire:
                // Fire2012's shape, at three cells: a bed of embers that cools
                // along the light, plus sparks landing at random.
                let step = Int(cycles * 8)
                let flicker = Self.noise(index, step)
                let cooling = position * 0.45
                let spark = flicker < level * 0.35 ? 0.5 : 0.0
                let heat = min(1, max(0.12, 0.55 + spark + flicker * 0.35 - cooling))
                return color(at: heat, brightness: heat)

            case .plasma:
                let a = sin(2 * .pi * (position * (0.5 + level) + phase))
                let b = sin(2 * .pi * (position * (1.5 + level) - phase * 1.3))
                return color(at: (a + b) / 4 + 0.5, brightness: 1)

            case .breathe:
                // Offsetting each section turns a breath into a ripple.
                let wave = (sin(2 * .pi * (phase - position * 0.35)) + 1) / 2
                return color(at: phase, brightness: 1 - level + level * wave)
            }
        }
    }

    // MARK: - Internals

    /// The dimmest a section is driven.
    ///
    /// Deliberately not black. Whether `0x000000` means "off" or "leave this
    /// section alone" is unsettled on the one device with segments, and an
    /// effect whose dark end silently froze on its last colour would look
    /// broken rather than dim. A very dark colour is unambiguous.
    private static let floor = 0.05

    private func color(at position: Double, brightness: Double) -> Int {
        let stop = palette.stop(at: position)
        let scaled = stop.value * min(1, max(0, brightness))
        return ColorConversion.rgb(hue: stop.hue,
                                   saturation: stop.saturation,
                                   value: Self.floor + (1 - Self.floor) * scaled)
    }

    /// A travelling head: full at the centre, fading over a trail whose length
    /// is the intensity.
    private static func head(_ distance: Double, trail: Double) -> Double {
        let width = 0.12 + 0.5 * trail
        return max(0, 1 - distance / width)
    }

    /// Wraps into 0..<1, for negative inputs too.
    private static func cycle(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }

    /// Distance around a loop, so a head leaving one end arrives at the other.
    private static func wrappedDistance(from: Double, to: Double) -> Double {
        let direct = abs(from - to)
        return min(direct, 1 - direct)
    }

    /// Deterministic 0...1 noise.
    ///
    /// Not `random()`: a frame has to depend only on its inputs, or the same
    /// moment of the same effect would differ between two runs and no test
    /// could pin any of it down.
    static func noise(_ a: Int, _ b: Int) -> Double {
        var x = UInt64(bitPattern: Int64(a &* 73_856_093)) ^ UInt64(bitPattern: Int64(b &* 19_349_663))
        x ^= x >> 33
        x = x &* 0xFF51_AFD7_ED55_8CCD
        x ^= x >> 33
        x = x &* 0xC4CE_B9FE_1A85_EC53
        x ^= x >> 33
        return Double(x % 1_000_000) / 1_000_000
    }
}

// MARK: - Ready-made effects

extension SegmentEffect {
    /// The pattern at its own defaults, which is what a UI offers first.
    public static func preset(_ pattern: Pattern) -> SegmentEffect {
        SegmentEffect(pattern: pattern)
    }

    public static var police: SegmentEffect { SegmentEffect(pattern: .alternate, palette: .police) }
}

extension Duration {
    /// Seconds as a fraction, for maths that is easier in floating point than
    /// in the attosecond representation.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
