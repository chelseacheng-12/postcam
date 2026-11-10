import CoreImage
import CoreGraphics

/// Colored-pencil treatment used only inside the stamp.
///
/// Colors are simplified into a few soft regions. Each region is drawn as pencil strokes on paper:
/// a fixed hatch texture, mostly vertical, laid down more densely where the color is darker, over a
/// pale wash of the same color. Outlines are soft, doubled, slightly wobbly pencil lines in a
/// darker shade of the color they border, not black ink.
/// Live frames pass a `CelHistory` so color, fills, and lines carry over from the last frame
/// instead of being recomputed from camera noise. Stills pass nil. The hatch, grain, and wobble
/// textures are made once and never move, so nothing crawls while the camera pans.
/// Heavy passes run at `workScale` so a 1080p preview can stay near 30fps.
enum IllustrationStyle {
    enum Knob {
        /// Resolution of the smoothing, stroke, and line passes, relative to the frame.
        static let workScale: CGFloat = 0.5

        /// Edge-preserving smooth before the colors are simplified. A median pass runs first.
        /// Sonny Boy shares these three.
        static let smoothNoise: Double = 0.04
        static let smoothSharpness: Double = 0.35
        /// Extra blur on the color that gets posterized. Removes the speckle that made bands crawl.
        static let colorBlur: Double = 1.2

        /// Share of the previous frame kept, 0...1. Higher is calmer, with a little trail on fast pans.
        static let colorKeep: CGFloat = 0.65
        static let fillKeep: CGFloat = 0.5

        /// Posterize steps per channel. Fewer steps give larger, flatter pencil regions.
        static let posterizeLevels: Double = 5
        /// 0 is fully flat regions. Higher keeps gentle gradients in sky and road.
        static let gradientKeep: Double = 0.2
        /// Below 1 is softer and more natural, as pencil is.
        static let saturation: Double = 0.9
        static let brightness: Double = 0.04
        static let contrast: Double = 1.0

        /// Paper showing between strokes. Warm off-white.
        static let paperRed: CGFloat = 0.975
        static let paperGreen: CGFloat = 0.965
        static let paperBlue: CGFloat = 0.94
        /// How much of the region color is washed under the strokes, 0...1. 0 is bare paper.
        static let washKeep: Double = 0.3

        /// Hatch texture: stroke count per 256-pixel tile, stroke length range in tile pixels,
        /// tilt from vertical in radians, and seed. Changing the seed redraws the pattern.
        static let hatchStrokes: Int = 1100
        static let hatchMinLength: CGFloat = 8
        static let hatchMaxLength: CGFloat = 30
        static let hatchTilt: CGFloat = 0.32
        static let hatchSeed: UInt64 = 0x50E7_C11
        /// Size of the tile on the work image. Above 1 makes the strokes longer and wider.
        static let hatchScale: CGFloat = 1.0
        /// Coverage is `(stroke + darkness * hatchDarkness - hatchCutoff) * hatchGain`.
        /// Raise `hatchCutoff` for more paper in light areas; raise `hatchDarkness` to fill darks solid.
        static let hatchDarkness: CGFloat = 0.9
        static let hatchCutoff: Double = 0.25
        static let hatchGain: Double = 2.2
        /// Stroke color relative to the region color. Below 1 makes the lead slightly denser.
        static let strokeShade: Double = 0.9

        /// Contours. More blur and a higher threshold leave only strong outlines.
        static let lineBlur: Double = 1.8
        static let lineIntensity: Double = 2.4
        static let lineThreshold: Double = 0.36
        static let lineHysteresis: Double = 0.14
        /// Blur on the line, for a soft pencil edge.
        static let lineSoften: Double = 0.9
        /// Line color is the region color times `lineShade`, plus `lineLift`. Lower is darker.
        static let lineShade: Double = 0.32
        static let lineLift: Double = 0.02
        /// Opacity of the main line and of the looser second pass beside it.
        static let lineStrength: Double = 0.75
        static let sketchStrength: Double = 0.45
        /// Pixel shift of the line. The field is fixed on screen. The second pass shifts the other
        /// way by `sketchSpread` times this, which gives the doubled sketchy edge.
        static let wobbleScale: Double = 4.5
        static let sketchSpread: Double = 1.6

        /// Paper tooth. 0 is clean. 0.1 is a visible grain.
        static let grainStrength: Double = 0.07
    }

    static var inkSettings: StableInk.Settings {
        StableInk.Settings(
            blur: Knob.lineBlur,
            intensity: Knob.lineIntensity,
            threshold: Knob.lineThreshold,
            hysteresis: Knob.lineHysteresis
        )
    }

    static func apply(
        to image: CIImage,
        grain: CIImage,
        wobble: CIImage,
        hatch: CIImage,
        history: CelHistory? = nil
    ) -> CIImage {
        let source = image.normalizedOrigin()
        let extent = source.extent
        guard extent.width > 2, extent.height > 2, extent.isFinite else { return source }

        let small = downscaled(source, scale: Knob.workScale)
        let smallExtent = small.extent

        var smoothed = smoothedColor(small)
        if let history {
            smoothed = history.color.blend(smoothed, keep: Knob.colorKeep)
        }

        var regions = simplifiedColors(from: smoothed, extent: smallExtent)
        if let history {
            regions = history.fills.blend(regions, keep: Knob.fillKeep)
        }

        let previousLines = history?.lines.previous(matching: smallExtent)
        let lineMask = StableInk.mask(from: smoothed, previous: previousLines, settings: inkSettings)
        let storedLines = history?.lines.commit(lineMask) ?? lineMask

        let strokes = strokeMarks(hatch, extent: smallExtent)
        let shaded = pencilFill(regions, marks: strokes, extent: smallExtent)
        let drawn = pencilLines(over: shaded, regions: regions, mask: storedLines, marks: strokes, wobble: wobble, extent: smallExtent)

        let full = upscaled(drawn, to: extent)
        return paperGrain(full, grain: grain, extent: extent)
    }

    /// Median, then edge-preserving noise reduction, then a light blur. Camera grit is gone before
    /// anything is quantized or traced.
    static func smoothedColor(_ image: CIImage) -> CIImage {
        let extent = image.extent
        return image.clampedToExtent()
            .applyingFilter("CIMedianFilter")
            .applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": Knob.smoothNoise,
                "inputSharpness": Knob.smoothSharpness
            ])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: Knob.colorBlur])
            .cropped(to: extent)
    }

    private static func simplifiedColors(from smoothed: CIImage, extent: CGRect) -> CIImage {
        let flat = smoothed.applyingFilter("CIColorPosterize", parameters: [
            "inputLevels": Knob.posterizeLevels
        ]).cropped(to: extent)

        let mixed = flat.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: smoothed,
            kCIInputTimeKey: Knob.gradientKeep
        ]).cropped(to: extent)

        return mixed.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: Knob.saturation,
            kCIInputBrightnessKey: Knob.brightness,
            kCIInputContrastKey: Knob.contrast
        ]).cropped(to: extent)
    }

    /// Stroke strength from the fixed hatch tile: 0 is bare paper, toward 1 is a heavy stroke.
    /// Converted to gamma values first, so the knobs read like the drawn grays.
    private static func strokeMarks(_ hatch: CIImage, extent: CGRect) -> CIImage {
        guard hatch.extent.width > 1, hatch.extent.isFinite else {
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        }
        let tile = hatch.normalizedOrigin()
            .transformed(by: CGAffineTransform(scaleX: Knob.hatchScale, y: Knob.hatchScale))
            .applyingFilter("CIAffineTile")
            .cropped(to: extent)
            .applyingFilter("CILinearToSRGBToneCurve")
            .cropped(to: extent)
        return StableInk.affine(tile, scale: -1, bias: 1)
    }

    /// Strokes of the region color over a pale wash on paper. Darker regions take more strokes.
    private static func pencilFill(_ regions: CIImage, marks: CIImage, extent: CGRect) -> CIImage {
        let paper = CIImage(color: CIColor(red: Knob.paperRed, green: Knob.paperGreen, blue: Knob.paperBlue))
            .cropped(to: extent)
        let wash = regions.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: paper,
            kCIInputTimeKey: 1 - Knob.washKeep
        ]).cropped(to: extent)
        let lead = StableInk.affine(regions, scale: Knob.strokeShade, bias: 0)

        let d = Knob.hatchDarkness
        let darkness = regions
            .applyingFilter("CILinearToSRGBToneCurve")
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: -0.299 * d, y: -0.587 * d, z: -0.114 * d, w: 0),
                "inputGVector": CIVector(x: -0.299 * d, y: -0.587 * d, z: -0.114 * d, w: 0),
                "inputBVector": CIVector(x: -0.299 * d, y: -0.587 * d, z: -0.114 * d, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: d, y: d, z: d, w: 1)
            ])
            .applyingFilter("CIColorClamp")
            .cropped(to: extent)
        // Linear dodge adds the two grays and keeps alpha at 1.
        let summed = marks.applyingFilter("CILinearDodgeBlendMode", parameters: [
            kCIInputBackgroundImageKey: darkness
        ]).cropped(to: extent)
        let coverage = StableInk.affine(summed, scale: Knob.hatchGain, bias: -Knob.hatchCutoff * Knob.hatchGain)

        return lead.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: wash,
            kCIInputMaskImageKey: coverage
        ]).cropped(to: extent)
    }

    /// Two soft passes of the contour, shifted opposite ways by the fixed wobble field, in a darker
    /// shade of the region color. The hatch breaks the line up a little, like pencil on tooth.
    private static func pencilLines(
        over shaded: CIImage,
        regions: CIImage,
        mask: CIImage,
        marks: CIImage,
        wobble: CIImage,
        extent: CGRect
    ) -> CIImage {
        let soft = mask.cropped(to: extent).clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: Knob.lineSoften])
            .cropped(to: extent)
        let main = StableInk.affine(
            displace(soft, wobble: wobble, extent: extent, scale: Knob.wobbleScale),
            scale: Knob.lineStrength,
            bias: 0
        )
        let sketch = StableInk.affine(
            displace(soft, wobble: wobble, extent: extent, scale: -Knob.wobbleScale * Knob.sketchSpread),
            scale: Knob.sketchStrength,
            bias: 0
        )
        let both = main.applyingFilter("CIMaximumCompositing", parameters: [
            kCIInputBackgroundImageKey: sketch
        ]).cropped(to: extent)
        let tooth = StableInk.affine(marks, scale: 0.5, bias: 0.6)
        let coverage = StableInk.multiply(both, tooth)

        let lineColor = StableInk.affine(regions, scale: Knob.lineShade, bias: Knob.lineLift)
        return lineColor.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: shaded,
            kCIInputMaskImageKey: coverage
        ]).cropped(to: extent)
    }

    private static func displace(_ image: CIImage, wobble: CIImage, extent: CGRect, scale: Double) -> CIImage {
        guard wobble.extent.width > 1, wobble.extent.height > 1, wobble.extent.isFinite else {
            return image
        }
        let base = wobble.normalizedOrigin()
        let scaleX = extent.width / max(base.extent.width, 1)
        let scaleY = extent.height / max(base.extent.height, 1)
        let map = base
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .normalizedOrigin()
            .cropped(to: extent)
        return image.clampedToExtent()
            .applyingFilter("CIDisplacementDistortion", parameters: [
                "inputDisplacementImage": map,
                kCIInputScaleKey: scale
            ])
            .cropped(to: extent)
    }

    /// Multiplies a fixed paper tooth over the drawing. The grain tile is mid-gray noise.
    private static func paperGrain(_ image: CIImage, grain: CIImage, extent: CGRect) -> CIImage {
        guard grain.extent.width > 1, grain.extent.isFinite, Knob.grainStrength > 0.001 else { return image }
        let tooth = grain
            .applyingFilter("CIAffineTile")
            .cropped(to: extent)
            .applyingFilter("CILinearToSRGBToneCurve")
            .cropped(to: extent)
        // In gamma values the grain spans about 0.4...0.65; this maps it to about 1 - grainStrength ... 1.
        let scale = Knob.grainStrength * 4
        let shaded = StableInk.affine(tooth, scale: scale, bias: 1 - scale * 0.65)
        return StableInk.multiply(image, shaded)
    }

    static func downscaled(_ image: CIImage, scale: CGFloat) -> CIImage {
        let scaled = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .normalizedOrigin()
        var width = floor(scaled.extent.width)
        var height = floor(scaled.extent.height)
        if Int(width) % 2 != 0 { width -= 1 }
        if Int(height) % 2 != 0 { height -= 1 }
        width = max(2, width)
        height = max(2, height)
        return scaled.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    static func upscaled(_ image: CIImage, to extent: CGRect) -> CIImage {
        let source = image.normalizedOrigin()
        let scaleX = extent.width / max(source.extent.width, 1)
        let scaleY = extent.height / max(source.extent.height, 1)
        return source
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .normalizedOrigin()
            .cropped(to: extent)
    }
}

private extension CGRect {
    var isFinite: Bool {
        origin.x.isFinite && origin.y.isFinite && width.isFinite && height.isFinite
    }
}
