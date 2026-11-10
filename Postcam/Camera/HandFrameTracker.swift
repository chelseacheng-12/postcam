import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Finds the two-hand director's frame and returns a soft mask of the window inside it.
/// Vision runs on every third frame. The quad is smoothed, and the mask fades out when the pose drops.
final class HandFrameTracker {
    private let request: VNDetectHumanHandPoseRequest
    private let still: Bool
    private var frameIndex = 0
    private var smoothed: [CGPoint] = []
    private var opacity: CGFloat = 0
    private var lastHit = CFAbsoluteTime(0)
    private var lastClock = CFAbsoluteTime(0)

    /// `still` is for a single imported photo: a found frame is applied at full strength, with no fade.
    init(still: Bool = false) {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        self.request = request
        self.still = still
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

    func mask(for image: CIImage) -> CIImage? {
        let source = image.normalizedOrigin()
        let extent = source.extent
        guard extent.width > 2, extent.height > 2 else { return nil }
        frameIndex += 1
        if frameIndex % 3 == 1 {
            detect(in: source)
        }
        tickOpacity()
        guard opacity > 0.03, smoothed.count == 4 else { return nil }
        return quadMask(smoothed, extent: extent, opacity: opacity)
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
        let aspect = image.extent.width / max(image.extent.height, 1)
        guard let observations = request.results,
              let quad = FramingPose.quad(from: observations, aspect: aspect) else {
            return
        }
        adopt(quad)
    }

    private func adopt(_ quad: [CGPoint]) {
        lastHit = CFAbsoluteTimeGetCurrent()
        if smoothed.count == quad.count {
            let next = FramingPose.aligned(quad, to: smoothed)
            let eased = zip(smoothed, next).map { old, new in
                CGPoint(
                    x: old.x * 0.62 + new.x * 0.38,
                    y: old.y * 0.62 + new.y * 0.38
                )
            }
            smoothed = FramingPose.isConvexCounterClockwise(eased) ? eased : quad
        } else {
            smoothed = quad
        }
        opacity = still ? 1 : min(1, opacity + 0.45)
    }

    /// Fade is based on time, so a dropped pose leaves in under half a second at any frame rate.
    private func tickOpacity() {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = lastClock == 0 ? 0 : now - lastClock
        lastClock = now
        if !still, now - lastHit > 0.15 {
            opacity = max(0, opacity - CGFloat(dt) * 2.6)
        }
        if opacity == 0 {
            smoothed = []
        }
    }

    /// Built in Core Image space, which is the same y-up space as Vision's normalized points,
    /// so the window lands on the hands without any bitmap flip.
    private func quadMask(_ points: [CGPoint], extent: CGRect, opacity: CGFloat) -> CIImage {
        let corners = points.map { point in
            CGPoint(
                x: extent.minX + point.x * extent.width,
                y: extent.minY + point.y * extent.height
            )
        }
        let tile = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: opacity))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        // Corners are counterclockwise from the first point, matching BL, BR, TR, TL of the tile.
        let quad = tile.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputBottomLeft": CIVector(cgPoint: corners[0]),
            "inputBottomRight": CIVector(cgPoint: corners[1]),
            "inputTopRight": CIVector(cgPoint: corners[2]),
            "inputTopLeft": CIVector(cgPoint: corners[3])
        ])
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        let radius = max(4, extent.width * 0.012)
        return quad.cropped(to: extent)
            .composited(over: clear)
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
    }
}

/// Director's frame from the reference photos.
/// Each hand is an L: thumb and index extended at roughly a right angle, other fingers ignored.
/// The two L's sit opposite each other. Each index tip meets, or comes near, the other hand's
/// thumb tip, closing a rectangle. Either hand may own the top edge. Rotation does not matter.
enum FramingPose {
    struct HandL {
        var indexTip: CGPoint
        var thumbTip: CGPoint
        var crotch: CGPoint
    }

    /// Returns four normalized, y-up corners ordered counterclockwise, or nil.
    /// `aspect` is width / height. Geometry runs with x scaled by it, so angles are true angles
    /// on a tall portrait frame.
    static func quad(from observations: [VNHumanHandPoseObservation], aspect: CGFloat) -> [CGPoint]? {
        let scaleX = max(aspect, 0.05)
        let hands = observations.compactMap { handL(from: $0, scaleX: scaleX) }
        guard hands.count >= 2 else { return nil }
        guard let square = directorQuad(hands[0], hands[1]) else { return nil }
        let inset = insetTowardCenter(square, factor: 0.9)
        let normalized = inset.map { CGPoint(x: $0.x / scaleX, y: $0.y) }
        guard isConvexCounterClockwise(normalized), area(normalized) > 0.012 else { return nil }
        return normalized
    }

    /// Rotates the new quad so each corner pairs with the nearest corner from the previous frame.
    static func aligned(_ points: [CGPoint], to previous: [CGPoint]) -> [CGPoint] {
        guard points.count == previous.count, points.count > 1 else { return points }
        var best = points
        var bestScore = CGFloat.greatestFiniteMagnitude
        for shift in 0..<points.count {
            var rotated: [CGPoint] = []
            rotated.reserveCapacity(points.count)
            for offset in 0..<points.count {
                rotated.append(points[(shift + offset) % points.count])
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
        return best
    }

    static func isConvexCounterClockwise(_ points: [CGPoint]) -> Bool {
        guard points.count >= 3 else { return false }
        for index in points.indices {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            let c = points[(index + 2) % points.count]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if cross <= 0 { return false }
        }
        return true
    }

    private static func handL(from observation: VNHumanHandPoseObservation, scaleX: CGFloat) -> HandL? {
        let indexTipPoint = joint(.indexTip, observation, minimum: 0.1)
        let thumbTipPoint = joint(.thumbTip, observation, minimum: 0.1)
        let indexBasePoint = joint(.indexMCP, observation, minimum: 0.08) ?? joint(.indexPIP, observation, minimum: 0.08)
        let thumbBasePoint = joint(.thumbMP, observation, minimum: 0.08) ?? joint(.thumbIP, observation, minimum: 0.08)
        guard let indexTipPoint, let thumbTipPoint, let indexBasePoint, let thumbBasePoint else { return nil }

        let indexTip = CGPoint(x: indexTipPoint.x * scaleX, y: indexTipPoint.y)
        let thumbTip = CGPoint(x: thumbTipPoint.x * scaleX, y: thumbTipPoint.y)
        let indexMCP = CGPoint(x: indexBasePoint.x * scaleX, y: indexBasePoint.y)
        let thumbMCP = CGPoint(x: thumbBasePoint.x * scaleX, y: thumbBasePoint.y)

        let indexLength = distance(indexTip, indexMCP)
        let thumbLength = distance(thumbTip, thumbMCP)
        let opening = distance(indexTip, thumbTip)
        guard indexLength > 0.02, thumbLength > 0.015, opening > 0.03 else { return nil }
        let indexDirection = CGPoint(x: indexTip.x - indexMCP.x, y: indexTip.y - indexMCP.y)
        let thumbDirection = CGPoint(x: thumbTip.x - thumbMCP.x, y: thumbTip.y - thumbMCP.y)
        let degrees = angleDegrees(indexDirection, thumbDirection)
        // About a right angle, with a wide allowance for perspective and a loose L.
        guard degrees > 35, degrees < 155 else { return nil }
        return HandL(indexTip: indexTip, thumbTip: thumbTip, crotch: midpoint(indexMCP, thumbMCP))
    }

    /// Corners are the two L crotches (between thumb MCP and index MCP) and the two places
    /// where the fingertips meet.
    private static func directorQuad(_ a: HandL, _ b: HandL) -> [CGPoint]? {
        let span = distance(a.crotch, b.crotch)
        guard span > 0.05 else { return nil }
        let cross = distance(a.indexTip, b.thumbTip) + distance(a.thumbTip, b.indexTip)
        let same = distance(a.indexTip, b.indexTip) + distance(a.thumbTip, b.thumbTip)
        let closing = min(cross, same)
        let facing = opensToward(a, b.crotch) && opensToward(b, a.crotch)
        // Fingertips do not have to touch. Facing L's get more room than loosely placed ones.
        let allowance = facing ? span * 1.1 + 0.08 : span * 0.6 + 0.04
        guard closing < allowance else { return nil }

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
        let sweep = signedAngle(from: start, to: end)
        let delta = signedAngle(from: start, to: target)
        let slack: CGFloat = 0.65
        if sweep >= 0 {
            return delta >= -slack && delta <= sweep + slack
        }
        return delta <= slack && delta >= sweep - slack
    }

    private static func signedAngle(from start: CGFloat, to end: CGFloat) -> CGFloat {
        var delta = end - start
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return delta
    }

    /// Ascending angle around the centroid is counterclockwise in y-up space.
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
