import CoreGraphics
import CoreImage
import Metal
import UIKit

/// Bakes the perforated frame and the anime treatment inside the window.
/// The paper and the mask are cached until the pixel size or the stamp width changes.
final class StampCompositor {
    let metalDevice: MTLDevice?
    let context: CIContext

    private let cacheLock = NSLock()
    private let renderQueue = DispatchQueue(label: "com.chelseacheng.postcam.warmup", qos: .userInitiated)
    private var cache: [String: (mask: CIImage, overlay: CIImage)] = [:]
    private var grain: CIImage?
    private var wobble: CIImage?

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            metalDevice = device
            context = CIContext(mtlDevice: device, options: [
                .cacheIntermediates: false
            ])
        } else {
            metalDevice = nil
            context = CIContext(options: [.cacheIntermediates: false])
        }
    }

    func warmUp() {
        renderQueue.async { [weak self] in
            guard let self else { return }
            _ = self.grainImage()
            let extent = CGRect(x: 0, y: 0, width: 160, height: 160)
            let gray = CIImage(color: CIColor(red: 0.75, green: 0.62, blue: 0.58)).cropped(to: extent)
            let styled = IllustrationStyle.apply(to: gray, grain: self.grainImage(), wobble: self.wobbleImage())
            _ = self.context.createCGImage(styled, from: styled.extent)
        }
    }

    /// `history` carries the live drawing between frames. Leave it nil for a single still.
    func composite(_ image: CIImage, copy: StampCopy, history: CelHistory? = nil) -> CIImage {
        let source = prepared(image)
        let extent = source.extent
        guard extent.width > 8, extent.height > 8 else { return source }
        guard let artwork = artwork(for: extent, copy: copy) else { return source }

        let stylized = IllustrationStyle.apply(
            to: source,
            grain: grainImage(),
            wobble: wobbleImage(),
            history: history
        )
        let masked = stylized.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: source,
            kCIInputMaskImageKey: artwork.mask
        ]).cropped(to: extent)

        return artwork.overlay.applyingFilter("CISourceOverCompositing", parameters: [
            kCIInputBackgroundImageKey: masked
        ]).cropped(to: extent)
    }

    func uiImage(from image: CIImage) -> UIImage? {
        let extent = image.extent.integral
        guard extent.width > 1, extent.height > 1 else { return nil }
        guard let cgImage = context.createCGImage(image, from: extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    func thumbnail(from image: CIImage, maxPixel: CGFloat = 420) -> UIImage? {
        let longest = max(image.extent.width, image.extent.height)
        guard longest > 1 else { return nil }
        let scale = min(1, maxPixel / longest)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).normalizedOrigin()
        return uiImage(from: scaled)
    }

    private func prepared(_ image: CIImage) -> CIImage {
        let normalized = image.normalizedOrigin()
        var width = floor(normalized.extent.width)
        var height = floor(normalized.extent.height)
        if Int(width) % 2 != 0 { width -= 1 }
        if Int(height) % 2 != 0 { height -= 1 }
        width = max(2, width)
        height = max(2, height)
        return normalized.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func artwork(for extent: CGRect, copy: StampCopy) -> (mask: CIImage, overlay: CIImage)? {
        let fractionKey = String(format: "%.4f", copy.widthFraction)
        let key = "\(Int(extent.width))x\(Int(extent.height))|\(fractionKey)"
        cacheLock.lock()
        if let hit = cache[key] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        guard let pair = drawArtwork(extent: extent, copy: copy) else { return nil }
        cacheLock.lock()
        cache[key] = pair
        if cache.count > 3, let extra = cache.keys.first(where: { $0 != key }) {
            cache.removeValue(forKey: extra)
        }
        cacheLock.unlock()
        return pair
    }

    private func drawArtwork(extent: CGRect, copy: StampCopy) -> (mask: CIImage, overlay: CIImage)? {
        let width = Int(extent.width)
        let height = Int(extent.height)
        let layout = StampGeometry.layout(in: extent, widthFraction: copy.widthFraction)
        guard layout.window.width > 16, layout.window.height > 16 else { return nil }
        guard let mask = drawMask(width: width, height: height, window: layout.window),
              let overlay = drawOverlay(width: width, height: height, layout: layout) else {
            return nil
        }
        return (mask, overlay)
    }

    private func drawMask(width: Int, height: Int, window: CGRect) -> CIImage? {
        guard let context = bitmapContext(width: width, height: height) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(UIColor.white.cgColor)
        // A couple of pixels of overlap hides a seam under the paper edge.
        context.fill(window.insetBy(dx: -2, dy: -2))
        guard let cgImage = context.makeImage() else { return nil }
        return upright(cgImage)
    }

    private func drawOverlay(width: Int, height: Int, layout: StampLayout) -> CIImage? {
        guard let context = bitmapContext(width: width, height: height) else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        context.clear(canvas)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(true)
        context.interpolationQuality = .high

        context.addPath(layout.path)
        context.addRect(layout.window)
        context.setFillColor(PostcamColor.paperUI.cgColor)
        context.fillPath(using: .evenOdd)

        context.addRect(layout.window)
        context.setStrokeColor(PostcamColor.frameLineUI.cgColor)
        context.setLineWidth(max(1, layout.bounds.width * 0.0035))
        context.strokePath()

        guard let cgImage = context.makeImage() else { return nil }
        return upright(cgImage)
    }

    /// `CIImage(cgImage:)` stores the top row at the bottom. The context above is y-up, matching
    /// the camera buffer, so flip the bitmap back. If a device shows the stamp upside down,
    /// return `CIImage(cgImage:)` directly.
    private func upright(_ cgImage: CGImage) -> CIImage {
        CIImage(cgImage: cgImage).oriented(.downMirrored).normalizedOrigin()
    }

    private func bitmapContext(width: Int, height: Int) -> CGContext? {
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

    private func grainImage() -> CIImage {
        cacheLock.lock()
        if let grain {
            cacheLock.unlock()
            return grain
        }
        cacheLock.unlock()

        let made = makeGrain()
        cacheLock.lock()
        if grain == nil { grain = made }
        let result = grain ?? made
        cacheLock.unlock()
        return result
    }

    /// Baked once. Live noise would shimmer like static instead of sitting on the paper.
    private func makeGrain() -> CIImage {
        let side: CGFloat = 256
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let fallback = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: rect)
        guard let random = CIFilter(name: "CIRandomGenerator")?.outputImage?.cropped(to: rect) else {
            return fallback
        }
        let gray = random.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
            kCIInputBrightnessKey: 0.02,
            kCIInputContrastKey: 0.25
        ]).cropped(to: rect)
        guard let cgImage = context.createCGImage(gray, from: rect) else { return fallback }
        return CIImage(cgImage: cgImage)
    }

    private func wobbleImage() -> CIImage {
        cacheLock.lock()
        if let wobble {
            cacheLock.unlock()
            return wobble
        }
        cacheLock.unlock()

        let made = makeWobble()
        cacheLock.lock()
        if wobble == nil { wobble = made }
        let result = wobble ?? made
        cacheLock.unlock()
        return result
    }

    /// Low-frequency field, baked once so the ink wobble does not swim between frames.
    private func makeWobble() -> CIImage {
        let side: CGFloat = 256
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let fallback = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: rect)
        guard let random = CIFilter(name: "CIRandomGenerator")?.outputImage?.cropped(to: rect) else {
            return fallback
        }
        let blurred = random.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 26])
            .cropped(to: rect)
        // The wider blur flattens the field, so contrast comes back up to keep a gentle hand-drawn bend.
        let soft = blurred.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
            kCIInputBrightnessKey: 0,
            kCIInputContrastKey: 1.8
        ]).cropped(to: rect)
        guard let cgImage = context.createCGImage(soft, from: rect) else { return fallback }
        return CIImage(cgImage: cgImage)
    }
}
