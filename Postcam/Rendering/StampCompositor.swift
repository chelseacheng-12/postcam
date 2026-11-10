import CoreGraphics
import CoreImage
import CoreText
import Metal
import UIKit

/// Bakes the perforated frame, typewriter lines, and the crayon treatment inside the window.
/// Mask and text are cached until the pixel size or the stamp copy changes.
final class StampCompositor {
    let metalDevice: MTLDevice?
    let context: CIContext

    private let cacheLock = NSLock()
    private let proofLock = NSLock()
    private let renderQueue = DispatchQueue(label: "com.chelseacheng.postcam.proof", qos: .userInitiated)
    private var cache: [String: (mask: CIImage, overlay: CIImage)] = [:]
    private var grain: CIImage?
    private var proofID = 0

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
            let styled = IllustrationStyle.apply(to: gray, grain: self.grainImage())
            _ = self.context.createCGImage(styled, from: styled.extent)
        }
    }

    func composite(_ image: CIImage, copy: StampCopy) -> CIImage {
        let source = prepared(image)
        let extent = source.extent
        guard extent.width > 8, extent.height > 8 else { return source }
        guard let artwork = artwork(for: extent, copy: copy) else { return source }

        let stylized = IllustrationStyle.apply(to: source, grain: grainImage())
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

    /// Settings-sheet proof. Stale renders (the user kept typing) come back as nil.
    func proof(copy: StampCopy) async -> UIImage? {
        let id: Int = proofLock.sync {
            proofID += 1
            return proofID
        }
        return await withCheckedContinuation { continuation in
            renderQueue.async {
                let stillCurrent = self.proofLock.sync { self.proofID == id }
                guard stillCurrent else {
                    continuation.resume(returning: nil)
                    return
                }
                let image = self.makeProof(copy: copy)
                let fresh = self.proofLock.sync { self.proofID == id }
                continuation.resume(returning: fresh ? image : nil)
            }
        }
    }

    private func makeProof(copy: StampCopy) -> UIImage? {
        let extent = CGRect(x: 0, y: 0, width: 720, height: 1280)
        let scene = StampSampleScene.make(extent: extent)
        return uiImage(from: composite(scene, copy: copy))
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
        let key = "\(Int(extent.width))x\(Int(extent.height))|\(fractionKey)|\(copy.date)|\(copy.label)|\(copy.caption)|\(copy.denomination)|\(copy.place)"
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
              let overlay = drawOverlay(width: width, height: height, layout: layout, copy: copy) else {
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

    private func drawOverlay(width: Int, height: Int, layout: StampLayout, copy: StampCopy) -> CIImage? {
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

        drawCopy(copy, layout: layout, in: context)
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

    private func drawCopy(_ copy: StampCopy, layout: StampLayout, in context: CGContext) {
        let window = layout.window
        let padX = window.width * 0.055
        let padY = window.height * 0.05
        let dateFont = typewriter(size: window.width * 0.042, bold: false)
        let labelFont = typewriter(size: window.width * 0.037, bold: false)
        let captionFont = typewriter(size: window.width * 0.030, bold: false)
        let valueFont = typewriter(size: window.width * 0.074, bold: true)
        let placeFont = typewriter(size: window.width * 0.033, bold: false)

        let capTop = window.maxY - padY
        let textBottom = window.minY + padY
        let placeBaseline = textBottom - placeFont.descender
        let captionBaseline = textBottom - captionFont.descender
        let valueBaseline = placeBaseline + placeFont.lineHeight * 0.78

        drawLine(
            copy.date,
            baselineY: capTop - dateFont.ascender,
            anchorX: window.minX + padX,
            align: .left,
            maxWidth: window.width * 0.46,
            font: dateFont,
            color: PostcamColor.inkUI,
            in: context
        )
        drawLine(
            copy.label,
            baselineY: capTop - labelFont.ascender,
            anchorX: window.maxX - padX,
            align: .right,
            maxWidth: window.width * 0.48,
            font: labelFont,
            color: PostcamColor.inkUI,
            in: context
        )
        drawLine(
            copy.caption,
            baselineY: captionBaseline,
            anchorX: window.minX + padX,
            align: .left,
            maxWidth: window.width * 0.56,
            font: captionFont,
            color: PostcamColor.inkUI,
            in: context
        )
        drawLine(
            copy.denomination,
            baselineY: valueBaseline,
            anchorX: window.maxX - padX,
            align: .right,
            maxWidth: window.width * 0.34,
            font: valueFont,
            color: PostcamColor.vermilionUI,
            in: context
        )
        drawLine(
            copy.place,
            baselineY: placeBaseline,
            anchorX: window.maxX - padX,
            align: .right,
            maxWidth: window.width * 0.36,
            font: placeFont,
            color: PostcamColor.inkUI,
            in: context
        )
    }

    private enum TextAlign { case left, right }

    private func drawLine(
        _ text: String,
        baselineY: CGFloat,
        anchorX: CGFloat,
        align: TextAlign,
        maxWidth: CGFloat,
        font: UIFont,
        color: UIColor,
        in context: CGContext
    ) {
        let rendered = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !rendered.isEmpty else { return }

        var current = font
        var inkLine = makeLine(rendered, font: current, color: color)
        var width = CGFloat(CTLineGetTypographicBounds(inkLine, nil, nil, nil))
        while width > maxWidth && current.pointSize > 8 {
            current = current.withSize(current.pointSize - 0.5)
            inkLine = makeLine(rendered, font: current, color: color)
            width = CGFloat(CTLineGetTypographicBounds(inkLine, nil, nil, nil))
        }

        let originX: CGFloat
        switch align {
        case .left: originX = anchorX
        case .right: originX = anchorX - width
        }

        let halo = makeLine(rendered, font: current, color: PostcamColor.haloUI)
        let radius = max(1, current.pointSize * 0.06)
        let shifts = [
            CGPoint(x: -radius, y: 0), CGPoint(x: radius, y: 0),
            CGPoint(x: 0, y: -radius), CGPoint(x: 0, y: radius)
        ]
        for shift in shifts {
            context.textPosition = CGPoint(x: originX + shift.x, y: baselineY + shift.y)
            CTLineDraw(halo, context)
        }
        context.textPosition = CGPoint(x: originX, y: baselineY)
        CTLineDraw(inkLine, context)
    }

    private func makeLine(_ text: String, font: UIFont, color: UIColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color.cgColor,
            .kern: font.pointSize * 0.04
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private func typewriter(size: CGFloat, bold: Bool) -> UIFont {
        let name = bold ? "AmericanTypewriter-Bold" : "AmericanTypewriter-Condensed"
        return UIFont(name: name, size: size)
            ?? UIFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
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
}

private extension NSLock {
    func sync<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

/// Flat stand-in for the street reference, so the settings sheet can show the real stamp
/// without a camera frame. Not a photograph.
enum StampSampleScene {
    static func make(extent: CGRect) -> CIImage {
        let width = extent.width
        let height = extent.height
        var image = CIImage(color: CIColor(red: 0.86, green: 0.91, blue: 0.93)).cropped(to: extent)
        image = paint(CGRect(x: 0, y: height * 0.42, width: width * 0.28, height: height * 0.38), CIColor(red: 0.93, green: 0.86, blue: 0.80), image)
        image = paint(CGRect(x: width * 0.22, y: height * 0.48, width: width * 0.22, height: height * 0.34), CIColor(red: 0.78, green: 0.83, blue: 0.86), image)
        image = paint(CGRect(x: width * 0.40, y: height * 0.40, width: width * 0.24, height: height * 0.44), CIColor(red: 0.91, green: 0.78, blue: 0.74), image)
        image = paint(CGRect(x: width * 0.62, y: height * 0.46, width: width * 0.38, height: height * 0.36), CIColor(red: 0.95, green: 0.90, blue: 0.82), image)
        image = paint(CGRect(x: 0, y: 0, width: width, height: height * 0.46), CIColor(red: 0.80, green: 0.67, blue: 0.64), image)
        let mark = CIColor(red: 0.95, green: 0.78, blue: 0.22)
        image = paint(CGRect(x: width * 0.16, y: height * 0.22, width: width * 0.12, height: max(2, height * 0.012)), mark, image)
        image = paint(CGRect(x: width * 0.40, y: height * 0.22, width: width * 0.12, height: max(2, height * 0.012)), mark, image)
        image = paint(CGRect(x: width * 0.64, y: height * 0.22, width: width * 0.12, height: max(2, height * 0.012)), mark, image)
        image = paint(CGRect(x: width * 0.08, y: height * 0.24, width: width * 0.28, height: height * 0.16), CIColor(red: 0.82, green: 0.28, blue: 0.18), image)
        image = paint(CGRect(x: width * 0.10, y: height * 0.33, width: width * 0.24, height: height * 0.032), CIColor(red: 0.22, green: 0.40, blue: 0.68), image)
        image = paint(CGRect(x: width * 0.50, y: height * 0.16, width: width * 0.34, height: height * 0.18), CIColor(red: 0.89, green: 0.40, blue: 0.22), image)
        image = paint(CGRect(x: width * 0.53, y: height * 0.27, width: width * 0.28, height: height * 0.034), CIColor(red: 0.20, green: 0.36, blue: 0.62), image)
        return image
    }

    private static func paint(_ rect: CGRect, _ color: CIColor, _ image: CIImage) -> CIImage {
        CIImage(color: color).cropped(to: rect).composited(over: image)
    }
}
