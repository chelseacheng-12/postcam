import CoreImage
import UIKit

enum ImagePrep {
    /// UIImage orientation is applied by `CIImage(image:)`. Long edge is capped so a library
    /// photo doesn't try to filter a 48-megapixel buffer in one shot.
    static func ciImage(from image: UIImage, maxPixel: CGFloat) -> CIImage? {
        guard let source = CIImage(image: image)?.normalizedOrigin() else { return nil }
        let longest = max(source.extent.width, source.extent.height)
        guard longest > 1 else { return nil }
        guard longest > maxPixel else { return source }
        let scale = maxPixel / longest
        return source.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).normalizedOrigin()
    }
}
