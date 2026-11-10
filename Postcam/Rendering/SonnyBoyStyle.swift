import CoreGraphics
import CoreImage
import Foundation

/// Flat 2D cel look from Sonny Boy: bold clean color, almost no shading, thin dark outlines.
/// `cel` is the pass for everything that is kept (people, objects). `SonnyBoyScene` swaps
/// skies and ground around it.
enum SonnyBoyStyle {
    enum Knob {
        static let posterizeLevels: Double = 5
        /// Almost flat. A little remains so a face is not a single chip of color.
        static let gradientKeep: Double = 0.1
        static let saturation: Double = 1.38
        static let brightness: Double = 0.04
        static let contrast: Double = 1.12
        static let colorKeep: CGFloat = 0.65
        static let fillKeep: CGFloat = 0.5

        static let lineBlur: Double = 1.4
        static let lineIntensity: Double = 2.6
        static let lineThreshold: Double = 0.34
        static let lineHysteresis: Double = 0.14
        static let lineSoften: Double = 0.5

        /// Near-black ink with a cool cast, like the show's outlines.
        static let ink = CIColor(red: 0.10, green: 0.10, blue: 0.14)

        static let skyTop = CIColor(red: 0.04, green: 0.24, blue: 0.74)
        static let skyLow = CIColor(red: 0.16, green: 0.46, blue: 0.93)
        static let cloud = CIColor(red: 1, green: 1, blue: 1)
        static let cloudShade = CIColor(red: 0.80, green: 0.87, blue: 0.97)
        static let blank = CIColor(red: 0.97, green: 0.96, blue: 0.92)
        static let seaFar = CIColor(red: 0.05, green: 0.42, blue: 0.68)
        static let seaNear = CIColor(red: 0.10, green: 0.62, blue: 0.74)
        static let sand = CIColor(red: 0.95, green: 0.85, blue: 0.57)
        static let grass = CIColor(red: 0.36, green: 0.63, blue: 0.30)
    }

    static var inkSettings: StableInk.Settings {
        StableInk.Settings(
            blur: Knob.lineBlur,
            intensity: Knob.lineIntensity,
            threshold: Knob.lineThreshold,
            hysteresis: Knob.lineHysteresis
        )
    }

    /// `small` is already at working resolution with its origin at zero.
    static func cel(_ small: CIImage, history: CelHistory?) -> CIImage {
        let extent = small.extent
        var smoothed = IllustrationStyle.smoothedColor(small)
        if let history {
            smoothed = history.color.blend(smoothed, keep: Knob.colorKeep)
        }

        let flat = smoothed.applyingFilter("CIColorPosterize", parameters: [
            "inputLevels": Knob.posterizeLevels
        ]).cropped(to: extent)
        let mixed = flat.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: smoothed,
            kCIInputTimeKey: Knob.gradientKeep
        ]).cropped(to: extent)
        var fills = mixed.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: Knob.saturation,
            kCIInputBrightnessKey: Knob.brightness,
            kCIInputContrastKey: Knob.contrast
        ]).cropped(to: extent)
        if let history {
            fills = history.fills.blend(fills, keep: Knob.fillKeep)
        }

        let previous = history?.lines.previous(matching: extent)
        let mask = StableInk.mask(from: smoothed, previous: previous, settings: inkSettings)
        let stored = history?.lines.commit(mask) ?? mask
        let ink = StableInk.ink(stored.cropped(to: extent), color: Knob.ink, soften: Knob.lineSoften)
        return ink.applyingFilter("CIMultiplyBlendMode", parameters: [
            kCIInputBackgroundImageKey: fills
        ]).cropped(to: extent)
    }

    /// Vertical two-color gradient across `extent`.
    static func gradient(_ extent: CGRect, bottom: CIColor, top: CIColor) -> CIImage {
        let parameters: [String: Any] = [
            "inputPoint0": CIVector(x: extent.midX, y: extent.minY),
            "inputPoint1": CIVector(x: extent.midX, y: extent.maxY),
            "inputColor0": bottom,
            "inputColor1": top
        ]
        guard let output = CIFilter(name: "CILinearGradient", parameters: parameters)?.outputImage else {
            return CIImage(color: bottom).cropped(to: extent)
        }
        return output.cropped(to: extent)
    }

    /// Black below `from`, white above `to` (or the reverse when `rising` is false).
    static func ramp(_ extent: CGRect, from: CGFloat, to: CGFloat, rising: Bool) -> CIImage {
        let black = CIColor(red: 0, green: 0, blue: 0)
        let white = CIColor(red: 1, green: 1, blue: 1)
        let parameters: [String: Any] = [
            "inputPoint0": CIVector(x: extent.midX, y: from),
            "inputPoint1": CIVector(x: extent.midX, y: max(to, from + 1)),
            "inputColor0": rising ? black : white,
            "inputColor1": rising ? white : black
        ]
        guard let output = CIFilter(name: "CILinearGradient", parameters: parameters)?.outputImage else {
            return CIImage(color: rising ? black : white).cropped(to: extent)
        }
        return output.cropped(to: extent)
    }

    /// Repeats `tile` across `extent`, scaled to `tileWidth` and slid right by `shift` points.
    static func tiled(_ tile: CIImage, over extent: CGRect, tileWidth: CGFloat, shift: CGFloat, y: CGFloat) -> CIImage {
        let source = tile.normalizedOrigin()
        guard source.extent.width > 1, source.extent.height > 1 else {
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        }
        let scale = tileWidth / source.extent.width
        let width = source.extent.width * scale
        let offset = width > 1 ? shift.truncatingRemainder(dividingBy: width) : 0
        return source
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .applyingFilter("CIAffineTile")
            .transformed(by: CGAffineTransform(translationX: extent.minX + offset, y: y))
            .cropped(to: extent)
    }
}

/// Hand-drawn pieces for the swapped sky and ground, generated once per framing from a seed.
/// Clouds are two-tone and flat. Waves and tufts are sparse strokes. Tiles are transparent.
struct SonnyBoyTextures {
    let clouds: CIImage
    let waves: CIImage
    let tufts: CIImage

    init(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        clouds = SonnyBoyTextures.drawClouds(&rng)
        waves = SonnyBoyTextures.drawWaves(&rng)
        tufts = SonnyBoyTextures.drawTufts(&rng)
    }

    private static func canvas(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func finish(_ context: CGContext, width: Int, height: Int) -> CIImage {
        guard let image = context.makeImage() else {
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
                .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return CIImage(cgImage: image)
    }

    private static func drawClouds(_ rng: inout SplitMix64) -> CIImage {
        let width = 768
        let height = 512
        guard let context = canvas(width: width, height: height) else {
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
                .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        let count = 3 + Int(rng.unit() * 2.99)
        for index in 0..<count {
            let slot = CGFloat(width) / CGFloat(count)
            let cloudWidth = slot * (0.62 + rng.unit() * 0.3)
            let left = slot * CGFloat(index) + (slot - cloudWidth) * 0.5
            let base = CGFloat(height) * (0.12 + rng.unit() * 0.55)
            let puffs = 4 + Int(rng.unit() * 3.99)
            var circles: [CGRect] = []
            for puff in 0..<puffs {
                let t = (CGFloat(puff) + 0.5) / CGFloat(puffs)
                let arch = 1 - abs(t - 0.5) * 1.4
                let radius = cloudWidth * (0.12 + 0.12 * arch + rng.unit() * 0.05)
                let x = left + cloudWidth * t
                let y = base + radius * (0.35 + rng.unit() * 0.3)
                circles.append(CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            }
            let flatBottom = CGRect(x: left, y: base, width: cloudWidth, height: cloudWidth * 0.12)

            let shade = SonnyBoyStyle.Knob.cloudShade
            context.setFillColor(red: shade.red, green: shade.green, blue: shade.blue, alpha: 1)
            for circle in circles {
                context.fillEllipse(in: circle.offsetBy(dx: 0, dy: -circle.height * 0.08))
            }
            context.fill(flatBottom.offsetBy(dx: 0, dy: -flatBottom.height * 0.4))

            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            for circle in circles {
                context.fillEllipse(in: circle.insetBy(dx: circle.width * 0.04, dy: circle.height * 0.04)
                    .offsetBy(dx: 0, dy: circle.height * 0.05))
            }
        }
        return finish(context, width: width, height: height)
    }

    private static func drawWaves(_ rng: inout SplitMix64) -> CIImage {
        let width = 512
        let height = 256
        guard let context = canvas(width: width, height: height) else {
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
                .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.85)
        context.setLineWidth(2.5)
        context.setLineCap(.round)
        let rows = 6
        for row in 0..<rows {
            let y = CGFloat(height) * (CGFloat(row) + 0.5) / CGFloat(rows)
            let strokes = 3 + Int(rng.unit() * 2.99)
            for _ in 0..<strokes {
                let start = rng.unit() * CGFloat(width - 60)
                let length = 30 + rng.unit() * 40
                context.beginPath()
                context.move(to: CGPoint(x: start, y: y))
                context.addCurve(
                    to: CGPoint(x: start + length, y: y),
                    control1: CGPoint(x: start + length * 0.33, y: y + 7),
                    control2: CGPoint(x: start + length * 0.66, y: y - 7)
                )
                context.strokePath()
            }
        }
        return finish(context, width: width, height: height)
    }

    private static func drawTufts(_ rng: inout SplitMix64) -> CIImage {
        let width = 512
        let height = 256
        guard let context = canvas(width: width, height: height) else {
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
                .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(red: 0.18, green: 0.40, blue: 0.16, alpha: 0.9)
        context.setLineWidth(2)
        context.setLineCap(.round)
        for _ in 0..<26 {
            let x = 10 + rng.unit() * CGFloat(width - 20)
            let y = 10 + rng.unit() * CGFloat(height - 30)
            let size = 6 + rng.unit() * 6
            context.beginPath()
            context.move(to: CGPoint(x: x - size * 0.6, y: y + size))
            context.addLine(to: CGPoint(x: x, y: y))
            context.addLine(to: CGPoint(x: x + size * 0.6, y: y + size))
            context.strokePath()
        }
        return finish(context, width: width, height: height)
    }
}

/// Small, fast, seedable generator so a framing always gets the same variation.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// 0 ..< 1
    mutating func unit() -> CGFloat {
        CGFloat(Double(next() >> 11) / 9_007_199_254_740_992.0)
    }
}
