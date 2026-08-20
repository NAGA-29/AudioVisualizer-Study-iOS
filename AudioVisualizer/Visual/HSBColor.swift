import Foundation

/// SwiftUI に依存しない HSB 表現 (各成分 0.0〜1.0)。テストしやすくするために独立させている。
struct HSBColor: Equatable {
    var hue: Double
    var saturation: Double
    var brightness: Double

    static let idle = HSBColor(hue: 0.6, saturation: 0.4, brightness: 0.12)
}
