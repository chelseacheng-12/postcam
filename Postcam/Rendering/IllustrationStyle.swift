import CoreImage
import CoreGraphics

/// Anime background treatment used only inside the stamp.
///
/// Flat cel color, warm charcoal line art, a little hand-drawn wobble.
/// Live frames pass a `CelHistory` so color, fills, and lines carry over from the last frame
/// instead of being recomputed from camera noise. Stills pass nil.
/// Heavy passes run at `workScale` so a 1080p preview can stay near 30fps.
enum IllustrationStyle {
    enum Knob {
        /// Resolution of the smoothing and line passes, relative to the frame.
        static let workScale: CGFloat = 0.5

        /// Edge-preserving smooth before the colors are flattened. A median pass runs first.
        static let smoothNoise: Double = 0.04
        static let smoothSharpness: Double = 0.35
        /// Extra blur on the color that gets posterized. Removes the speckle that made bands crawl.
        static let colorBlur: Double = 1.2

        /// Share of the previous frame kept, 0...1. Higher is calmer, with a little trail on fast pans.
        static let colorKeep: CGFloat = 0.65
        static let fillKeep: CGFloat = 0.5

        /// Posterize steps per channel. 5–8 reads as cel shading.
        static let posterizeLevels: Double = 6
        /// 0 is fully flat. Higher keeps gentle gradients in sky and road.
        static let gradientKeep: Double = 0.30
        static let saturation: Double = 1.16
        static let brightness: Double = 0.03
        static let contrast: Double = 1.05

        /// Contours. More blur and a higher threshold leave only strong outlines.
        static let lineBlur: Double = 1.8
        static let lineIntensity: Double = 2.4
        static let lineThreshold: Double = 0.32
        static let lineHysteresis: Double = 0.14
        /// Antialiasing on the ink.
        static let lineSoften: Double = 0.6
        /// Pixel shift of the ink. The field is fixed on screen, so keep it small.
        static let wobbleScale: Double = 3
        /// 0 is full ink. 1 removes the lines.
        static let lineFade: Double = 0.1
        /// 0 is full grain. 1 is a clean cel.
        static let grainFade: Double = 0.9

        /// Warm charcoal, not pure black.
        static let inkRed: CGFloat = 0.23
        static let inkGreen: CGFloat = 0.14
        static let inkBlue: CGFloat = 0.11
    }

    static var inkSettings: StableInk.Settings {
        StableInk.Settings(
            blur: Knob.lineBlur,
            intensity: Knob.lineIntensity,
            threshold: Knob.lineThreshold,
            hysteresis: Knob.lineHysteresis
        )
    }

    static func apply(to image: CIImage, grain: CIImage, wobble: CIImage, history: CelHistory? = nil) -> CIImage {
        let source = image.normalizedOrigin()
        let extent = source.extent
        guard extent.width > 2, extent.height > 2, extent.isFinite else { return source }

        let small = downscaled(source, scale: Knob.workScale)
        let smallExtent = small.extent

        var smoothed = smoothedColor(small)
        if let history {
            smoothed = history.color.blend(smoothed, keep: Knob.colorKeep)
        }

        var fills = celFills(from: smoothed, extent: smallExtent)
        if let history {
            fills = history.fills.blend(fills, keep: Knob.fillKeep)
        }

        let previousLines = history?.lines.previous(matching: smallExtent)
        let lineMask = StableInk.mask(from: smoothed, previous: previousLines, settings: inkSettings)
        let storedLines = history?.lines.commit(lineMask) ?? lineMask
        let lines = inkLines(mask: storedLines, wobble: wobble, extent: smallExtent)

        let inked = lines.applyingFilter("CIMultiplyBlendMode", parameters: [
            kCIInputBackgroundImageKey: fills
        ]).cropped(to: smallExtent)

        let drawn = inked.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: fills,
            kCIInputTimeKey: Knob.lineFade
        ]).cropped(to: smallExtent)

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

    private static func celFills(from smoothed: CIImage, extent: CGRect) -> CIImage {
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

    private static func inkLines(mask: CIImage, wobble: CIImage, extent: CGRect) -> CIImage {
        let ink = StableInk.ink(
            mask.cropped(to: extent),
            color: CIColor(red: Knob.inkRed, green: Knob.inkGreen, blue: Knob.inkBlue),
            soften: Knob.lineSoften
        )
        return displace(ink, wobble: wobble, extent: extent)
    }

    private static func displace(_ image: CIImage, wobble: CIImage, extent: CGRect) -> CIImage {
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
                kCIInputScaleKey: Knob.wobbleScale
            ])
            .cropped(to: extent)
    }

    private static func paperGrain(_ image: CIImage, grain: CIImage, extent: CGRect) -> CIImage {
        guard grain.extent.width > 1, grain.extent.isFinite, Knob.grainFade < 0.999 else { return image }
        let textured = grain
            .applyingFilter("CIAffineTile")
            .cropped(to: extent)
            .applyingFilter("CISoftLightBlendMode", parameters: [
                kCIInputBackgroundImageKey: image
            ])
            .cropped(to: extent)
        return textured.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: image,
            kCIInputTimeKey: Knob.grainFade
        ]).cropped(to: extent)
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
