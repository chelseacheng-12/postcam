import CoreImage
import CoreGraphics

extension CIImage {
    /// Moves the extent origin to (0, 0). Core Image filters often leave a translated extent.
    func normalizedOrigin() -> CIImage {
        let origin = extent.origin
        guard origin.x != 0 || origin.y != 0 else { return self }
        return transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }

    /// Aspect-fills this image into `viewAspect` (width / height) and returns an even-sized crop.
    /// The saved photo uses this same crop, so it matches the full-bleed preview.
    func croppedToEvenAspect(_ viewAspect: CGFloat) -> CIImage {
        let source = normalizedOrigin()
        let src = source.extent
        guard src.width > 2, src.height > 2, viewAspect > 0.05 else { return source }

        let imageAspect = src.width / src.height
        var crop = src
        if imageAspect > viewAspect {
            let newWidth = src.height * viewAspect
            crop = CGRect(x: floor((src.width - newWidth) / 2), y: 0, width: floor(newWidth), height: floor(src.height))
        } else if imageAspect < viewAspect {
            let newHeight = src.width / viewAspect
            crop = CGRect(x: 0, y: floor((src.height - newHeight) / 2), width: floor(src.width), height: floor(newHeight))
        }

        var width = floor(crop.width)
        var height = floor(crop.height)
        if Int(width) % 2 != 0 { width -= 1 }
        if Int(height) % 2 != 0 { height -= 1 }
        crop.size.width = max(2, width)
        crop.size.height = max(2, height)
        if crop.maxX > src.width { crop.origin.x = max(0, src.width - crop.width) }
        if crop.maxY > src.height { crop.origin.y = max(0, src.height - crop.height) }
        return source.cropped(to: crop).normalizedOrigin()
    }

    /// Scales to cover `dest` in Core Image coordinates (origin at the bottom left).
    func filling(_ dest: CGRect) -> CIImage {
        let source = extent
        guard source.width > 1, source.height > 1, dest.width > 1, dest.height > 1 else { return self }
        let scale = max(dest.width / source.width, dest.height / source.height)
        let scaled = transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = dest.midX - scaled.extent.midX
        let dy = dest.midY - scaled.extent.midY
        return scaled
            .transformed(by: CGAffineTransform(translationX: dx, y: dy))
            .cropped(to: dest)
    }
}
