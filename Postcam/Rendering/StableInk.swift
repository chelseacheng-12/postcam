import CoreGraphics
import CoreImage

/// Contour lines that hold still between frames.
/// Edges are measured on a blurred copy so fine texture drops out. The threshold has hysteresis:
/// a pixel that was ink last frame needs less edge strength to stay ink, so lines do not blink.
enum StableInk {
    struct Settings {
        /// Blur before edge detection. Higher keeps only broad contours.
        var blur: Double
        /// CIEdges gain.
        var intensity: Double
        /// Edge strength a new line needs.
        var threshold: Double
        /// How much easier it is for last frame's line to survive.
        var hysteresis: Double
    }

    /// White where there is a line, black elsewhere. Opaque, same extent as `image`.
    static func mask(from image: CIImage, previous: CIImage?, settings: Settings) -> CIImage {
        let extent = image.extent
        let gray = image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
            kCIInputBrightnessKey: 0,
            kCIInputContrastKey: 1
        ]).cropped(to: extent)
        let broad = gray.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: settings.blur])
            .cropped(to: extent)
        let edges = broad.clampedToExtent()
            .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: settings.intensity])
            .cropped(to: extent)
        var strength = edges
        if let previous {
            let bonus = affine(previous.cropped(to: extent), scale: settings.hysteresis, bias: 0)
            // Linear dodge adds the colors but keeps alpha at 1, so the threshold sees true sums.
            strength = bonus.applyingFilter("CILinearDodgeBlendMode", parameters: [
                kCIInputBackgroundImageKey: edges
            ]).cropped(to: extent)
        }
        let binary = strength.applyingFilter("CIColorThreshold", parameters: [
            "inputThreshold": settings.threshold
        ]).cropped(to: extent)
        return opaque(binary)
    }

    /// Paper-white image with `color` lines, ready to multiply over fills.
    static func ink(_ mask: CIImage, color: CIColor, soften: Double) -> CIImage {
        let extent = mask.extent
        let soft = soften > 0
            ? mask.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: soften])
                .cropped(to: extent)
            : mask
        return soft.applyingFilter("CIFalseColor", parameters: [
            "inputColor0": CIColor(red: 1, green: 1, blue: 1),
            "inputColor1": color
        ]).cropped(to: extent)
    }

    /// Thin ring around the white area of a gray mask.
    static func outline(_ mask: CIImage, radius: Double) -> CIImage {
        let extent = mask.extent
        return mask.clampedToExtent()
            .applyingFilter("CIMorphologyGradient", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
    }

    /// `value * scale + bias` on every color channel, clamped to 0...1, alpha forced to 1.
    static func affine(_ image: CIImage, scale: Double, bias: Double) -> CIImage {
        let extent = image.extent
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(scale), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(scale), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(scale), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: CGFloat(bias), y: CGFloat(bias), z: CGFloat(bias), w: 1)
        ])
        .applyingFilter("CIColorClamp")
        .cropped(to: extent)
    }

    static func opaque(_ image: CIImage) -> CIImage {
        affine(image, scale: 1, bias: 0)
    }

    /// Product of two gray masks.
    static func multiply(_ a: CIImage, _ b: CIImage) -> CIImage {
        let extent = a.extent
        return a.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: b
        ]).cropped(to: extent)
    }
}
