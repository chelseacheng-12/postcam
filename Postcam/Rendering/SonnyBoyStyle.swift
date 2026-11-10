import CoreGraphics
import CoreImage

/// Flat, graphic, high-key color. Sparse thin lines. No stamp.
/// Used only inside the hand-framed window.
enum SonnyBoyStyle {
    enum Knob {
        static let workScale: CGFloat = 0.5
        static let smoothNoise: Double = 0.02
        static let smoothSharpness: Double = 0.35
        static let posterizeLevels: Double = 5
        /// Almost flat. A little remains so a sky is not a single chip of color.
        static let gradientKeep: Double = 0.12
        static let saturation: Double = 1.42
        static let brightness: Double = 0.05
        static let contrast: Double = 1.1
        static let lineNoise: Double = 0.06
        static let lineSharpness: Double = 0.35
        static let lineEdge: Double = 0.7
        static let lineThreshold: Double = 0.32
        static let lineContrast: Double = 40
        /// 0 is full ink. Higher leaves only a few thin strokes.
        static let lineFade: Double = 0.55
        static let inkRed: CGFloat = 0.16
        static let inkGreen: CGFloat = 0.12
        static let inkBlue: CGFloat = 0.14
    }

    static func apply(to image: CIImage) -> CIImage {
        let source = image.normalizedOrigin()
        let extent = source.extent
        guard extent.width > 2, extent.height > 2, extent.isFinite else { return source }

        let small = downscaled(source)
        let smallExtent = small.extent
        let smoothed = small.clampedToExtent()
            .applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": Knob.smoothNoise,
                "inputSharpness": Knob.smoothSharpness
            ])
            .cropped(to: smallExtent)

        let flat = smoothed.applyingFilter("CIColorPosterize", parameters: [
            "inputLevels": Knob.posterizeLevels
        ]).cropped(to: smallExtent)

        let mixed = flat.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: smoothed,
            kCIInputTimeKey: Knob.gradientKeep
        ]).cropped(to: smallExtent)

        let fills = mixed.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: Knob.saturation,
            kCIInputBrightnessKey: Knob.brightness,
            kCIInputContrastKey: Knob.contrast
        ]).cropped(to: smallExtent)

        let lines = smoothed.clampedToExtent()
            .applyingFilter("CILineOverlay", parameters: [
                "inputNRNoiseLevel": Knob.lineNoise,
                "inputNRSharpness": Knob.lineSharpness,
                "inputEdgeIntensity": Knob.lineEdge,
                "inputThreshold": Knob.lineThreshold,
                "inputContrast": Knob.lineContrast
            ])
            .cropped(to: smallExtent)
            .applyingFilter("CIFalseColor", parameters: [
                "inputColor0": CIColor(red: Knob.inkRed, green: Knob.inkGreen, blue: Knob.inkBlue),
                "inputColor1": CIColor(red: 1, green: 1, blue: 1)
            ])
            .cropped(to: smallExtent)

        let inked = lines.applyingFilter("CIMultiplyBlendMode", parameters: [
            kCIInputBackgroundImageKey: fills
        ]).cropped(to: smallExtent)

        let drawn = inked.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: fills,
            kCIInputTimeKey: Knob.lineFade
        ]).cropped(to: smallExtent)

        return upscaled(drawn, to: extent)
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
