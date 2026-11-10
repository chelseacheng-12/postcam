import CoreGraphics
import CoreImage
import Foundation

/// Hand-made art for the Sonny Boy sky: a painted cumulus sheet and a whale, both drawn in code
/// with Core Graphics so nothing copyrighted ships with the app. Drawn once and reused.
enum SonnyBoyArt {
    enum Knob {
        /// Whale width as a share of the hand window's width.
        static let whaleWidth: CGFloat = 0.58
        /// Seconds for the whale to swim across the window.
        static let whaleCrossing: Double = 38
        static let whaleBob: CGFloat = 0.015
        /// Cloud sheet width as a share of the window's width.
        static let cloudWidth: CGFloat = 1.15

        static let cloudDeep = (red: CGFloat(0.60), green: CGFloat(0.70), blue: CGFloat(0.91))
        static let cloudShade = (red: CGFloat(0.72), green: CGFloat(0.80), blue: CGFloat(0.95))
        static let cloudBody = (red: CGFloat(0.95), green: CGFloat(0.97), blue: CGFloat(1.0))

        static let whaleBack = (red: CGFloat(0.29), green: CGFloat(0.39), blue: CGFloat(0.60))
        static let whaleBackLight = (red: CGFloat(0.42), green: CGFloat(0.53), blue: CGFloat(0.74))
        static let whaleBelly = (red: CGFloat(0.95), green: CGFloat(0.96), blue: CGFloat(0.99))
        static let whaleGroove = (red: CGFloat(0.70), green: CGFloat(0.76), blue: CGFloat(0.88))
        static let whaleInk = (red: CGFloat(0.12), green: CGFloat(0.15), blue: CGFloat(0.28))

        /// Soft contact shadow under floating copies.
        static let shadowColor = CIColor(red: 0.22, green: 0.27, blue: 0.42, alpha: 0.42)
    }

    static let whaleSize = CGSize(width: 1024, height: 512)
    static let cloudSize = CGSize(width: 1024, height: 640)

    /// Facing left, transparent around the body.
    static let whale: CIImage = drawWhale()

    // MARK: - Placing

    /// The cloud sheet repeated sideways along a band whose bottom sits at `bottom`.
    /// Only one row, so clouds never repeat above themselves.
    static func cloudBand(_ sheet: CIImage, over extent: CGRect, window: CGRect, bottom: CGFloat, shift: CGFloat) -> CIImage {
        let source = sheet.normalizedOrigin()
        guard source.extent.width > 1, source.extent.height > 1 else { return clear(extent) }
        let width = max(window.width * Knob.cloudWidth, 64)
        let scale = width / source.extent.width
        let height = source.extent.height * scale
        let offset = shift.truncatingRemainder(dividingBy: width)
        let band = CGRect(x: extent.minX, y: bottom, width: extent.width, height: height).intersection(extent)
        guard !band.isNull, band.height > 1 else { return clear(extent) }
        return source
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .applyingFilter("CIAffineTile")
            .transformed(by: CGAffineTransform(translationX: window.minX - offset, y: bottom))
            .cropped(to: band)
    }

    /// The whale swimming right to left across `window`, high in the sky part.
    /// `phase` (0..<1) picks where along its path it starts, so each framing differs.
    static func swimmingWhale(in window: CGRect, horizonY: CGFloat, time: CFTimeInterval, phase: Double, extent: CGRect) -> CIImage {
        let art = whale
        guard art.extent.width > 1, window.width > 8 else { return clear(extent) }
        let width = window.width * Knob.whaleWidth
        let scale = width / art.extent.width
        let height = art.extent.height * scale
        let progress = CGFloat((time / Knob.whaleCrossing + phase).truncatingRemainder(dividingBy: 1))
        let x = window.maxX - progress * (window.width + width)
        let skyTop = max(window.maxY, horizonY + height)
        let bob = CGFloat(sin(time * 0.7 + phase * 6)) * window.height * Knob.whaleBob
        let y = horizonY + (skyTop - horizonY) * 0.5 - height * 0.5 + bob
        return art
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: x, y: y))
            .cropped(to: extent)
    }

    /// Soft oval shadow centered at `center`, `width` wide and flattened.
    static func contactShadow(center: CGPoint, width: CGFloat, strength: CGFloat, extent: CGRect) -> CIImage {
        let radius = max(width * 0.5, 4)
        let color = Knob.shadowColor
        let parameters: [String: Any] = [
            "inputCenter": CIVector(x: 0, y: 0),
            "inputRadius0": radius * 0.35,
            "inputRadius1": radius,
            "inputColor0": CIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha * strength),
            "inputColor1": CIColor(red: color.red, green: color.green, blue: color.blue, alpha: 0)
        ]
        guard let gradient = CIFilter(name: "CIRadialGradient", parameters: parameters)?.outputImage else {
            return clear(extent)
        }
        return gradient
            .transformed(by: CGAffineTransform(scaleX: 1, y: 0.22))
            .transformed(by: CGAffineTransform(translationX: center.x, y: center.y))
            .cropped(to: extent)
    }

    static func clear(_ extent: CGRect) -> CIImage {
        CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
    }

    // MARK: - Clouds

    /// Two or three big cumulus heads with flat bases, painted in four flat tones:
    /// a deep rim, a blue shade underneath, the white body, and bright highlights on top.
    static func paintedClouds(_ rng: inout SplitMix64) -> CIImage {
        let width = Int(cloudSize.width)
        let height = Int(cloudSize.height)
        guard let context = SonnyBoyTextures.canvas(width: width, height: height) else {
            return clear(CGRect(origin: .zero, size: cloudSize))
        }
        context.clear(CGRect(origin: .zero, size: cloudSize))
        let count = 2 + Int(rng.unit() * 1.99)
        let slot = cloudSize.width / CGFloat(count)
        for index in 0..<count {
            let cloudWidth = slot * (0.7 + rng.unit() * 0.22)
            let center = slot * (CGFloat(index) + 0.5)
            let base = cloudSize.height * (0.06 + rng.unit() * 0.3)
            let tall = cloudWidth * (0.5 + rng.unit() * 0.3)
            paintCloud(context, rng: &rng, center: center, base: base, width: cloudWidth, tall: tall)
        }
        return SonnyBoyTextures.finish(context, width: width, height: height)
    }

    private struct Puff {
        var center: CGPoint
        var radius: CGFloat
        var isBase: Bool
    }

    private static func paintCloud(_ context: CGContext, rng: inout SplitMix64, center: CGFloat, base: CGFloat, width: CGFloat, tall: CGFloat) {
        var puffs: [Puff] = []
        for _ in 0..<22 {
            let u = rng.unit()
            let dome = sqrt(max(0, 1 - (2 * u - 1) * (2 * u - 1)))
            let x = center - width / 2 + width * u
            let y = base + tall * dome * (0.15 + rng.unit() * 0.6)
            let radius = width * (0.07 + 0.11 * dome) * (0.75 + rng.unit() * 0.5)
            puffs.append(Puff(center: CGPoint(x: x, y: y), radius: radius, isBase: false))
        }
        for index in 0..<6 {
            let u = 0.1 + 0.8 * (CGFloat(index) + 0.5) / 6
            let radius = width * 0.085 * (0.8 + rng.unit() * 0.4)
            puffs.append(Puff(center: CGPoint(x: center - width / 2 + width * u, y: base + radius * 0.55), radius: radius, isBase: true))
        }
        puffs.sort { $0.center.y < $1.center.y }

        context.saveGState()
        context.clip(to: CGRect(x: 0, y: base, width: cloudSize.width, height: cloudSize.height - base))
        let lift = tall * 0.11
        fill(context, puffs, color: Knob.cloudDeep, dx: 0, dy: -tall * 0.02, scale: 1)
        fill(context, puffs, color: Knob.cloudShade, dx: 0, dy: 0, scale: 0.98)
        fill(context, puffs, color: Knob.cloudBody, dx: -width * 0.015, dy: lift, scale: 0.88)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        for puff in puffs where !puff.isBase {
            let r = puff.radius * 0.5
            let c = CGPoint(x: puff.center.x - puff.radius * 0.2, y: puff.center.y + lift + puff.radius * 0.25)
            context.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
        context.restoreGState()
    }

    private static func fill(
        _ context: CGContext,
        _ puffs: [Puff],
        color: (red: CGFloat, green: CGFloat, blue: CGFloat),
        dx: CGFloat,
        dy: CGFloat,
        scale: CGFloat
    ) {
        context.setFillColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
        for puff in puffs {
            let r = puff.radius * scale
            context.fillEllipse(in: CGRect(x: puff.center.x + dx - r, y: puff.center.y + dy - r, width: r * 2, height: r * 2))
        }
    }

    // MARK: - Whale

    private static func drawWhale() -> CIImage {
        let width = Int(whaleSize.width)
        let height = Int(whaleSize.height)
        guard let context = SonnyBoyTextures.canvas(width: width, height: height) else {
            return clear(CGRect(origin: .zero, size: whaleSize))
        }
        context.clear(CGRect(origin: .zero, size: whaleSize))
        context.setLineJoin(.round)
        context.setLineCap(.round)
        let outline: CGFloat = 3

        fillAndStroke(context, path: dorsalPath(), color: Knob.whaleBack, lineWidth: outline)
        fillAndStroke(context, path: finPath(), color: Knob.whaleBack, lineWidth: outline)

        let body = bodyPath()
        setFill(context, Knob.whaleBack)
        context.addPath(body)
        context.fillPath()

        context.saveGState()
        context.addPath(body)
        context.clip()
        setFill(context, Knob.whaleBackLight)
        context.addPath(backLightPath())
        context.fillPath()
        setFill(context, Knob.whaleBelly)
        context.addPath(bellyPath())
        context.fillPath()
        let groove = Knob.whaleGroove
        context.setStrokeColor(red: groove.red, green: groove.green, blue: groove.blue, alpha: 1)
        context.setLineWidth(2)
        for index in 0..<7 {
            let i = CGFloat(index)
            let y = 0.44 - i * 0.022
            context.beginPath()
            context.move(to: point(0.09 + i * 0.015, y))
            context.addCurve(
                to: point(0.50 - i * 0.035, y - 0.005),
                control1: point(0.22, y - 0.025),
                control2: point(0.36, y - 0.03)
            )
            context.strokePath()
        }
        context.restoreGState()

        setStroke(context, Knob.whaleInk)
        context.setLineWidth(outline)
        context.addPath(body)
        context.strokePath()

        fillAndStroke(context, path: flukesPath(), color: Knob.whaleBack, lineWidth: outline)

        setFill(context, Knob.whaleInk)
        context.fillEllipse(in: CGRect(
            x: 0.16 * whaleSize.width - 10,
            y: 0.52 * whaleSize.height - 10,
            width: 20,
            height: 20
        ))
        setStroke(context, Knob.whaleInk)
        context.setLineWidth(2.5)
        context.beginPath()
        context.move(to: point(0.055, 0.49))
        context.addCurve(to: point(0.20, 0.48), control1: point(0.10, 0.47), control2: point(0.14, 0.47))
        context.strokePath()

        return SonnyBoyTextures.finish(context, width: width, height: height)
    }

    /// `x` and `y` are shares of the whale canvas, y-up.
    private static func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * whaleSize.width, y: y * whaleSize.height)
    }

    private static func setFill(_ context: CGContext, _ color: (red: CGFloat, green: CGFloat, blue: CGFloat)) {
        context.setFillColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
    }

    private static func setStroke(_ context: CGContext, _ color: (red: CGFloat, green: CGFloat, blue: CGFloat)) {
        context.setStrokeColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
    }

    private static func fillAndStroke(
        _ context: CGContext,
        path: CGPath,
        color: (red: CGFloat, green: CGFloat, blue: CGFloat),
        lineWidth: CGFloat
    ) {
        setFill(context, color)
        context.addPath(path)
        context.fillPath()
        setStroke(context, Knob.whaleInk)
        context.setLineWidth(lineWidth)
        context.addPath(path)
        context.strokePath()
    }

    private static func bodyPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: point(0.05, 0.50))
        path.addCurve(to: point(0.44, 0.72), control1: point(0.07, 0.66), control2: point(0.24, 0.74))
        path.addCurve(to: point(0.84, 0.55), control1: point(0.62, 0.70), control2: point(0.74, 0.62))
        path.addCurve(to: point(0.885, 0.535), control1: point(0.86, 0.54), control2: point(0.875, 0.535))
        path.addLine(to: point(0.885, 0.495))
        path.addCurve(to: point(0.52, 0.34), control1: point(0.80, 0.47), control2: point(0.70, 0.38))
        path.addCurve(to: point(0.07, 0.43), control1: point(0.34, 0.30), control2: point(0.12, 0.33))
        path.addCurve(to: point(0.05, 0.50), control1: point(0.055, 0.46), control2: point(0.05, 0.48))
        path.closeSubpath()
        return path
    }

    private static func backLightPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: point(0.10, 0.64))
        path.addCurve(to: point(0.80, 0.60), control1: point(0.25, 0.73), control2: point(0.55, 0.73))
        path.addCurve(to: point(0.10, 0.64), control1: point(0.55, 0.67), control2: point(0.28, 0.68))
        path.closeSubpath()
        return path
    }

    private static func bellyPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: point(0.04, 0.475))
        path.addCurve(to: point(0.60, 0.41), control1: point(0.20, 0.47), control2: point(0.42, 0.44))
        path.addCurve(to: point(0.90, 0.47), control1: point(0.70, 0.395), control2: point(0.78, 0.40))
        path.addLine(to: point(0.90, 0))
        path.addLine(to: point(0, 0))
        path.closeSubpath()
        return path
    }

    private static func flukesPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: point(0.86, 0.545))
        path.addCurve(to: point(0.985, 0.74), control1: point(0.90, 0.60), control2: point(0.93, 0.70))
        path.addCurve(to: point(0.93, 0.53), control1: point(0.975, 0.66), control2: point(0.955, 0.60))
        path.addCurve(to: point(0.995, 0.33), control1: point(0.96, 0.47), control2: point(0.985, 0.40))
        path.addCurve(to: point(0.86, 0.49), control1: point(0.94, 0.37), control2: point(0.91, 0.43))
        path.closeSubpath()
        return path
    }

    private static func finPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: point(0.25, 0.40))
        path.addCurve(to: point(0.42, 0.17), control1: point(0.29, 0.30), control2: point(0.34, 0.22))
        path.addCurve(to: point(0.35, 0.39), control1: point(0.40, 0.25), control2: point(0.37, 0.33))
        path.closeSubpath()
        return path
    }

    private static func dorsalPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: point(0.66, 0.665))
        path.addCurve(to: point(0.735, 0.73), control1: point(0.69, 0.70), control2: point(0.71, 0.72))
        path.addCurve(to: point(0.725, 0.625), control1: point(0.725, 0.69), control2: point(0.72, 0.66))
        path.closeSubpath()
        return path
    }
}
