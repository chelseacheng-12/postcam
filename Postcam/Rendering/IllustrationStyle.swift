import CoreImage
import CoreGraphics

/// Anime background treatment used only inside the stamp.
///
/// Flat cel color, warm charcoal line art, a little hand-drawn wobble.
/// Edit `Knob` if the lines are too busy, the fills are too flat, or the ink is too heavy.
/// Heavy passes run at `workScale` so a 1080p preview can stay near 30fps.
enum IllustrationStyle {
    enum Knob {
        /// Resolution of the smoothing and line passes, relative to the frame.
        static let workScale: CGFloat = 0.5

        /// Edge-preserving smooth before the colors are flattened.
        static let smoothNoise: Double = 0.025
        static let smoothSharpness: Double = 0.42

        /// Posterize steps per channel. 5–8 reads as cel shading.
        static let posterizeLevels: Double = 6
        /// 0 is fully flat. Higher keeps gentle gradients in sky and road.
        static let gradientKeep: Double = 0.30
        static let saturation: Double = 1.16
        static let brightness: Double = 0.03
        static let contrast: Double = 1.05

        /// CILineOverlay. Higher threshold and noise drop speckle; higher contrast crisps the ink.
        static let lineNoise: Double = 0.04
        static let lineSharpness: Double = 0.5
        static let lineEdge: Double = 1.2
        static let lineThreshold: Double = 0.15
        static let lineContrast: Double = 58
        /// Blur before the contrast boost, so stroke width varies a little.
        static let lineSoften: Double = 0.4
        /// Pixel shift of the ink. Small values wobble; large values tear the drawing.
        static let wobbleScale: Double = 7
        /// 0 is full ink. 1 removes the lines.
        static let lineFade: Double = 0.08
        /// 0 is full grain. 1 is a clean cel.
        static let grainFade: Double = 0.9

        /// Warm charcoal, not pure black.
        static let inkRed: CGFloat = 0.23
        static let inkGreen: CGFloat = 0.14
        static let inkBlue: CGFloat = 0.11
    }

    static func apply(to image: CIImage, grain: CIImage, wobble: CIImage) -> CIImage {
        let source = image.normalizedOrigin()
        let extent = source.extent
        guard extent.width > 2, extent.height > 2, extent.isFinite else { return source }

        let small = downscaled(source)
        let smallExtent = small.extent
        let smoothed = smoothedColor(small)
        let fills = celFills(from: smoothed, extent: smallExtent)
        let lines = inkLines(from: smoothed, wobble: wobble, extent: smallExtent)

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

    /// Noise reduction keeps object edges and wipes camera grit before posterizing.
    private static func smoothedColor(_ image: CIImage) -> CIImage {
        let extent = image.extent
        return image.clampedToExtent()
            .applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": Knob.smoothNoise,
                "inputSharpness": Knob.smoothSharpness
            ])
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

    /// Thresholded line overlay on the smoothed frame, then a low-frequency nudge.
    private static func inkLines(from smoothed: CIImage, wobble: CIImage, extent: CGRect) -> CIImage {
        let traced = smoothed.clampedToExtent()
            .applyingFilter("CILineOverlay", parameters: [
                "inputNRNoiseLevel": Knob.lineNoise,
                "inputNRSharpness": Knob.lineSharpness,
                "inputEdgeIntensity": Knob.lineEdge,
                "inputThreshold": Knob.lineThreshold,
                "inputContrast": Knob.lineContrast
            ])
            .cropped(to: extent)

        let weighted = traced.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: Knob.lineSoften
            ])
            .cropped(to: extent)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0,
                kCIInputBrightnessKey: -0.02,
                kCIInputContrastKey: 1.45
            ])
            .cropped(to: extent)

        let jittered = displace(weighted, wobble: wobble, extent: extent)
        return jittered.applyingFilter("CIFalseColor", parameters: [
            "inputColor0": CIColor(red: Knob.inkRed, green: Knob.inkGreen, blue: Knob.inkBlue),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1)
        ]).cropped(to: extent)
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

    private static func downscaled(_ image: CIImage) -> CIImage {
        let scaled = image
            .transformed(by: CGAffineTransform(scaleX: Knob.workScale, y: Knob.workScale))
            .normalizedOrigin()
        var width = floor(scaled.extent.width)
        var height = floor(scaled.extent.height)
        if Int(width) % 2 != 0 { width -= 1 }
        if Int(height) % 2 != 0 { height -= 1 }
        width = max(2, width)
        height = max(2, height)
        return scaled.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private static func upscaled(_ image: CIImage, to extent: CGRect) -> CIImage {
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
