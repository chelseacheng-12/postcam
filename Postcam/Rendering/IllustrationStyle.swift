import CoreImage
import CoreGraphics

/// Crayon / colored-pencil treatment used only inside the stamp.
///
/// Edit `Knob` if the live image is too dark, too pink, or the pencil lines are too heavy.
/// These run on every preview frame, so keep the chain short.
enum IllustrationStyle {
    enum Knob {
        static let posterizeLevels: Double = 6
        static let saturation: Double = 0.94
        static let brightness: Double = 0.05
        static let contrast: Double = 1.14
        /// 0 leaves shadows alone. Higher lifts dark pavement toward the pastel wash.
        static let shadowLift: Double = 0.42
        static let highlightAmount: Double = 0.9
        /// Lower than 6500 warms the frame (maps neutral daylight toward tungsten).
        static let targetTemperature: Double = 4900
        static let targetTint: Double = 10
        /// 0 keeps the full pencil outline. 1 removes it.
        static let lineMix: Double = 0.58
        static let edgeIntensity: Double = 2.6
    }

    static func apply(to image: CIImage, grain: CIImage) -> CIImage {
        let source = image.normalizedOrigin()
        let extent = source.extent
        guard extent.width > 2, extent.height > 2, extent.isFinite else { return source }

        let lifted = source.applyingFilter("CIHighlightShadowAdjust", parameters: [
            "inputHighlightAmount": Knob.highlightAmount,
            "inputShadowAmount": Knob.shadowLift
        ]).cropped(to: extent)

        let poster = lifted.applyingFilter("CIColorPosterize", parameters: [
            "inputLevels": Knob.posterizeLevels
        ]).cropped(to: extent)

        let graded = poster.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: Knob.saturation,
            kCIInputBrightnessKey: Knob.brightness,
            kCIInputContrastKey: Knob.contrast
        ]).cropped(to: extent)

        let warmed = graded.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: 6500, y: 0),
            "inputTargetNeutral": CIVector(x: Knob.targetTemperature, y: Knob.targetTint)
        ]).cropped(to: extent)

        // Push neutrals toward peach and keep a little of the original blue.
        let peach = warmed.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1.05, y: 0.06, z: 0.02, w: 0),
            "inputGVector": CIVector(x: 0.02, y: 0.90, z: 0.03, w: 0),
            "inputBVector": CIVector(x: 0.04, y: 0.03, z: 0.80, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0.035, y: 0.012, z: 0.028, w: 0)
        ]).cropped(to: extent)

        let wash = CIImage(color: CIColor(red: 0.98, green: 0.74, blue: 0.76)).cropped(to: extent)
        let pastel = wash.applyingFilter("CISoftLightBlendMode", parameters: [
            kCIInputBackgroundImageKey: peach
        ]).cropped(to: extent)

        let lines = pencilLines(from: source, extent: extent)
        let drawn = lines.applyingFilter("CIMultiplyBlendMode", parameters: [
            kCIInputBackgroundImageKey: pastel
        ]).cropped(to: extent)

        let penciled = drawn.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: pastel,
            kCIInputTimeKey: Knob.lineMix
        ]).cropped(to: extent)

        guard grain.extent.width > 1, grain.extent.isFinite else { return penciled }
        let tiled = grain.applyingFilter("CIAffineTile").cropped(to: extent)
        return tiled.applyingFilter("CISoftLightBlendMode", parameters: [
            kCIInputBackgroundImageKey: penciled
        ]).cropped(to: extent)
    }

    /// Edges at half resolution, then scaled back. Cheaper, and the soft line reads as pencil.
    private static func pencilLines(from image: CIImage, extent: CGRect) -> CIImage {
        let small = image.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        let smallExtent = small.extent
        let edges = small.clampedToExtent()
            .applyingFilter("CIEdges", parameters: [
                kCIInputIntensityKey: Knob.edgeIntensity
            ])
            .cropped(to: smallExtent)
        let inverted = edges.applyingFilter("CIColorInvert").cropped(to: smallExtent)
        return inverted
            .transformed(by: CGAffineTransform(scaleX: 2, y: 2))
            .cropped(to: extent)
    }
}

private extension CGRect {
    var isFinite: Bool {
        origin.x.isFinite && origin.y.isFinite && width.isFinite && height.isFinite
    }
}
