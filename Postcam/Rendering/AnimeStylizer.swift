import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation

/// Redraws a crop of the camera frame as a Makoto Shinkai style anime background with the bundled
/// Core ML model (`Postcam/ML/SonnyBoyAnime.mlpackage`, CartoonGAN; see `tools/anime-model`).
///
/// Live frames call `submit`. One inference runs at a time on a private queue; a frame that
/// arrives while one is running is dropped, and `latest` keeps returning the last finished result,
/// so a slow phone shows a steady picture at a lower update rate instead of stuttering.
/// Stills call `stylizeNow`, which waits for the model.
///
/// The model works at about 150k pixels. Its output is grown back to the crop's full resolution
/// with an edge-preserving upsample guided by the camera crop, so painted regions keep the
/// photo's sharp borders without its texture. Successive results at about the same place are
/// blended (`keep`) so the drawing does not flicker.
final class AnimeStylizer {
    enum Knob {
        static let modelName = "SonnyBoyAnime"
        /// Share of the previous result kept when the window has not moved much.
        static let keep: CGFloat = 0.35
        /// A window that moved or resized more than this share of the frame starts fresh.
        static let sameWindow: CGFloat = 0.06
        /// Edge-preserving upsample of the model output against the camera crop.
        static let upsampleSpatial: Double = 2
        static let upsampleLuma: Double = 0.1
    }

    /// Input sizes the model was converted with, width × height. Keep in sync with
    /// `SHAPES` in `tools/anime-model/convert_cartoongan.py`.
    static let shapes: [(width: Int, height: Int)] = [
        (384, 384), (320, 448), (448, 320), (256, 576), (576, 256)
    ]

    struct Result {
        /// The drawing, placed at `rect` in frame coordinates.
        let image: CIImage
        let rect: CGRect
        let frameExtent: CGRect
    }

    enum State {
        case loading
        case ready
        case failed
    }

    static let shared = AnimeStylizer()

    private let queue = DispatchQueue(label: "postcam.anime-model", qos: .userInitiated)
    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let history: FrameHistory
    private var model: MLModel?
    private var inputs: [String: CVPixelBuffer] = [:]
    private var lastRect: CGRect?
    private var currentState = State.loading
    private var busy = false
    private var latestResult: Result?

    private init() {
        history = FrameHistory(context: context)
        queue.async { [weak self] in
            self?.load()
        }
    }

    var state: State {
        lock.lock()
        defer { lock.unlock() }
        return currentState
    }

    /// Starts a live inference on `rect` of `frame` unless one is already running.
    func submit(_ frame: CIImage, rect: CGRect) {
        lock.lock()
        guard currentState == .ready, !busy else {
            lock.unlock()
            return
        }
        busy = true
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.run(frame, rect: rect, smooth: true)
            self.lock.lock()
            if let result {
                self.latestResult = result
            }
            self.busy = false
            self.lock.unlock()
        }
    }

    /// The last live result for a frame of this size, if any.
    func latest(for frameExtent: CGRect) -> Result? {
        lock.lock()
        defer { lock.unlock() }
        guard let latestResult, latestResult.frameExtent == frameExtent else { return nil }
        return latestResult
    }

    /// Runs the model on `rect` of `frame` and waits for it, including for the model to load.
    func stylizeNow(_ frame: CIImage, rect: CGRect) -> Result? {
        queue.sync {
            run(frame, rect: rect, smooth: false)
        }
    }

    /// Forgets the live result, for a new hand framing or a camera switch.
    func reset() {
        lock.lock()
        latestResult = nil
        lock.unlock()
        queue.async { [weak self] in
            self?.lastRect = nil
            self?.history.reset()
        }
    }

    // MARK: - Queue only

    private func load() {
        guard let url = Bundle.main.url(forResource: Knob.modelName, withExtension: "mlmodelc") else {
            setState(.failed)
            return
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        do {
            model = try MLModel(contentsOf: url, configuration: configuration)
            setState(.ready)
        } catch {
            setState(.failed)
        }
    }

    private func setState(_ state: State) {
        lock.lock()
        currentState = state
        lock.unlock()
    }

    private func run(_ frame: CIImage, rect requested: CGRect, smooth: Bool) -> Result? {
        guard let model else { return nil }
        let frameExtent = frame.extent
        let rect = requested.integral.intersection(frameExtent)
        guard !rect.isNull, rect.width >= 16, rect.height >= 16 else { return nil }
        let shape = Self.shape(for: rect.width / rect.height)
        guard let input = inputBuffer(width: shape.width, height: shape.height) else { return nil }

        let crop = frame.cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let scaled = crop
            .transformed(by: CGAffineTransform(
                scaleX: CGFloat(shape.width) / rect.width,
                y: CGFloat(shape.height) / rect.height
            ))
            .cropped(to: CGRect(x: 0, y: 0, width: shape.width, height: shape.height))
        context.render(
            scaled,
            to: input,
            bounds: CGRect(x: 0, y: 0, width: shape.width, height: shape.height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let output: MLFeatureProvider
        do {
            let provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)])
            output = try model.prediction(from: provider)
        } catch {
            return nil
        }
        guard let buffer = output.featureValue(for: "stylized")?.imageBufferValue else { return nil }
        var drawing = CIImage(cvPixelBuffer: buffer)

        if smooth {
            let moved = lastRect.map { previous in
                let shift = max(
                    abs(previous.minX - rect.minX), abs(previous.maxX - rect.maxX),
                    abs(previous.minY - rect.minY), abs(previous.maxY - rect.maxY)
                )
                return shift > Knob.sameWindow * max(frameExtent.width, frameExtent.height)
            } ?? true
            if moved {
                history.reset()
            }
            drawing = history.blend(drawing, keep: moved ? 0 : Knob.keep)
            lastRect = rect
        }

        let grown = upsample(drawing, guide: crop)
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
            .cropped(to: rect)
        return Result(image: grown, rect: rect, frameExtent: frameExtent)
    }

    private func upsample(_ small: CIImage, guide: CIImage) -> CIImage {
        let extent = guide.extent
        let parameters: [String: Any] = [
            kCIInputImageKey: guide,
            "inputSmallImage": small.normalizedOrigin(),
            "inputSpatialSigma": Knob.upsampleSpatial,
            "inputLumaSigma": Knob.upsampleLuma
        ]
        if let output = CIFilter(name: "CIEdgePreserveUpsampleFilter", parameters: parameters)?.outputImage {
            return output.cropped(to: extent)
        }
        return IllustrationStyle.upscaled(small, to: extent)
    }

    private func inputBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let key = "\(width)x\(height)"
        if let buffer = inputs[key] {
            return buffer
        }
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
        guard status == kCVReturnSuccess, let buffer else { return nil }
        inputs[key] = buffer
        return buffer
    }

    /// The converted input size closest to `aspect` (width / height).
    static func shape(for aspect: CGFloat) -> (width: Int, height: Int) {
        let target = log(max(aspect, 0.01))
        var best = shapes[0]
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for shape in shapes {
            let distance = abs(log(CGFloat(shape.width) / CGFloat(shape.height)) - target)
            if distance < bestDistance {
                bestDistance = distance
                best = shape
            }
        }
        return best
    }
}
