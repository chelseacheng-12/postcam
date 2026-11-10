import SwiftUI
import UIKit

/// Shared ink. Camera chrome stays black, white, and the Camera-app yellow.
/// Vermilion is only the stamp denomination and the album accent.
enum PostcamColor {
    static let yellow = RGB(1.0, 0.839, 0.039)
    static let record = RGB(1.0, 0.231, 0.188)
    static let ink = RGB(0.165, 0.110, 0.078)
    static let vermilion = RGB(0.62, 0.165, 0.133)
    static let paper = RGB(0.988, 0.980, 0.965)
    /// Selected camera mode. Soft enough to sit with the stamp, strong enough to read on black.
    static let modePink = RGB(0.98, 0.67, 0.72)

    static var cameraYellow: Color { Color(rgb: yellow) }
    static var recordRed: Color { Color(rgb: record) }
    static var inkColor: Color { Color(rgb: ink) }
    static var vermilionColor: Color { Color(rgb: vermilion) }

    static var inkUI: UIColor { UIColor(rgb: ink) }
    static var vermilionUI: UIColor { UIColor(rgb: vermilion) }
    static var paperUI: UIColor { UIColor(rgb: paper) }
    static var modePinkColor: Color { Color(rgb: modePink) }
    static var haloUI: UIColor { UIColor(rgb: RGB(1, 0.99, 0.97), alpha: 0.92) }
    static var frameLineUI: UIColor { UIColor(red: 0.76, green: 0.70, blue: 0.62, alpha: 1) }

    struct RGB {
        var r, g, b: Double
        init(_ r: Double, _ g: Double, _ b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }
    }
}

extension Color {
    init(rgb: PostcamColor.RGB) {
        self.init(red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}

extension UIColor {
    convenience init(rgb: PostcamColor.RGB, alpha: Double = 1) {
        self.init(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: alpha)
    }
}

enum Haptic {
    static func shutter() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    static func record() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func select() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
