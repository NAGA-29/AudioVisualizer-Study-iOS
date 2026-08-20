import SwiftUI

extension Color {
    init(_ hsb: HSBColor) {
        self.init(hue: hsb.hue, saturation: hsb.saturation, brightness: hsb.brightness)
    }
}

extension HSBColor {
    /// 波形/バーの前景色。背景と同系色だと沈むので、色相を補色寄りにずらして明度を上げる。
    var accent: HSBColor {
        HSBColor(
            hue: (hue + 0.5).truncatingRemainder(dividingBy: 1),
            saturation: min(1, saturation * 0.6 + 0.25),
            brightness: min(1, brightness * 0.4 + 0.6)
        )
    }
}
