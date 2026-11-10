import CoreGraphics
import ImageIO

/// How a raw camera buffer is turned upright for the portrait screen: some clockwise quarter
/// turns, then an optional left-right flip for the mirrored selfie view.
struct FrameOrientation: Equatable {
    /// Clockwise quarter turns applied to the raw buffer, 0...3.
    let quarterTurns: Int
    /// Left-right flip after the turn.
    let mirrored: Bool

    /// `angle` is the clockwise rotation, in degrees, that Apple's rotation coordinator reports for a
    /// level picture on the portrait screen. Most iPhone sensors deliver landscape buffers that need a
    /// quarter turn, but some front cameras deliver portrait buffers that need none, so the angle is
    /// checked against the buffer's shape. On a portrait screen a landscape buffer needs an odd number
    /// of quarter turns and a portrait buffer an even number. A missing or contradicting angle falls
    /// back to the shape alone: one turn for landscape, none for portrait.
    init(angle: CGFloat?, bufferIsLandscape: Bool, mirrored: Bool) {
        var turns = bufferIsLandscape ? 1 : 0
        if let angle, angle.isFinite {
            let reported = ((Int((angle / 90).rounded()) % 4) + 4) % 4
            if (reported % 2 == 1) == bufferIsLandscape {
                turns = reported
            }
        }
        self.init(turns: turns, mirrored: mirrored)
    }

    private init(turns: Int, mirrored: Bool) {
        quarterTurns = turns
        self.mirrored = mirrored
    }

    /// The same turn without the flip: the true view, for saving front-camera shots.
    var unmirrored: FrameOrientation {
        FrameOrientation(turns: quarterTurns, mirrored: false)
    }

    var imageOrientation: CGImagePropertyOrientation {
        switch (quarterTurns, mirrored) {
        case (1, false): return .right
        case (2, false): return .down
        case (3, false): return .left
        case (0, true): return .upMirrored
        case (1, true): return .leftMirrored
        case (2, true): return .downMirrored
        case (3, true): return .rightMirrored
        default: return .up
        }
    }

    /// Maps a screen point, normalized with the origin at the top left, back to the raw buffer in the
    /// same convention. Focus and exposure points of interest use the raw buffer's frame.
    func rawPoint(fromScreen point: CGPoint) -> CGPoint {
        let x = mirrored ? 1 - point.x : point.x
        let y = point.y
        switch quarterTurns {
        case 1: return CGPoint(x: y, y: 1 - x)
        case 2: return CGPoint(x: 1 - x, y: 1 - y)
        case 3: return CGPoint(x: 1 - y, y: x)
        default: return CGPoint(x: x, y: y)
        }
    }

    var label: String {
        "\(quarterTurns * 90)° clockwise\(mirrored ? ", mirrored" : "")"
    }
}
