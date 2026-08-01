import XCTest
@testable import YeelightKit

/// The segment effects are pure generators, so everything about them can be
/// checked here — which matters, because the only other way to see one is to
/// point a camera at a light bar.
final class SegmentEffectTests: XCTestCase {

    private let zones = 3 // what the Monitor Light Bar Pro has

    private var everyEffect: [SegmentEffect] {
        SegmentEffect.Pattern.allCases.map { SegmentEffect(pattern: $0) }
    }

    func testEveryPatternFillsExactlyTheSectionsItWasAskedFor() {
        for effect in everyEffect {
            for count in [1, 3, 8] {
                XCTAssertEqual(effect.colors(zones: count, at: 0.4).count, count,
                               "\(effect.pattern.rawValue) at \(count) zones")
            }
        }
    }

    /// A light with no segments still gets the animation, as one colour.
    func testASingleZoneIsMeaningful() {
        for effect in everyEffect {
            XCTAssertEqual(effect.colors(zones: 1, at: 1.1).count, 1)
            XCTAssertEqual(effect.colors(zones: 0, at: 1.1).count, 1, "zero must not mean no output")
        }
    }

    /// Whether `0x000000` switches a section off or leaves it on its last
    /// colour is unsettled on the only device with segments, so no effect may
    /// depend on the answer.
    func testNoSectionIsEverSentBlack() {
        for effect in everyEffect {
            for step in 0..<200 {
                let time = Double(step) * 0.05
                for color in effect.colors(zones: zones, at: time) {
                    XCTAssertNotEqual(color, 0, "\(effect.pattern.rawValue) went black at \(time)s")
                }
            }
        }
    }

    func testColoursStayInsideTwentyFourBits() {
        for pattern in SegmentEffect.Pattern.allCases {
            for palette in Palette.all {
                let effect = SegmentEffect(pattern: pattern, palette: palette)
                for step in 0..<40 {
                    for color in effect.colors(zones: zones, at: Double(step) * 0.1) {
                        XCTAssertGreaterThanOrEqual(color, 0)
                        XCTAssertLessThanOrEqual(color, 0xFFFFFF)
                    }
                }
            }
        }
    }

    /// Frames are a function of time alone, so a caller may drop frames or
    /// change its rate without the animation drifting — and two runs of the
    /// same effect look identical, which the random-looking patterns have to
    /// honour as much as the others.
    func testTheSameMomentAlwaysProducesTheSameFrame() {
        for effect in everyEffect {
            XCTAssertEqual(effect.colors(zones: zones, at: 3.7),
                           effect.colors(zones: zones, at: 3.7),
                           effect.pattern.rawValue)
        }
    }

    // MARK: - The knobs

    /// The whole point of the parameter model: one speed control that means the
    /// same thing everywhere.
    func testSpeedShortensTheCycleForEveryPattern() {
        for pattern in SegmentEffect.Pattern.allCases {
            let slow = SegmentEffect(pattern: pattern, speed: 0).period.seconds
            let mid = SegmentEffect(pattern: pattern, speed: 0.5).period.seconds
            let fast = SegmentEffect(pattern: pattern, speed: 1).period.seconds

            XCTAssertGreaterThan(slow, mid, pattern.rawValue)
            XCTAssertGreaterThan(mid, fast, pattern.rawValue)
            XCTAssertEqual(slow, pattern.slowestPeriod.seconds, accuracy: 0.01)
            XCTAssertEqual(fast, pattern.fastestPeriod.seconds, accuracy: 0.01)
        }
    }

    /// Interpolated as a ratio rather than a difference, so the middle of the
    /// slider is the middle of what the eye sees.
    func testTheMiddleOfTheSpeedRangeIsTheGeometricMiddle() {
        let pattern = SegmentEffect.Pattern.comet
        let mid = SegmentEffect(pattern: pattern, speed: 0.5).period.seconds
        let expected = (pattern.slowestPeriod.seconds * pattern.fastestPeriod.seconds).squareRoot()
        XCTAssertEqual(mid, expected, accuracy: 0.01)
    }

    func testOutOfRangeKnobsAreClamped() {
        let effect = SegmentEffect(pattern: .comet, speed: 5, intensity: -3)
        XCTAssertEqual(effect.period.seconds,
                       SegmentEffect.Pattern.comet.fastestPeriod.seconds, accuracy: 0.01)
        XCTAssertEqual(effect.colors(zones: zones, at: 0.2).count, zones)
    }

    /// A longer trail means more of the light is lit at any moment. Without
    /// this the intensity slider could be wired to nothing and no test would
    /// notice.
    func testIntensityLengthensACometsTrail() {
        func litSections(intensity: Double) -> Int {
            let effect = SegmentEffect(pattern: .comet, intensity: intensity)
            let colors = effect.colors(zones: 8, at: 0)
            let luminance = colors.map { ($0 >> 16 & 0xFF) + ($0 >> 8 & 0xFF) + ($0 & 0xFF) }
            let brightest = luminance.max() ?? 0
            return luminance.filter { $0 > brightest / 4 }.count
        }
        XCTAssertGreaterThan(litSections(intensity: 1), litSections(intensity: 0))
    }

    /// A pattern that ignores the knob says so, so a UI can hide it rather than
    /// show a control that does nothing.
    func testAPatternThatIgnoresIntensitySaysSo() {
        XCTAssertFalse(SegmentEffect.Pattern.alternate.usesIntensity)
        let quiet = SegmentEffect(pattern: .alternate, intensity: 0).colors(zones: zones, at: 0.1)
        let loud = SegmentEffect(pattern: .alternate, intensity: 1).colors(zones: zones, at: 0.1)
        XCTAssertEqual(quiet, loud)

        for pattern in SegmentEffect.Pattern.allCases where pattern.usesIntensity {
            let a = SegmentEffect(pattern: pattern, intensity: 0).colors(zones: 8, at: 0.3)
            let b = SegmentEffect(pattern: pattern, intensity: 1).colors(zones: 8, at: 0.3)
            XCTAssertNotEqual(a, b, "\(pattern.rawValue) claims to use intensity")
        }
    }

    // MARK: - Movement

    /// The point of the whole feature: the bright part has to *move*, and move
    /// in section order, or the light is just changing colour.
    func testACometTravelsAlongTheLight() {
        let effect = SegmentEffect(pattern: .comet)
        let period = effect.period.seconds

        var wraps = 0
        var previous = Self.brightestSection(of: effect, at: 0)
        // Stopping short of a full period: at exactly one period the head is
        // back where it started, which would read as a wrap.
        for step in 1..<40 {
            let current = Self.brightestSection(of: effect, at: Double(step) / 40 * period)
            if current < previous { wraps += 1 }
            previous = current
        }
        XCTAssertLessThanOrEqual(wraps, 1, "the head should travel one way, not jitter")
        XCTAssertGreaterThan(previous, 0, "the head never left the first section")
    }

    /// A scanner is a comet that comes back, and that difference is the whole
    /// reason both exist.
    func testAScannerTurnsAroundInsteadOfWrapping() {
        let effect = SegmentEffect(pattern: .scanner)
        let period = effect.period.seconds

        let start = Self.brightestSection(of: effect, at: 0)
        let middle = Self.brightestSection(of: effect, at: period / 2)
        let end = Self.brightestSection(of: effect, at: period * 0.95)

        XCTAssertGreaterThan(middle, start)
        XCTAssertLessThan(end, middle, "it should be on its way back")
    }

    func testChaseLightsOneSectionAtATime() {
        let effect = SegmentEffect(pattern: .chase, intensity: 1)
        let colors = effect.colors(zones: zones, at: 0)
        let luminance = colors.map { ($0 >> 16 & 0xFF) + ($0 >> 8 & 0xFF) + ($0 & 0xFF) }
        let brightest = luminance.max() ?? 0
        XCTAssertEqual(luminance.filter { $0 == brightest }.count, 1)
    }

    /// Alternate has to differ between neighbours and swap ends, or it is not
    /// the thing anyone means by police lights.
    func testAlternateSwapsEnds() {
        let effect = SegmentEffect.police
        let first = effect.colors(zones: 2, at: 0)
        let second = effect.colors(zones: 2, at: effect.period.seconds / 2)

        XCTAssertNotEqual(first[0], first[1], "the two ends should differ")
        XCTAssertEqual(first[0], second[1])
        XCTAssertEqual(first[1], second[0])
    }

    /// A rainbow that shows one colour at a time is a colour flow, which the
    /// device can already run by itself. The sections differing is the reason
    /// any of this runs in the app at all.
    func testPlasmaShowsDifferentColoursAtOnce() {
        let colors = SegmentEffect(pattern: .plasma, palette: .rainbow).colors(zones: zones, at: 1.3)
        XCTAssertEqual(Set(colors).count, zones)
    }

    private static func brightestSection(of effect: SegmentEffect, at time: Double) -> Int {
        let colors = effect.colors(zones: 8, at: time)
        let luminance = colors.map { ($0 >> 16 & 0xFF) + ($0 >> 8 & 0xFF) + ($0 & 0xFF) }
        return luminance.firstIndex(of: luminance.max()!)!
    }
}

final class PaletteTests: XCTestCase {

    func testAPaletteWrapsRatherThanSticking() {
        let start = Palette.rainbow.stop(at: 0)
        let wrapped = Palette.rainbow.stop(at: 1)
        XCTAssertEqual(start.hue, wrapped.hue, accuracy: 0.001)
        XCTAssertEqual(Palette.rainbow.stop(at: 1.25).hue,
                       Palette.rainbow.stop(at: 0.25).hue, accuracy: 0.001)
    }

    /// Hue is a wheel, so interpolating from red to magenta must not sweep
    /// backwards through every other colour on the way.
    func testHueTakesTheShortWayRound() {
        let palette = Palette(name: "test", stops: [.init(hue: 0.95), .init(hue: 0.05)])
        let middle = palette.stop(at: 0.25).hue
        // Halfway between 0.95 and 1.05 is 1.0, which is red — not 0.5, cyan.
        let distanceFromRed = min(abs(middle), abs(1 - middle))
        XCTAssertLessThan(distanceFromRed, 0.02, "got \(middle)")
    }

    func testEveryPaletteIsUsable() {
        for palette in Palette.all {
            XCTAssertFalse(palette.stops.isEmpty, palette.name)
            for step in 0...20 {
                let stop = palette.stop(at: Double(step) / 20)
                XCTAssertTrue((0...1).contains(stop.saturation), palette.name)
                XCTAssertTrue((0...1).contains(stop.value), palette.name)
            }
        }
    }

    /// Fire reads as fire because it darkens towards the bottom of the palette,
    /// not only because it is red.
    func testTheFirePaletteRampsItsBrightness() {
        XCTAssertLessThan(Palette.fire.stop(at: 0).value, Palette.fire.stop(at: 0.6).value)
    }
}
