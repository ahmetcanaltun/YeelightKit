import Foundation

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
/// Neither replaces the other, so an app is expected to offer both.
///
/// The generator is a pure function of time, so a caller decides its own frame
/// rate and can drop frames without the animation drifting.
///
/// ```swift
/// let colors = SegmentEffect.sweep.colors(zones: 3, at: elapsed)
/// try await session.setSegmentColors(colors)
/// ```
public enum SegmentEffect: String, Sendable, CaseIterable {

    /// A bright band travelling along the light, its hue drifting between passes.
    case sweep
    /// The hue wheel spread across the sections and slid along.
    case rainbow
    /// One hue, brightening and dimming as a wave that ripples across the
    /// sections rather than pulsing them together.
    case pulse
    /// Alternating red and blue, swapping ends.
    case police

    /// How long one full cycle takes.
    public var period: Duration {
        switch self {
        case .sweep: return .milliseconds(2500)
        case .rainbow: return .seconds(6)
        case .pulse: return .seconds(4)
        case .police: return .milliseconds(1200)
        }
    }

    /// Colours for `zones` sections, `time` seconds into the effect.
    ///
    /// Index 0 is the first section. On a Monitor Light Bar that is the
    /// screen-left end, so an effect that moves from 0 upwards moves left to
    /// right.
    ///
    /// A `zones` of 1 is meaningful: a light with no segments still gets the
    /// animation, just without anything travelling.
    public func colors(zones: Int, at time: Double) -> [Int] {
        let count = max(1, zones)
        let phase = Self.cycle(time / period.seconds)

        return (0..<count).map { index in
            // Sections are treated as points at their own centres, so the two
            // ends of the light are half a section from 0 and 1 rather than
            // sitting exactly on them.
            let position = (Double(index) + 0.5) / Double(count)

            switch self {
            case .sweep:
                let distance = Self.wrappedDistance(from: position, to: phase)
                let inBand = max(0, 1 - distance / Self.bandWidth)
                return Self.color(hue: phase, value: inBand)

            case .rainbow:
                return Self.color(hue: Self.cycle(position + phase), value: 1)

            case .pulse:
                // Offsetting each section's phase turns a breath into a ripple.
                let wave = (sin(2 * .pi * (phase - position * 0.35)) + 1) / 2
                return Self.color(hue: phase, value: wave)

            case .police:
                let flipped = phase >= 0.5
                let isRed = (index % 2 == 0) != flipped
                return Self.color(hue: isRed ? 0 : Self.blueHue, value: 1)
            }
        }
    }

    // MARK: - Internals

    /// How much of the light the travelling band covers, either side of centre.
    /// Wide enough that three sections never all go dark between passes.
    private static let bandWidth = 0.45

    private static let blueHue = 2.0 / 3.0

    /// The dimmest a section is driven.
    ///
    /// Deliberately not black. Whether `0x000000` means "off" or "leave this
    /// section alone" is unsettled on the one device with segments, and an
    /// effect whose dark end silently froze on its last colour would look
    /// broken rather than dim. A very dark colour is unambiguous.
    private static let floor = 0.05

    private static func color(hue: Double, value: Double) -> Int {
        ColorConversion.rgb(hue: hue,
                            saturation: 1,
                            value: floor + (1 - floor) * min(1, max(0, value)))
    }

    /// Wraps into 0..<1, for negative inputs too.
    private static func cycle(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }

    /// Distance around a loop, so a band leaving one end arrives at the other.
    private static func wrappedDistance(from: Double, to: Double) -> Double {
        let direct = abs(from - to)
        return min(direct, 1 - direct)
    }
}

extension Duration {
    /// Seconds as a fraction, for maths that is easier in floating point than
    /// in the attosecond representation.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
