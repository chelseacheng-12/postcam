import CoreGraphics
import CoreImage
import Foundation
import UIKit
import Vision

/// Finds the two-hand director's frame and returns a soft mask of the window inside it.
/// Vision runs on every third frame. The quad is smoothed, and the mask fades out when the pose drops.
final class HandFrameTracker {
    private let request: VNDetectHumanHandPoseRequest
    private var frameIndex = 0
    private var smoothed: [CGPoint] = []
    private var opacity: CGFloat = 0
    private var lastHit = CFAbsoluteTime(0)
    private var lastClock = CFAbsoluteTime(0)

    init() {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        self.request = request
    }

    /// Sonny Boy inside the hand window. The rest of the frame stays the camera image.
    func styled(_ image: CIImage) -> CIImage {
        let source = image.normalizedOrigin()
        guard let mask = mask(for: source) else { return source }
        let stylized = SonnyBoyStyle.apply(to: source)
        return stylized.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: source,
            kCIInputMaskImageKey: mask
        ]).cropped(to: source.extent)
    }

    /// Normalized points are y-up, matching the upright camera image.
    func mask(for image: CIImage) -> CIImage? {
        let extent = image.normalizedOrigin().extent
        frameIndex += 1
        if frameIndex % 3 == 1 {
            detect(in: image.normalizedOrigin())
        }
        tickOpacity()
        guard opacity > 0.03, smoothed.count >= 3, extent.width > 2, extent.height > 2 else {
            return nil
        }
        return rasterize(points: smoothed, extent: extent, opacity: opacity)
    }

    private func detect(in image: CIImage) {
        let longest = max(image.extent.width, image.extent.height)
        let scale = min(1, 480 / max(longest, 1))
        let small = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .normalizedOrigin()
        let handler = VNImageRequestHandler(ciImage: small, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return
        }
        guard let observations = request.results,
              let polygon = FramingPose.polygon(from: observations) else {
            return
        }
        adopt(polygon)
    }

    private func adopt(_ polygon: [CGPoint]) {
        lastHit = CFAbsoluteTimeGetCurrent()
        if smoothed.count == polygon.count, !smoothed.isEmpty {
            let next = FramingPose.aligned(polygon, to: smoothed)
            smoothed = zip(smoothed, next).map { old, new in
                CGPoint(
                    x: old.x * 0.62 + new.x * 0.38,
                    y: old.y * 0.62 + new.y * 0.38
                )
            }
        } else {
            smoothed = polygon
        }
        opacity = min(1, opacity + 0.45)
    }

    /// Fade is based on time, so a dropped pose leaves in under half a second at any frame rate.
    private func tickOpacity() {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = lastClock == 0 ? 0 : now - lastClock
        lastClock = now
        if now - lastHit > 0.15 {
            opacity = max(0, opacity - CGFloat(dt) * 2.6)
        }
        if opacity == 0 {
            smoothed = []
        }
    }

    private func rasterize(points: [CGPoint], extent: CGRect, opacity: CGFloat) -> CIImage? {
        let width = Int(extent.width.rounded(.down))
        let height = Int(extent.height.rounded(.down))
        guard width > 2, height > 2 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(UIColor(white: 1, alpha: opacity).cgColor)
        context.beginPath()
        let first = points[0]
        context.move(to: CGPoint(x: first.x * CGFloat(width), y: first.y * CGFloat(height)))
        for point in points.dropFirst() {
            context.addLine(to: CGPoint(x: point.x * CGFloat(width), y: point.y * CGFloat(height)))
        }
        context.closePath()
        context.fillPath()
        guard let cgImage = context.makeImage() else { return nil }
        let mask = CIImage(cgImage: cgImage).oriented(.downMirrored).normalizedOrigin()
        return mask.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 10])
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }
}

/// Director's frame from the reference photos.
/// Each hand is an L: thumb and index extended, other fingers ignored.
/// The two L's sit opposite each other. One hand's index tip meets the other hand's thumb tip,
/// and the remaining pair of tips meets as well, closing a rectangle. Either hand may own the
/// top edge. Rotation does not matter.
enum FramingPose {
    struct HandL {
        var indexTip: CGPoint
        var thumbTip: CGPoint
        var indexMCP: CGPoint
        var thumbMCP: CGPoint
        var crotch: CGPoint
    }

    static func polygon(from observations: [VNHumanHandPoseObservation]) -> [CGPoint]? {
        let hands = observations.compactMap { handL(from: $0) }
        guard hands.count >= 2 else { return nil }
        guard let quad = directorQuad(hands[0], hands[1]) else { return nil }
        guard area(quad) > 0.012 else { return nil }
        return insetTowardCenter(quad, factor: 0.9)
    }

    /// Rotate and reverse so this quad's corners stay paired with the previous frame.
    static func aligned(_ points: [CGPoint], to previous: [CGPoint]) -> [CGPoint] {
        guard points.count == previous.count, points.count > 1 else { return points }
        let rings = [points, Array(points.reversed())]
        var best = points
        var bestScore = CGFloat.greatestFiniteMagnitude
        for ring in rings {
            for shift in 0..<ring.count {
                var rotated: [CGPoint] = []
                rotated.reserveCapacity(ring.count)
                for offset in 0..<ring.count {
                    rotated.append(ring[(shift + offset) % ring.count])
                }
                var score: CGFloat = 0
                for index in rotated.indices {
                    score += distance(rotated[index], previous[index])
                }
                if score < bestScore {
                    bestScore = score
                    best = rotated
                }
            }
        }
        return best
    }

    private static func handL(from observation: VNHumanHandPoseObservation) -> HandL? {
        let indexTip = joint(.indexTip, observation, minimum: 0.1)
        let thumbTip = joint(.thumbTip, observation, minimum: 0.1)
        let indexMCP = joint(.indexMCP, observation, minimum: 0.08) ?? joint(.indexPIP, observation, minimum: 0.08)
        let thumbMCP = joint(.thumbMP, observation, minimum: 0.08) ?? joint(.thumbIP, observation, minimum: 0.08)
        guard let indexTip, let thumbTip, let indexMCP, let thumbMCP else { return nil }
        let indexLength = distance(indexTip, indexMCP)
        let thumbLength = distance(thumbTip, thumbMCP)
        let opening = distance(indexTip, thumbTip)
        guard indexLength > 0.025, thumbLength > 0.02, opening > 0.04 else { return nil }
        let indexDirection = CGPoint(x: indexTip.x - indexMCP.x, y: indexTip.y - indexMCP.y)
        let thumbDirection = CGPoint(x: thumbTip.x - thumbMCP.x, y: thumbTip.y - thumbMCP.y)
        let degrees = angleDegrees(indexDirection, thumbDirection)
        // About a right angle, with a wide allowance for perspective and a loose L.
        guard degrees > 35, degrees < 155 else { return nil }
        let crotch = midpoint(indexMCP, thumbMCP)
        return HandL(
            indexTip: indexTip,
            thumbTip: thumbTip,
            indexMCP: indexMCP,
            thumbMCP: thumbMCP,
            crotch: crotch
        )
    }

    /// Corners are the two L crotches (thumb MCP + index MCP) and the two places the tips meet.
    private static func directorQuad(_ a: HandL, _ b: HandL) -> [CGPoint]? {
        let facing = opensToward(a, b.crotch) && opensToward(b, a.crotch)
        let cross = distance(a.indexTip, b.thumbTip) + distance(a.thumbTip, b.indexTip)
        let same = distance(a.indexTip, b.indexTip) + distance(a.thumbTip, b.thumbTip)
        let span = distance(a.crotch, b.crotch)
        let closing = min(cross, same)
        let near = span > 0.05 && closing < max(0.5, span * 1.2)
        guard facing || near else { return nil }

        let indexMeetsThumb = cross <= same
        let meetA = indexMeetsThumb ? midpoint(a.indexTip, b.thumbTip) : midpoint(a.indexTip, b.indexTip)
        let meetB = indexMeetsThumb ? midpoint(a.thumbTip, b.indexTip) : midpoint(a.thumbTip, b.thumbTip)
        return orderAroundCenter([a.crotch, meetA, b.crotch, meetB])
    }

    /// The other L's corner should sit in the opening of this L. Slack covers a tilted camera.
    private static func opensToward(_ hand: HandL, _ point: CGPoint) -> Bool {
        if distance(hand.crotch, point) < 0.04 { return true }
        let start = atan2(hand.indexTip.y - hand.crotch.y, hand.indexTip.x - hand.crotch.x)
        let end = atan2(hand.thumbTip.y - hand.crotch.y, hand.thumbTip.x - hand.crotch.x)
        let target = atan2(point.y - hand.crotch.y, point.x - hand.crotch.x)
        let span = signedAngle(from: start, to: end)
        let delta = signedAngle(from: start, to: target)
        let slack: CGFloat = 0.65
        if span >= 0 {
            return delta >= -slack && delta <= span + slack
        }
        return delta <= slack && delta >= span - slack
    }

    private static func signedAngle(from start: CGFloat, to end: CGFloat) -> CGFloat {
        var delta = end - start
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return delta
    }

    private static func orderAroundCenter(_ points: [CGPoint]) -> [CGPoint] {
        let centerX = points.reduce(CGFloat(0)) { $0 + $1.x } / CGFloat(points.count)
        let centerY = points.reduce(CGFloat(0)) { $0 + $1.y } / CGFloat(points.count)
        return points.sorted { lhs, rhs in
            atan2(lhs.y - centerY, lhs.x - centerX) < atan2(rhs.y - centerY, rhs.x - centerX)
        }
    }

    private static func insetTowardCenter(_ points: [CGPoint], factor: CGFloat) -> [CGPoint] {
        let centerX = points.reduce(CGFloat(0)) { $0 + $1.x } / CGFloat(points.count)
        let centerY = points.reduce(CGFloat(0)) { $0 + $1.y } / CGFloat(points.count)
        return points.map { point in
            CGPoint(
                x: centerX + (point.x - centerX) * factor,
                y: centerY + (point.y - centerY) * factor
            )
        }
    }

    private static func area(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 3 else { return 0 }
        var sum: CGFloat = 0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            sum += points[index].x * next.y - next.x * points[index].y
        }
        return abs(sum) * 0.5
    }

    private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) * 0.5, y: (a.y + b.y) * 0.5)
    }

    private static func joint(
        _ name: VNHumanHandPoseObservation.JointName,
        _ observation: VNHumanHandPoseObservation,
        minimum: Float
    ) -> CGPoint? {
        guard let point = try? observation.recognizedPoint(name), point.confidence >= minimum else {
            return nil
        }
        return point.location
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func angleDegrees(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dot = a.x * b.x + a.y * b.y
        let magnitude = hypot(a.x, a.y) * hypot(b.x, b.y)
        guard magnitude > 0.0001 else { return 0 }
        let cosine = min(1, max(-1, dot / magnitude))
        return acos(cosine) * 180 / .pi
    }
}
