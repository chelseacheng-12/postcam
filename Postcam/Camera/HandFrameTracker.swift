import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Finds the two-hand director's frame and returns a hard-edged mask of the window inside it.
/// Vision runs on every other frame. The quad is smoothed, held while at least one hand stays in
/// view, and fades out when the hands leave.
///
/// Hands held right at the lens often show only a thumb and an index finger, and Vision may miss
/// them. Detection tries, in order:
/// 1. Two L-shaped hands (strong; switches the window on at once).
/// 2. Partial hands: one L, or two lone fingers, with the frame edges as the missing sides.
/// 3. The same on a zoomed-out copy of the frame, where big close-up hands fit the detector better.
/// 4. Skin-colored fingers bracketing an empty rectangle from at least three sides.
/// Steps 2–4 must agree for a few detections in a row before the window switches on.
final class HandFrameTracker {
    enum Knob {
        /// Run hand pose on every Nth camera frame.
        static let detectEvery = 2
        /// Longest side of the image handed to Vision. Larger finds small, far hands; close-up
        /// hands are found at any size.
        static let detectLongestSide: CGFloat = 640
        /// More than two so a stray third hand does not hide the pair that forms the frame.
        static let maximumHands = 4
        /// Seconds the last window stays at full strength after the frame breaks, while at least one
        /// hand is still in view (one hand often drops out for a moment when close to the lens).
        static let holdWithOneHand: CFTimeInterval = 0.8
        /// Seconds before fading once no hand at all is in view.
        static let holdWithNoHands: CFTimeInterval = 0.2
        /// Fade-out speed, opacity per second.
        static let fadePerSecond: CGFloat = 2.6
        /// Detections in a row a partial hand frame (one L, two fingers) needs before it shows.
        static let partialConfirm = 2
        /// Detections in a row the skin-color fallback needs before it shows.
        static let skinConfirm = 3
        static let skinFallback = true
        /// The zoomed-out Vision pass shrinks the frame to this share inside a gray border.
        static let zoomOut: CGFloat = 0.62
        /// Width of the grid the skin fallback works on.
        static let skinGridWidth = 72
    }

    private let request: VNDetectHumanHandPoseRequest
    private let context: CIContext
    private let still: Bool
    private let scene: SonnyBoyScene
    private var frameIndex = 0
    private var smoothed: [CGPoint] = []
    private var opacity: CGFloat = 0
    private var lastHit = CFAbsoluteTime(0)
    private var lastHandSeen = CFAbsoluteTime(0)
    private var lastClock = CFAbsoluteTime(0)
    /// Counts hand frames. Each new one picks a new surreal plan; it holds for that framing.
    private var framing = 0
    private var detections = 0
    /// Weak detections in a row.
    private var weakStreak = 0
    private var lastPair = CFAbsoluteTime(0)

    /// `still` is for a single imported photo: a found frame is applied at full strength, with no fade.
    init(context: CIContext, still: Bool = false) {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = Knob.maximumHands
        self.request = request
        self.context = context
        self.still = still
        let seed = still ? 0x5EED_C0DE : UInt64.random(in: 1...UInt64.max)
        scene = SonnyBoyScene(context: context, still: still, seed: seed)
    }

    /// Sonny Boy inside the hand window. The rest of the frame stays the camera image.
    /// `forceFull` draws a window that is still fading at full strength, for photo capture.
    func styled(_ image: CIImage, forceFull: Bool = false) -> CIImage {
        let source = image.normalizedOrigin()
        guard let mask = mask(for: source, forceFull: forceFull) else { return source }
        let stylized = scene.render(
            source,
            horizon: windowHorizon(),
            framing: framing,
            window: windowBounds(),
            waitForModel: forceFull
        )
        return stylized.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: source,
            kCIInputMaskImageKey: mask
        ]).cropped(to: source.extent)
    }

    /// Uploads. A hand frame in the photo limits the effect to its window, like the camera.
    /// Without one, the whole photo gets the scene.
    func styledStill(_ image: CIImage) -> CIImage {
        let source = image.normalizedOrigin()
        if let mask = mask(for: source, forceFull: true) {
            let stylized = scene.render(source, horizon: windowHorizon(), framing: framing, window: windowBounds())
            return stylized.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: source,
                kCIInputMaskImageKey: mask
            ]).cropped(to: source.extent)
        }
        return scene.render(source, horizon: 0.45, framing: framing)
    }

    /// Upper part of the window may turn into sky, the lower part into ground.
    private func windowHorizon() -> CGFloat {
        guard smoothed.count == 4 else { return 0.45 }
        let ys = smoothed.map { $0.y }
        let low = ys.min() ?? 0
        let high = ys.max() ?? 1
        return low + (high - low) * 0.42
    }

    /// Bounding box of the window, 0...1 and y-up, so the sky art is sized to it.
    private func windowBounds() -> CGRect {
        guard smoothed.count == 4 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let xs = smoothed.map { $0.x }
        let ys = smoothed.map { $0.y }
        let minX = max(0, xs.min() ?? 0)
        let minY = max(0, ys.min() ?? 0)
        let maxX = min(1, xs.max() ?? 1)
        let maxY = min(1, ys.max() ?? 1)
        guard maxX > minX, maxY > minY else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func mask(for image: CIImage, forceFull: Bool = false) -> CIImage? {
        let source = image.normalizedOrigin()
        let extent = source.extent
        guard extent.width > 2, extent.height > 2 else { return nil }
        frameIndex += 1
        if Knob.detectEvery <= 1 || frameIndex % Knob.detectEvery == 1 {
            detect(in: source)
        }
        tickOpacity()
        guard opacity > 0.03, smoothed.count == 4 else { return nil }
        return quadMask(smoothed, extent: extent, opacity: forceFull ? 1 : opacity)
    }

    private func detect(in image: CIImage) {
        let longest = max(image.extent.width, image.extent.height)
        let scale = min(1, Knob.detectLongestSide / max(longest, 1))
        let small = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .normalizedOrigin()
        let aspect = image.extent.width / max(image.extent.height, 1)
        detections += 1

        let hands = handPoints(in: small, zoom: 1)
        if !hands.isEmpty {
            lastHandSeen = CFAbsoluteTimeGetCurrent()
        }
        var found = FramingPose.detect(hands, aspect: aspect)
        if let found, found.kind == .pair {
            accept(found)
            return
        }

        // Fallbacks cost a second Vision pass. While no window is up they run every other time.
        let runFallbacks = still || opacity > 0 || detections % 2 == 0
        if runFallbacks {
            let zoomed = handPoints(in: small, zoom: Knob.zoomOut)
            if !zoomed.isEmpty {
                lastHandSeen = CFAbsoluteTimeGetCurrent()
            }
            if let combined = FramingPose.detect(hands + zoomed, aspect: aspect),
               combined.kind == .pair || found == nil {
                found = combined
            }
        }
        if let found {
            accept(found)
            return
        }
        if runFallbacks, Knob.skinFallback, !still, let quad = skinWindow(small) {
            lastHandSeen = CFAbsoluteTimeGetCurrent()
            accept(FramingPose.Detection(quad: quad, kind: .skin))
            return
        }
        if runFallbacks {
            weakStreak = 0
        }
    }

    private func accept(_ detection: FramingPose.Detection) {
        switch detection.kind {
        case .pair:
            weakStreak = 0
            lastPair = CFAbsoluteTimeGetCurrent()
            adopt(detection.quad)
        case .partial, .skin:
            weakStreak += 1
            // A two-hand frame seen a moment ago is better; a partial one would only make the
            // window jump. It still counts as hands in view, which keeps the hold going.
            if CFAbsoluteTimeGetCurrent() - lastPair < Knob.holdWithNoHands * 2.5 {
                lastHit = CFAbsoluteTimeGetCurrent()
                return
            }
            let needed = detection.kind == .skin ? Knob.skinConfirm : Knob.partialConfirm
            if still || opacity > 0 || weakStreak >= needed {
                adopt(detection.quad)
            }
        }
    }

    /// Hand joints from Vision in normalized y-up frame coordinates. With `zoom` below 1 the frame
    /// is shrunk into the middle of a gray canvas first, and points are mapped back.
    private func handPoints(in small: CIImage, zoom: CGFloat) -> [HandPoints] {
        let extent = small.extent
        var input = small
        let offset = (1 - zoom) / 2
        if zoom < 1 {
            let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
            input = small
                .transformed(by: CGAffineTransform(scaleX: zoom, y: zoom))
                .transformed(by: CGAffineTransform(translationX: extent.width * offset, y: extent.height * offset))
                .composited(over: gray)
                .cropped(to: extent)
        }
        let handler = VNImageRequestHandler(ciImage: input, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let observations = request.results ?? []
        return observations.map { observation in
            HandPoints(observation) { point in
                CGPoint(x: (point.x - offset) / zoom, y: (point.y - offset) / zoom)
            }
        }
    }

    /// Skin-color fallback for when Vision sees no hand at all.
    private func skinWindow(_ small: CIImage) -> [CGPoint]? {
        let extent = small.extent
        guard extent.width > 4, extent.height > 4 else { return nil }
        let width = Knob.skinGridWidth
        let height = max(8, Int((CGFloat(width) * extent.height / extent.width).rounded()))
        let grid = small
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width, y: CGFloat(height) / extent.height))
            .normalizedOrigin()
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(
            grid,
            toBitmap: &pixels,
            rowBytes: width * 4,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return SkinFrame.window(rgba: pixels, width: width, height: height)
    }

    private func adopt(_ quad: [CGPoint]) {
        lastHit = CFAbsoluteTimeGetCurrent()
        if opacity == 0 {
            framing += 1
        }
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
        let handInView = now - lastHandSeen < Knob.holdWithNoHands + 0.15
        let hold = handInView ? Knob.holdWithOneHand : Knob.holdWithNoHands
        if !still, now - lastHit > hold {
            opacity = max(0, opacity - CGFloat(dt) * Knob.fadePerSecond)
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
        // No blur: the illustrated window meets the photo on a crisp, antialiased edge.
        return quad.cropped(to: extent)
            .composited(over: clear)
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

    struct Detection {
        enum Kind {
            /// Two L's closing a frame.
            case pair
            /// One L or two lone fingers, with frame edges as the missing sides.
            case partial
            /// Skin-color fallback.
            case skin
        }

        var quad: [CGPoint]
        var kind: Kind
    }

    /// One finger as a segment from a lower joint to its tip, in aspect-scaled space.
    struct Finger {
        var tip: CGPoint
        var base: CGPoint
        /// The base is the knuckle where the finger meets the hand, not a joint partway up.
        var rooted: Bool
    }

    /// Returns four normalized, y-up corners ordered counterclockwise, or nil.
    /// `aspect` is width / height. Geometry runs with x scaled by it, so angles are true angles
    /// on a tall portrait frame.
    enum Knob {
        /// Vision confidence a fingertip and a finger base need. Low, because hands close to the lens
        /// or at the frame edge come back with weak but usable points.
        static let tipConfidence: Float = 0.04
        static let baseConfidence: Float = 0.03
        /// Allowed angle between thumb and index, degrees. Wide for perspective and loose L's.
        static let minimumAngle: CGFloat = 20
        static let maximumAngle: CGFloat = 170
        /// Corners are pulled toward the center by this factor so the window sits inside the fingers.
        static let inset: CGFloat = 0.95
        /// Smallest window, as a share of the frame. There is no largest; big windows are clamped.
        static let minimumArea: CGFloat = 0.004
        /// Partial frames (one L, two fingers) need a bigger window and a squarer angle, so a hand
        /// waved past the lens does not count.
        static let partialMinimumArea: CGFloat = 0.06
        static let partialMinimumAngle: CGFloat = 50
        static let partialMaximumAngle: CGFloat = 130
        static let partialFingerLength: CGFloat = 0.04
        /// Each arm of a partial L, from its corner to the fingertip. Close-up fingers are long.
        static let partialArm: CGFloat = 0.1
        /// Two lone fingers this close to parallel (degrees) bound a band; this far apart (share
        /// of the frame) at least.
        static let parallelAngle: CGFloat = 30
        static let parallelGap: CGFloat = 0.12
    }

    /// Best window from all hands: a pair of L's first, then one L, then two lone fingers.
    static func detect(_ hands: [HandPoints], aspect: CGFloat) -> Detection? {
        let scaleX = max(aspect, 0.05)
        let ls = hands.map { handL(from: $0, scaleX: scaleX) }
        let found = ls.compactMap { $0 }
        if let quad = pairQuad(found, scaleX: scaleX) {
            return Detection(quad: quad, kind: .pair)
        }

        var best: [CGPoint]?
        var bestArea: CGFloat = 0
        func consider(_ square: [CGPoint]?) {
            guard let square else { return }
            let window = clampedToFrame(square.map { CGPoint(x: $0.x / scaleX, y: $0.y) })
            let size = area(window)
            guard isConvexCounterClockwise(window), size > Knob.partialMinimumArea, size > bestArea else { return }
            best = window
            bestArea = size
        }
        for hand in found {
            consider(openL(corner: hand.crotch, toward: hand.indexTip, and: hand.thumbTip, scaleX: scaleX))
        }
        // Lone fingers come from hands that did not make an L.
        var lone: [(hand: Int, finger: Finger)] = []
        for (index, hand) in hands.enumerated() where ls[index] == nil {
            if let finger = finger(index: true, hand, scaleX: scaleX) { lone.append((index, finger)) }
            if let finger = finger(index: false, hand, scaleX: scaleX) { lone.append((index, finger)) }
        }
        if lone.count >= 2 {
            for first in 0..<(lone.count - 1) {
                for second in (first + 1)..<lone.count where lone[first].hand != lone[second].hand {
                    consider(fingerQuad(lone[first].finger, lone[second].finger, scaleX: scaleX))
                }
            }
        }
        guard let best else { return nil }
        return Detection(quad: best, kind: .partial)
    }

    /// Every pair of L-shaped hands is tried; the largest window wins.
    private static func pairQuad(_ hands: [HandL], scaleX: CGFloat) -> [CGPoint]? {
        guard hands.count >= 2 else { return nil }
        var best: [CGPoint]?
        var bestArea: CGFloat = 0
        for first in 0..<(hands.count - 1) {
            for second in (first + 1)..<hands.count {
                guard let square = directorQuad(hands[first], hands[second]) else { continue }
                let inset = insetTowardCenter(square, factor: Knob.inset)
                let normalized = inset.map { CGPoint(x: $0.x / scaleX, y: $0.y) }
                let window = clampedToFrame(normalized)
                let size = area(window)
                guard isConvexCounterClockwise(window), size > Knob.minimumArea, size > bestArea else { continue }
                best = window
                bestArea = size
            }
        }
        return best
    }

    /// An L whose corner is `corner` and whose arms point at `a` and `b`, run out to the frame edges.
    /// The fourth corner completes the parallelogram.
    private static func openL(corner: CGPoint, toward a: CGPoint, and b: CGPoint, scaleX: CGFloat) -> [CGPoint]? {
        let u = CGPoint(x: a.x - corner.x, y: a.y - corner.y)
        let v = CGPoint(x: b.x - corner.x, y: b.y - corner.y)
        guard hypot(u.x, u.y) > Knob.partialArm, hypot(v.x, v.y) > Knob.partialArm else { return nil }
        let degrees = angleDegrees(u, v)
        guard degrees > Knob.partialMinimumAngle, degrees < Knob.partialMaximumAngle else { return nil }
        guard let p1 = exitPoint(from: corner, direction: u, width: scaleX),
              let p2 = exitPoint(from: corner, direction: v, width: scaleX) else { return nil }
        let p3 = CGPoint(x: p1.x + p2.x - corner.x, y: p1.y + p2.y - corner.y)
        return orderAroundCenter([corner, p1, p3, p2])
    }

    /// Two fingers from different hands. Near-parallel fingers bound a band across the frame;
    /// crossing fingers make an L at the point where their lines meet.
    private static func fingerQuad(_ a: Finger, _ b: Finger, scaleX: CGFloat) -> [CGPoint]? {
        let da = CGPoint(x: a.tip.x - a.base.x, y: a.tip.y - a.base.y)
        let db = CGPoint(x: b.tip.x - b.base.x, y: b.tip.y - b.base.y)
        guard hypot(da.x, da.y) > Knob.partialFingerLength, hypot(db.x, db.y) > Knob.partialFingerLength else {
            return nil
        }
        var degrees = angleDegrees(da, db)
        if degrees > 90 { degrees = 180 - degrees }
        if degrees < Knob.parallelAngle {
            let mid = midpoint(b.tip, b.base)
            guard distanceToLine(mid, through: a.base, direction: da) > Knob.parallelGap,
                  let (a0, a1) = clipLine(through: a.base, direction: da, width: scaleX),
                  let (b0, b1) = clipLine(through: b.base, direction: db, width: scaleX) else { return nil }
            return orderAroundCenter([a0, a1, b0, b1])
        }
        guard let meet = intersection(a.base, da, b.base, db),
              meet.x > -0.3, meet.x < scaleX + 0.3, meet.y > -0.3, meet.y < 1.3 else { return nil }
        let towardA = distance(meet, a.tip) > distance(meet, a.base) ? a.tip : a.base
        let towardB = distance(meet, b.tip) > distance(meet, b.base) ? b.tip : b.base
        return openL(corner: meet, toward: towardA, and: towardB, scaleX: scaleX)
    }

    /// Where a ray from `point` leaves the frame (`width` × 1, aspect-scaled).
    private static func exitPoint(from point: CGPoint, direction: CGPoint, width: CGFloat) -> CGPoint? {
        var t = CGFloat.greatestFiniteMagnitude
        if direction.x > 0.0001 { t = min(t, (width - point.x) / direction.x) }
        if direction.x < -0.0001 { t = min(t, -point.x / direction.x) }
        if direction.y > 0.0001 { t = min(t, (1 - point.y) / direction.y) }
        if direction.y < -0.0001 { t = min(t, -point.y / direction.y) }
        guard t.isFinite, t > 0, t < 1000 else { return nil }
        return CGPoint(x: point.x + direction.x * t, y: point.y + direction.y * t)
    }

    /// The two points where a line crosses the frame border, or nil if it misses the frame.
    private static func clipLine(through point: CGPoint, direction: CGPoint, width: CGFloat) -> (CGPoint, CGPoint)? {
        var low = -CGFloat.greatestFiniteMagnitude
        var high = CGFloat.greatestFiniteMagnitude
        let axes: [(CGFloat, CGFloat, CGFloat)] = [(point.x, direction.x, width), (point.y, direction.y, 1)]
        for (origin, step, size) in axes {
            if abs(step) < 0.0001 {
                if origin < 0 || origin > size { return nil }
                continue
            }
            let t0 = -origin / step
            let t1 = (size - origin) / step
            low = max(low, min(t0, t1))
            high = min(high, max(t0, t1))
        }
        guard low < high, low.isFinite, high.isFinite else { return nil }
        return (
            CGPoint(x: point.x + direction.x * low, y: point.y + direction.y * low),
            CGPoint(x: point.x + direction.x * high, y: point.y + direction.y * high)
        )
    }

    private static func intersection(_ p: CGPoint, _ r: CGPoint, _ q: CGPoint, _ s: CGPoint) -> CGPoint? {
        let denominator = r.x * s.y - r.y * s.x
        guard abs(denominator) > 0.0001 else { return nil }
        let t = ((q.x - p.x) * s.y - (q.y - p.y) * s.x) / denominator
        return CGPoint(x: p.x + r.x * t, y: p.y + r.y * t)
    }

    private static func distanceToLine(_ point: CGPoint, through origin: CGPoint, direction: CGPoint) -> CGFloat {
        let length = hypot(direction.x, direction.y)
        guard length > 0.0001 else { return distance(point, origin) }
        return abs((point.x - origin.x) * direction.y - (point.y - origin.y) * direction.x) / length
    }

    /// Keeps corners on the picture, so a frame held right at the lens covers the screen instead of
    /// pointing off it. Falls back to the unclamped corners if clamping folds the shape.
    private static func clampedToFrame(_ points: [CGPoint]) -> [CGPoint] {
        let clamped = points.map { CGPoint(x: min(max($0.x, 0), 1), y: min(max($0.y, 0), 1)) }
        return isConvexCounterClockwise(clamped) ? clamped : points
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

    /// A thumb and index finger at an L angle. Either finger may be partial: a fingertip cut off by
    /// the frame falls back to the next joint, and a missing knuckle to a joint further up. When the
    /// knuckles are out of view, the corner of the L is where the two finger lines meet.
    private static func handL(from hand: HandPoints, scaleX: CGFloat) -> HandL? {
        guard let index = finger(index: true, hand, scaleX: scaleX),
              let thumb = finger(index: false, hand, scaleX: scaleX) else { return nil }
        let indexLength = distance(index.tip, index.base)
        let thumbLength = distance(thumb.tip, thumb.base)
        let opening = distance(index.tip, thumb.tip)
        guard indexLength > 0.01, thumbLength > 0.008, opening > 0.015 else { return nil }
        let indexDirection = CGPoint(x: index.tip.x - index.base.x, y: index.tip.y - index.base.y)
        let thumbDirection = CGPoint(x: thumb.tip.x - thumb.base.x, y: thumb.tip.y - thumb.base.y)
        let degrees = angleDegrees(indexDirection, thumbDirection)
        // About a right angle, with a wide allowance for perspective and a loose L.
        guard degrees > Knob.minimumAngle, degrees < Knob.maximumAngle else { return nil }

        var crotch = midpoint(index.base, thumb.base)
        if !(index.rooted && thumb.rooted),
           let meet = intersection(index.base, indexDirection, thumb.base, thumbDirection),
           distance(meet, index.base) < 0.5, distance(meet, thumb.base) < 0.5 {
            crotch = meet
        }
        return HandL(indexTip: index.tip, thumbTip: thumb.tip, crotch: crotch)
    }

    /// Index (`index` true) or thumb as a segment, from the best joints available.
    private static func finger(index: Bool, _ hand: HandPoints, scaleX: CGFloat) -> Finger? {
        let tip = Knob.tipConfidence
        let base = Knob.baseConfidence
        let tipNames: [VNHumanHandPoseObservation.JointName] = index ? [.indexTip, .indexDIP] : [.thumbTip, .thumbIP]
        let rootNames: [VNHumanHandPoseObservation.JointName] = index ? [.indexMCP] : [.thumbMP, .thumbCMC]
        let midNames: [VNHumanHandPoseObservation.JointName] = index ? [.indexPIP, .indexDIP] : [.thumbIP]

        var tipName: VNHumanHandPoseObservation.JointName?
        var tipPoint: CGPoint?
        for name in tipNames {
            if let point = hand.point(name, minimum: tip) {
                tipName = name
                tipPoint = point
                break
            }
        }
        guard let tipPoint, let tipName else { return nil }
        var basePoint: CGPoint?
        var rooted = false
        for name in rootNames {
            if let point = hand.point(name, minimum: base) {
                basePoint = point
                rooted = true
                break
            }
        }
        if basePoint == nil {
            for name in midNames where name != tipName {
                if let point = hand.point(name, minimum: base) {
                    basePoint = point
                    break
                }
            }
        }
        guard let basePoint, distance(basePoint, tipPoint) > 0.005 else { return nil }
        return Finger(
            tip: CGPoint(x: tipPoint.x * scaleX, y: tipPoint.y),
            base: CGPoint(x: basePoint.x * scaleX, y: basePoint.y),
            rooted: rooted
        )
    }

    /// Corners are the two L crotches (between thumb MCP and index MCP) and the two places
    /// where the fingertips meet.
    private static func directorQuad(_ a: HandL, _ b: HandL) -> [CGPoint]? {
        let span = distance(a.crotch, b.crotch)
        guard span > 0.03 else { return nil }
        let cross = distance(a.indexTip, b.thumbTip) + distance(a.thumbTip, b.indexTip)
        let same = distance(a.indexTip, b.indexTip) + distance(a.thumbTip, b.thumbTip)
        let closing = min(cross, same)
        let facing = opensToward(a, b.crotch) && opensToward(b, a.crotch)
        // Fingertips do not have to touch. Facing L's get more room than loosely placed ones.
        let allowance = facing ? span * 1.6 + 0.12 : span * 1.0 + 0.08
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
        let slack: CGFloat = 0.9
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

/// The thumb and index joints of one Vision hand, in normalized y-up frame coordinates.
struct HandPoints {
    static let names: [VNHumanHandPoseObservation.JointName] = [
        .thumbTip, .thumbIP, .thumbMP, .thumbCMC,
        .indexTip, .indexDIP, .indexPIP, .indexMCP
    ]

    private var joints: [VNHumanHandPoseObservation.JointName: (location: CGPoint, confidence: Float)] = [:]

    /// `map` moves Vision's points into frame coordinates, for passes run on a reworked image.
    init(_ observation: VNHumanHandPoseObservation, map: (CGPoint) -> CGPoint) {
        for name in HandPoints.names {
            guard let point = try? observation.recognizedPoint(name), point.confidence > 0 else { continue }
            joints[name] = (map(point.location), point.confidence)
        }
    }

    func point(_ name: VNHumanHandPoseObservation.JointName, minimum: Float) -> CGPoint? {
        guard let joint = joints[name], joint.confidence >= minimum else { return nil }
        return joint.location
    }
}

/// Fallback for hands Vision cannot see: skin-colored fingers bracketing an empty rectangle.
/// Works on a small RGBA grid whose first row is the top of the picture.
enum SkinFrame {
    enum Knob {
        /// Share of skin a strip just outside a side needs for that side to count as a finger.
        static let sideSkin: CGFloat = 0.45
        /// Sides that must be fingers. Three keeps a hand in one corner from counting.
        static let minimumSides = 3
        static let minimumArea: CGFloat = 0.06
        static let maximumArea: CGFloat = 0.85
        /// Share of the picture that may be skin. Outside this, it is a face, a wall, or no hand.
        static let minimumSkin: CGFloat = 0.03
        static let maximumSkin: CGFloat = 0.6
    }

    /// Four normalized y-up corners, counterclockwise from bottom-left, or nil.
    static func window(rgba: [UInt8], width: Int, height: Int) -> [CGPoint]? {
        guard width > 4, height > 4, rgba.count >= width * height * 4 else { return nil }
        var skin = [Bool](repeating: false, count: width * height)
        var skinCount = 0
        for index in 0..<(width * height) {
            let r = CGFloat(rgba[index * 4])
            let g = CGFloat(rgba[index * 4 + 1])
            let b = CGFloat(rgba[index * 4 + 2])
            let y = 0.299 * r + 0.587 * g + 0.114 * b
            let cb = 128 - 0.168736 * r - 0.331264 * g + 0.5 * b
            let cr = 128 + 0.5 * r - 0.418688 * g - 0.081312 * b
            if y > 45, cr > 135, cr < 180, cb > 80, cb < 132 {
                skin[index] = true
                skinCount += 1
            }
        }
        let fraction = CGFloat(skinCount) / CGFloat(width * height)
        guard fraction > Knob.minimumSkin, fraction < Knob.maximumSkin else { return nil }
        skin = closed(skin, width: width, height: height)
        guard touchesBorder(skin, width: width, height: height) else { return nil }

        var integral = [Int](repeating: 0, count: (width + 1) * (height + 1))
        for row in 0..<height {
            var sum = 0
            for column in 0..<width {
                sum += skin[row * width + column] ? 1 : 0
                integral[(row + 1) * (width + 1) + column + 1] = integral[row * (width + 1) + column + 1] + sum
            }
        }
        func skinIn(top: Int, left: Int, bottom: Int, right: Int) -> CGFloat {
            let t = max(0, top), l = max(0, left), b = min(height - 1, bottom), r = min(width - 1, right)
            guard t <= b, l <= r else { return 0 }
            let total = integral[(b + 1) * (width + 1) + r + 1] - integral[t * (width + 1) + r + 1]
                - integral[(b + 1) * (width + 1) + l] + integral[t * (width + 1) + l]
            return CGFloat(total) / CGFloat((b - t + 1) * (r - l + 1))
        }

        var best: (top: Int, left: Int, bottom: Int, right: Int)?
        var bestScore: CGFloat = 0
        func evaluate(top: Int, left: Int, bottom: Int, right: Int) {
            let area = CGFloat((bottom - top + 1) * (right - left + 1)) / CGFloat(width * height)
            guard area > Knob.minimumArea, area < Knob.maximumArea else { return }
            let thickV = max(2, height / 30)
            let thickH = max(2, width / 30)
            var sides = 0
            if top > 0, skinIn(top: top - thickV, left: left, bottom: top - 1, right: right) > Knob.sideSkin { sides += 1 }
            if bottom < height - 1, skinIn(top: bottom + 1, left: left, bottom: bottom + thickV, right: right) > Knob.sideSkin { sides += 1 }
            if left > 0, skinIn(top: top, left: left - thickH, bottom: bottom, right: left - 1) > Knob.sideSkin { sides += 1 }
            if right < width - 1, skinIn(top: top, left: right + 1, bottom: bottom, right: right + thickH) > Knob.sideSkin { sides += 1 }
            guard sides >= Knob.minimumSides else { return }
            let score = area * CGFloat(sides)
            if score > bestScore {
                bestScore = score
                best = (top, left, bottom, right)
            }
        }

        // Every maximal skin-free rectangle, found row by row with a histogram stack.
        var heights = [Int](repeating: 0, count: width)
        for row in 0..<height {
            for column in 0..<width {
                heights[column] = skin[row * width + column] ? 0 : heights[column] + 1
            }
            var stack: [Int] = []
            for column in 0...width {
                let current = column < width ? heights[column] : 0
                while let last = stack.last, heights[last] >= current {
                    stack.removeLast()
                    let barHeight = heights[last]
                    guard barHeight > 0 else { continue }
                    let left = (stack.last ?? -1) + 1
                    evaluate(top: row - barHeight + 1, left: left, bottom: row, right: column - 1)
                }
                stack.append(column)
            }
        }

        guard let best else { return nil }
        let minX = CGFloat(best.left) / CGFloat(width)
        let maxX = CGFloat(best.right + 1) / CGFloat(width)
        let maxY = 1 - CGFloat(best.top) / CGFloat(height)
        let minY = 1 - CGFloat(best.bottom + 1) / CGFloat(height)
        return [
            CGPoint(x: minX, y: minY),
            CGPoint(x: maxX, y: minY),
            CGPoint(x: maxX, y: maxY),
            CGPoint(x: minX, y: maxY)
        ]
    }

    /// Dilate then erode by one cell, so a finger with a dark crease stays one strip.
    private static func closed(_ mask: [Bool], width: Int, height: Int) -> [Bool] {
        func pass(_ input: [Bool], grow: Bool) -> [Bool] {
            var output = input
            for row in 0..<height {
                for column in 0..<width {
                    var value = !grow
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let y = min(max(row + dy, 0), height - 1)
                            let x = min(max(column + dx, 0), width - 1)
                            if grow { value = value || input[y * width + x] } else { value = value && input[y * width + x] }
                        }
                    }
                    output[row * width + column] = value
                }
            }
            return output
        }
        return pass(pass(mask, grow: true), grow: false)
    }

    /// Hands come in from the edges of the picture.
    private static func touchesBorder(_ mask: [Bool], width: Int, height: Int) -> Bool {
        for column in 0..<width where mask[column] || mask[(height - 1) * width + column] { return true }
        for row in 0..<height where mask[row * width] || mask[row * width + width - 1] { return true }
        return false
    }
}
