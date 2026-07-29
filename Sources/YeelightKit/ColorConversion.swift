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
        let v: Double = 1.0 // Full brightness
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
