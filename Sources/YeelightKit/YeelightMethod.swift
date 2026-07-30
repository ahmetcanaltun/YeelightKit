import Foundation

/// Control methods defined by the Yeelight inter-operation spec.
///
/// Sending a method the device did not advertise in its `support` list is
/// rejected outright, so check ``YeelightDevice/supports(_:)`` first.
public enum YeelightMethod: String, Sendable, CaseIterable {
    case getProp = "get_prop"
    case setPower = "set_power"
    case toggle
    case setBright = "set_bright"
    case setColorTemperature = "set_ct_abx"
    case setRGB = "set_rgb"
    case setHSV = "set_hsv"
    case setDefault = "set_default"
    case setName = "set_name"
    case setScene = "set_scene"
    case startColorFlow = "start_cf"
    case stopColorFlow = "stop_cf"
    case adjustBright = "adjust_bright"
    case adjustColorTemperature = "adjust_ct"
    case adjustColor = "adjust_color"
    case cronAdd = "cron_add"
    case cronGet = "cron_get"
    case cronDelete = "cron_del"
    case setMusic = "set_music"

    case backgroundSetPower = "bg_set_power"
    case backgroundToggle = "bg_toggle"
    case backgroundSetBright = "bg_set_bright"
    case backgroundSetColorTemperature = "bg_set_ct_abx"
    case backgroundSetRGB = "bg_set_rgb"
    case backgroundSetHSV = "bg_set_hsv"
    case backgroundSetScene = "bg_set_scene"
    case backgroundStartColorFlow = "bg_start_cf"
    case backgroundStopColorFlow = "bg_stop_cf"
}

/// How a change should be applied.
public enum YeelightEffect: String, Sendable {
    /// Jump straight to the value; `duration` is ignored.
    case sudden
    /// Ramp to the value over `duration`.
    case smooth
}

/// Properties readable with `get_prop`.
///
/// An unrecognised name comes back as an empty string rather than an error, so
/// asking for a property the device does not have is harmless.
public enum YeelightProperty: String, Sendable, CaseIterable {
    case power
    /// On devices with a background light this is the *main* light, while
    /// `power` reports the device as a whole. Notifications carry only this one.
    case mainPower = "main_power"
    case bright
    case colorTemperature = "ct"
    case rgb
    case hue
    case saturation = "sat"
    case colorMode = "color_mode"
    case name
    /// "1" while a colour flow is running on the device.
    case flowing
    /// The running flow's `count,action,expression`, useful for diagnostics.
    case flowParameters = "flow_params"

    case backgroundPower = "bg_power"
    case backgroundBright = "bg_bright"
    case backgroundColorTemperature = "bg_ct"
    case backgroundRGB = "bg_rgb"
    case backgroundHue = "bg_hue"
    case backgroundSaturation = "bg_sat"
    case backgroundColorMode = "bg_lmode"
    case backgroundFlowing = "bg_flowing"
    case backgroundFlowParameters = "bg_flow_params"
}
