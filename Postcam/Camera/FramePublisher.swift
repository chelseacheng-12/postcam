import CoreImage
import CoreVideo

/// Renders a filter graph into a buffer we own, synchronously, before the camera
/// recycles the capture buffer. The preview can then upload that copy to Metal later.
final class FramePublisher {
    private let context: CIContext
    private let lock = NSLock()
    private var spare: [CVPixelBuffer] = []
    private let capacity = 3

    init(context: CIContext) {
        self.context = context
    }

    func render(_ image: CIImage) -> CVPixelBuffer? {
        let extent = image.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 2, height > 2 else { return nil }

        let buffer = take(width: width, height: height) ?? makeBuffer(width: width, height: height)
        guard let buffer else { return nil }
        context.render(
            image,
            to: buffer,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return buffer
    }

    func recycle(_ buffer: CVPixelBuffer) {
        lock.lock()
        if spare.count < capacity {
            spare.append(buffer)
        }
        lock.unlock()
    }

    private func take(width: Int, height: Int) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = spare.firstIndex(where: {
            CVPixelBufferGetWidth($0) == width && CVPixelBufferGetHeight($0) == height
        }) else { return nil }
        return spare.remove(at: index)
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
