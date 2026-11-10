import CoreGraphics
import CoreImage
import Foundation

/// Flat 2D cel look from Sonny Boy: bold clean color, almost no shading, thin dark outlines.
/// `cel` makes the flat fills at working resolution. `lineMask` traces the outlines at full
/// resolution, so they stay thin and sharp instead of being scaled up with the fills.
/// `SonnyBoyScene` swaps skies and ground around them.
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

        /// Outlines, traced on the full-resolution frame. A 3×3 median removes sensor noise without
        /// moving edges; `lineBlur` is only a light pre-smooth. Higher `lineThreshold` keeps fewer,
        /// stronger contours. `lineHysteresis` keeps last frame's lines with less edge strength,
        /// which is what holds them still while panning; nothing is blended or blurred over time.
        static let lineBlur: Double = 0.8
        static let lineIntensity: Double = 3.0
        static let lineThreshold: Double = 0.4
        static let lineHysteresis: Double = 0.16
        /// Blur on the finished line. 0 is a hard, crisp edge.
        static let lineSoften: Double = 0
        /// A second 3×3 median on the finished lines removes lone specks and keeps lines 2px and wider.
        static let despeckle = true
        /// Width, in full-resolution pixels, of the outline where sky, ground, and people meet.
        static let boundaryRadius: Double = 1

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

    /// Flat fills, no lines. `small` is already at working resolution with its origin at zero.
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
        return fills
    }

    /// White where there is an outline, black elsewhere, at the resolution of `full`.
    /// `history` carries the binary lines between frames for hysteresis. Leave it nil for a still.
    static func lineMask(_ full: CIImage, history: FrameHistory?) -> CIImage {
        let extent = full.extent
        let clean = full.clampedToExtent()
            .applyingFilter("CIMedianFilter")
            .cropped(to: extent)
        let previous = history?.previous(matching: extent)
        var mask = StableInk.mask(from: clean, previous: previous, settings: inkSettings)
        if Knob.despeckle {
            mask = mask.clampedToExtent()
                .applyingFilter("CIMedianFilter")
                .cropped(to: extent)
        }
        return history?.commit(mask) ?? mask
    }

    /// Multiplies `mask` lines in ink over `image`.
    static func inked(_ image: CIImage, lines mask: CIImage) -> CIImage {
        let extent = image.extent
        let ink = StableInk.ink(mask.cropped(to: extent), color: Knob.ink, soften: Knob.lineSoften)
        return ink.applyingFilter("CIMultiplyBlendMode", parameters: [
            kCIInputBackgroundImageKey: image
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
/// Clouds are painted cumulus from `SonnyBoyArt`. Waves and tufts are sparse strokes. Tiles are transparent.
struct SonnyBoyTextures {
    let clouds: CIImage
    let waves: CIImage
    let tufts: CIImage

    init(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        clouds = SonnyBoyArt.paintedClouds(&rng)
        waves = SonnyBoyTextures.drawWaves(&rng)
        tufts = SonnyBoyTextures.drawTufts(&rng)
    }

    static func canvas(width: Int, height: Int) -> CGContext? {
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

    static func finish(_ context: CGContext, width: Int, height: Int) -> CIImage {
        guard let image = context.makeImage() else {
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
                .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return CIImage(cgImage: image)
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
