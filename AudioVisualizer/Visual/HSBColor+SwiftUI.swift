import SwiftUI

extension Color {
    init(_ hsb: HSBColor) {
        self.init(hue: hsb.hue, saturation: hsb.saturation, brightness: hsb.brightness)
    }
}

extension HSBColor {
    /// 色相環上を `delta` だけ回した色。彩度/明度はそのまま。
    func shiftingHue(by delta: Double) -> HSBColor {
        var hue = (self.hue + delta).truncatingRemainder(dividingBy: 1)
        if hue < 0 { hue += 1 }
        return HSBColor(hue: hue, saturation: saturation, brightness: brightness)
    }

    /// 明度/彩度を掛け率で調整した色。
    func adjusted(saturation saturationScale: Double = 1, brightness brightnessScale: Double = 1) -> HSBColor {
        HSBColor(
            hue: hue,
            saturation: min(1, max(0, saturation * saturationScale)),
            brightness: min(1, max(0, brightness * brightnessScale))
        )
    }

    /// 波形/バーの前景色。背景と同系色だと沈むので、色相を補色寄りにずらして明度を上げる。
    var accent: HSBColor {
        HSBColor(
            hue: (hue + 0.5).truncatingRemainder(dividingBy: 1),
            saturation: min(1, saturation * 0.6 + 0.25),
            brightness: min(1, brightness * 0.4 + 0.6)
        )
    }
}
