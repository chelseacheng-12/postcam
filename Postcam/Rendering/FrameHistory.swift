import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// Feedback buffer for temporal smoothing. Each frame's result is rendered into a buffer we own,
/// so the next frame can read it after the camera has recycled its own buffer.
/// Use from one queue only. A result stays valid for the next two commits.
final class FrameHistory {
    private let context: CIContext
    private let slots = 3
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var buffers: [CVPixelBuffer] = []
    private var next = 0
    private var width = 0
    private var height = 0
    private var lastCommit = CFAbsoluteTime(0)
    private var stored: CIImage?

    init(context: CIContext) {
        self.context = context
    }

    func reset() {
        stored = nil
    }

    /// The last result, if it has the same size and is recent enough to still describe this scene.
    func previous(matching extent: CGRect, maxAge: CFTimeInterval = 0.35) -> CIImage? {
        guard let stored else { return nil }
        guard CFAbsoluteTimeGetCurrent() - lastCommit < maxAge else { return nil }
        guard Int(extent.width.rounded(.down)) == width,
              Int(extent.height.rounded(.down)) == height else { return nil }
        return stored
    }

    /// Mixes `current` toward the previous result. `keep` 0 has no memory; 0.7 is heavy smoothing.
    func blend(_ current: CIImage, keep: CGFloat) -> CIImage {
        let source = current.normalizedOrigin()
        let extent = source.extent
        var mixed = source
        if keep > 0, let prior = previous(matching: extent) {
            mixed = source.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: prior,
                kCIInputTimeKey: keep
            ]).cropped(to: extent)
        }
        return commit(mixed) ?? mixed
    }

    /// Renders `image` into the next owned buffer and returns an image backed by that buffer.
    @discardableResult
    func commit(_ image: CIImage) -> CIImage? {
        let source = image.normalizedOrigin()
        let newWidth = Int(source.extent.width.rounded(.down))
        let newHeight = Int(source.extent.height.rounded(.down))
        guard newWidth > 1, newHeight > 1, newWidth < 8192, newHeight < 8192 else { return nil }
        if newWidth != width || newHeight != height {
            buffers = []
            next = 0
            stored = nil
            width = newWidth
            height = newHeight
        }
        let index = next % slots
        if index >= buffers.count {
            guard let made = makeBuffer(width: newWidth, height: newHeight) else { return nil }
            buffers.append(made)
        }
        let buffer = buffers[index]
        next += 1
        context.render(
            source,
            to: buffer,
            bounds: CGRect(x: 0, y: 0, width: newWidth, height: newHeight),
            colorSpace: colorSpace
        )
        let result = CIImage(cvPixelBuffer: buffer)
        stored = result
        lastCommit = CFAbsoluteTimeGetCurrent()
        return result
    }

    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess else { return nil }
        return buffer
    }
}

/// Temporal state for one cel-shaded stream: the smoothed source, the flat fills, and the ink mask.
final class CelHistory {
    let color: FrameHistory
    let fills: FrameHistory
    let lines: FrameHistory

    init(context: CIContext) {
        color = FrameHistory(context: context)
        fills = FrameHistory(context: context)
        lines = FrameHistory(context: context)
    }

    func reset() {
        color.reset()
        fills.reset()
        lines.reset()
    }
}
