import CoreGraphics
import CoreImage
import Foundation

/// Flat 2D cel look from Sonny Boy: every region one flat color with a hard border, one hard cool
/// shadow tone, and thin dark outlines. `paint` works like this:
/// - The working-size frame is shrunk and median-filtered until photo texture is gone, then grown
///   to full resolution with an edge-preserving upsample guided by the full frame.
/// - That smooth image is snapped to a small palette (k-means, then `CIPalettize`), so regions are
///   flat and the borders between them are hard, pixel-sharp steps. A 3×3 median cleans stray
///   pixels along those borders.
/// - Shadows and outlines come from the palette regions, so they line up with the fills exactly.
/// `SonnyBoyScene` swaps skies and ground around them.
enum SonnyBoyStyle {
    enum Knob {
        /// Texture removal: the working frame is shrunk to this share and median-filtered
        /// `flattenPasses` times. Smaller and more passes paints over more detail.
        static let flattenScale: CGFloat = 0.45
        static let flattenPasses = 2
        static let flattenBlur: Double = 0.6
        /// Edge-preserving upsample. `upsampleLuma` is how different two sides of an edge must be
        /// to stay separate; lower keeps more shapes, higher paints over more of them.
        static let upsampleSpatial: Double = 2
        static let upsampleLuma: Double = 0.08
        /// Colors in the cel palette. More keeps more color variety; fewer is flatter and bolder.
        static let paletteSize = 14
        /// Share of working size the palette is learned from.
        static let paletteSampleScale: CGFloat = 0.3
        /// Share of last frame's palette kept, so colors do not jump.
        static let paletteKeep: CGFloat = 0.6
        /// 3×3 median passes on the snapped colors. Removes specks along region borders.
        static let cleanupPasses = 2

        /// Bright, clean, high-key grade.
        static let exposure: Double = 0.3
        static let vibrance: Double = 0.35
        static let saturation: Double = 1.18
        static let brightness: Double = 0.02
        static let contrast: Double = 1.04
        /// Slight cool cast in the light colors, like a painted background.
        static let coolLift: CGFloat = 0.03

        /// Hard cel shadows: palette regions darker than `shadowLevel` (linear luminance) are
        /// multiplied by `shadowTint`. No blur, so the shadow edge is the region edge.
        static let shadowLevel: Double = 0.075
        static let shadowTint = CIColor(red: 0.66, green: 0.72, blue: 0.92)

        static let colorKeep: CGFloat = 0.65

        /// Outlines, traced at full resolution on the palette regions, so only borders between
        /// clearly different regions get a line. `lineBlur` is only a light pre-smooth. Higher `lineThreshold`
        /// keeps fewer, stronger contours. `lineHysteresis` keeps last frame's lines with less edge strength,
        /// which is what holds them still while panning; nothing is blended or blurred over time.
        static let lineBlur: Double = 0.5
        static let lineIntensity: Double = 3.0
        static let lineThreshold: Double = 0.42
        static let lineHysteresis: Double = 0.16
        /// Blur on the finished line. 0 is a hard, crisp edge.
        static let lineSoften: Double = 0
        /// A second 3×3 median on the finished lines removes lone specks and keeps lines 2px and wider.
        static let despeckle = true
        /// Width, in full-resolution pixels, of the outline where sky, ground, and people meet.
        static let boundaryRadius: Double = 1

        /// Near-black ink with a cool cast, like the show's outlines.
        static let ink = CIColor(red: 0.10, green: 0.10, blue: 0.14)

        /// Saturated cobalt, deepest at the top of the window.
        static let skyTop = CIColor(red: 0.05, green: 0.27, blue: 0.80)
        static let skyLow = CIColor(red: 0.30, green: 0.58, blue: 0.96)
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

    /// Full-resolution fills, plus the snapped palette regions before grading and shadows.
    /// Outlines are traced on `regions`, so they sit exactly on fill borders.
    struct Layers {
        let fills: CIImage
        let regions: CIImage
    }

    /// `full` is the frame with its origin at zero; `small` is it at working resolution.
    /// `palette` carries the palette between frames. Leave both histories nil for a still.
    static func paint(full: CIImage, small: CIImage, history: CelHistory?, palette: FrameHistory?) -> Layers {
        let extent = full.extent
        let guide = IllustrationStyle.smoothedColor(small)
        var flat = flattened(guide)
        if let history {
            flat = history.color.blend(flat, keep: Knob.colorKeep)
        }
        let sharpGuide = full.clampedToExtent()
            .applyingFilter("CIMedianFilter")
            .cropped(to: extent)
        let structure = guidedUpsample(flat, guide: sharpGuide)

        var regions: CIImage
        if let colors = paletteImage(from: flat, history: palette) {
            regions = structure.applyingFilter("CIPalettize", parameters: [
                "inputPaletteImage": colors,
                "inputPerceptual": true
            ]).cropped(to: extent)
        } else {
            regions = structure.applyingFilter("CIColorPosterize", parameters: ["inputLevels": 6])
                .cropped(to: extent)
        }
        for _ in 0..<Knob.cleanupPasses {
            regions = regions.clampedToExtent()
                .applyingFilter("CIMedianFilter")
                .cropped(to: extent)
        }
        let fills = shaded(graded(regions), regions: regions)
        return Layers(fills: fills, regions: regions)
    }

    /// Flat regions with borders where the real edges are. Shrinking and median filtering wipe out
    /// texture; the guided upsample puts the outlines of shapes back without the texture.
    static func flattened(_ image: CIImage) -> CIImage {
        let tiny = IllustrationStyle.downscaled(image, scale: Knob.flattenScale)
        let tinyExtent = tiny.extent
        var region = tiny.clampedToExtent()
        for _ in 0..<max(Knob.flattenPasses, 1) {
            region = region.applyingFilter("CIMedianFilter")
        }
        region = region
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: Knob.flattenBlur])
            .cropped(to: tinyExtent)
        return guidedUpsample(region, guide: image)
    }

    /// Grows `small` to the size of `guide`, keeping its borders on the edges in `guide`.
    static func guidedUpsample(_ small: CIImage, guide: CIImage) -> CIImage {
        let extent = guide.extent
        let parameters: [String: Any] = [
            kCIInputImageKey: guide,
            "inputSmallImage": small.normalizedOrigin(),
            "inputSpatialSigma": Knob.upsampleSpatial,
            "inputLumaSigma": Knob.upsampleLuma
        ]
        guard let output = CIFilter(name: "CIEdgePreserveUpsampleFilter", parameters: parameters)?.outputImage else {
            return IllustrationStyle.upscaled(small, to: extent)
        }
        return output.cropped(to: extent)
    }

    /// `paletteSize` × 1 image of cel colors learned from `flat`. Seeded with last frame's palette,
    /// so each color keeps its slot and can be eased instead of jumping.
    static func paletteImage(from flat: CIImage, history: FrameHistory?) -> CIImage? {
        let sample = IllustrationStyle.downscaled(flat, scale: Knob.paletteSampleScale)
        let paletteExtent = CGRect(x: 0, y: 0, width: Knob.paletteSize, height: 1)
        var parameters: [String: Any] = [
            kCIInputImageKey: sample,
            kCIInputExtentKey: CIVector(cgRect: sample.extent),
            "inputCount": Knob.paletteSize,
            "inputPasses": history == nil ? 5 : 2,
            "inputPerceptual": true
        ]
        if let seed = history?.previous(matching: paletteExtent) {
            parameters["inputMeans"] = seed
        }
        guard let means = CIFilter(name: "CIKMeans", parameters: parameters)?.outputImage else { return nil }
        let box = means.extent.isInfinite || means.extent.isEmpty ? paletteExtent : means.extent
        let colors = means.settingAlphaOne(in: box).cropped(to: box)
        guard let history else { return colors }
        return history.blend(colors, keep: Knob.paletteKeep)
    }

    private static func graded(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let lift = Knob.coolLift
        return image
            .applyingFilter("CIExposureAdjust", parameters: ["inputEV": Knob.exposure])
            .applyingFilter("CIVibrance", parameters: ["inputAmount": Knob.vibrance])
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: Knob.saturation,
                kCIInputBrightnessKey: Knob.brightness,
                kCIInputContrastKey: Knob.contrast
            ])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 - lift, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0, y: 0, z: lift, w: 0)
            ])
            .cropped(to: extent)
    }

    /// Dark regions get one flat cool shadow tone. The mask is cut from the palette regions with
    /// no blur, so the shadow edge is exactly a region edge.
    private static func shaded(_ fills: CIImage, regions: CIImage) -> CIImage {
        let extent = fills.extent
        let luminance = regions.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
            kCIInputBrightnessKey: 0,
            kCIInputContrastKey: 1
        ]).cropped(to: extent)
        let lit = luminance.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": Knob.shadowLevel])
            .cropped(to: extent)
        let shadow = StableInk.affine(lit, scale: -1, bias: 1)
        let tint = CIImage(color: Knob.shadowTint).cropped(to: extent)
        let dark = tint.applyingFilter("CIMultiplyBlendMode", parameters: [
            kCIInputBackgroundImageKey: fills
        ]).cropped(to: extent)
        return dark.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: fills,
            kCIInputMaskImageKey: shadow
        ]).cropped(to: extent)
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
