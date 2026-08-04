//
//  ColorConversion.swift
//  YeelightKit
//

import Foundation

/// HSV <-> packed 0xRRGGBB conversion used by the Ambilight colour picker.
///
/// Lives outside the view layer so the maths can be exercised by unit tests —
/// the Yeelight protocol only speaks packed RGB integers, while the picker
/// works in hue/saturation.
public enum ColorConversion {

    /// Converts hue and saturation (both 0...1) at full brightness into the
    /// packed 0xRRGGBB integer the `set_rgb` family of commands expects.
    public static func rgb(hue: Double, saturation: Double) -> Int {
        rgb(hue: hue, saturation: saturation, value: 1)
    }

    /// As above, but dimming the colour itself rather than the light.
    ///
    /// Brightness is normally the device's own `set_bright`, which applies to
    /// the whole light. An animation that wants one section brighter than
    /// another has no such command, so the darkness has to be carried in the
    /// colour.
    public static func rgb(hue: Double, saturation: Double, value: Double) -> Int {
        let v = min(1, max(0, value))
        let h = min(1, max(0, hue))
        let s = min(1, max(0, saturation))

        let c = v * s
        let x = c * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c

        var r: Double = 0, g: Double = 0, b: Double = 0
        let hue6 = h * 6

        if hue6 < 1 {
            r = c; g = x; b = 0
        } else if hue6 < 2 {
            r = x; g = c; b = 0
        } else if hue6 < 3 {
            r = 0; g = c; b = x
        } else if hue6 < 4 {
            r = 0; g = x; b = c
        } else if hue6 < 5 {
            r = x; g = 0; b = c
        } else {
            r = c; g = 0; b = x
        }

        let red = Int(((r + m) * 255).rounded())
        let green = Int(((g + m) * 255).rounded())
        let blue = Int(((b + m) * 255).rounded())
        return (red << 16) | (green << 8) | blue
    }

    /// A colour temperature as the packed RGB the colour commands take.
    ///
    /// Lights that accept `set_ct_abx` do this themselves; this is for the ones
    /// that do not. A background channel is RGB-only on every device seen so
    /// far, so warming it with the evening means computing what 2700 K looks
    /// like rather than asking for it.
    ///
    /// Daniel Tanner's piecewise fit to the blackbody curve, which is accurate
    /// to a couple of percent over the range any lamp offers and is the same
    /// approximation every lighting project ends up using. Clamped to
    /// 1000–40000 K because the fit's logarithms are only defined there — the
    /// device's own range (1700–6500 K) sits comfortably inside it.
    public static func rgb(kelvin: Int) -> Int {
        let temperature = Double(min(40000, max(1000, kelvin))) / 100

        let red: Double
        if temperature <= 66 {
            red = 255
        } else {
            red = 329.698727446 * pow(temperature - 60, -0.1332047592)
        }

        let green: Double
        if temperature <= 66 {
            green = 99.4708025861 * log(temperature) - 161.1195681661
        } else {
            green = 288.1221695283 * pow(temperature - 60, -0.0755148492)
        }

        let blue: Double
        if temperature >= 66 {
            blue = 255
        } else if temperature <= 19 {
            // Below roughly 1900 K there is no blue in the fire at all.
            blue = 0
        } else {
            blue = 138.5177312231 * log(temperature - 10) - 305.0447927307
        }

        func byte(_ value: Double) -> Int { Int(min(255, max(0, value)).rounded()) }
        return (byte(red) << 16) | (byte(green) << 8) | byte(blue)
    }

    /// Inverse of `rgb(hue:saturation:)`, discarding brightness.
    public static func hueSaturation(fromRGB rgb: Int) -> (hue: Double, saturation: Double) {
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0

        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC

        var h: Double = 0
        let s: Double = maxC == 0 ? 0 : delta / maxC

        if delta > 0 {
            if maxC == r {
                h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == g {
                h = (b - r) / delta + 2
            } else {
                h = (r - g) / delta + 4
            }
            h = h / 6
            if h < 0 { h += 1 }
        }

        return (h, s)
    }
}
