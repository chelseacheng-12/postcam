import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

/// What a framing turns into. Chosen once per framing from a seed, so it never flickers.
struct SurrealPlan {
    enum Upper {
        /// Cobalt sky with flat clouds.
        case sky
        /// Blank flat 2D space.
        case blank
    }

    enum Ground {
        /// The real floor stays, painted like everything else.
        case keep
        case sea
        case sand
        case grass
        /// The ground falls away into sky.
        case sky
    }

    var upper: Upper
    var ground: Ground
    /// How many salient objects get a floating copy.
    var floats: Int
    /// A whale swims through the sky.
    var whale: Bool
    /// Where along its path the whale starts, 0..<1.
    var whalePhase: Double
    var textureSeed: UInt64

    static func make(seed: UInt64, groundIsWater: Bool) -> SurrealPlan {
        var rng = SplitMix64(seed: seed)
        let upper: Upper = rng.unit() < 0.9 ? .sky : .blank
        let roll = rng.unit()
        var ground: Ground
        if roll < 0.55 {
            ground = .keep
        } else if roll < 0.7 {
            ground = .sea
        } else if roll < 0.82 {
            ground = .sand
        } else if roll < 0.92 {
            ground = .sky
        } else {
            ground = .grass
        }
        if groundIsWater, ground == .sea {
            ground = .keep
        }
        let floatRoll = rng.unit()
        let floats = floatRoll < 0.15 ? 0 : (floatRoll < 0.55 ? 1 : 2)
        let whale = upper == .sky && rng.unit() < 0.85
        let whalePhase = Double(rng.unit())
        return SurrealPlan(
            upper: upper,
            ground: ground,
            floats: floats,
            whale: whale,
            whalePhase: whalePhase,
            textureSeed: rng.next()
        )
    }
}

/// Sonny Boy, surreal version. The hand window is redrawn as an anime background by the Core ML
/// model in `AnimeStylizer`; only that crop goes through the model. On top of the drawing, empty
/// background above the horizon (ceilings, walls, windows, real sky) becomes a cobalt sky with
/// painted cumulus, sometimes with a whale swimming through it, and never covers an object. Flat
/// ground below usually stays, or becomes sea, sand, grass, or more sky. Up to two detected objects
/// float above themselves with a soft shadow underneath.
///
/// While the model loads, or if it cannot load, the drawing falls back to the Core Image cel
/// filter (`SonnyBoyStyle.paint`). Vision and the region masks run at `workScale`. Live mode reuses
/// masks between Vision passes and smooths them over time. Still mode runs every pass once.
final class SonnyBoyScene {
    enum Knob {
        static let workScale: CGFloat = 0.42
        /// Share of last frame's sky/ground/person masks kept.
        static let regionKeep: CGFloat = 0.7
        /// How texture-free a surface must be to turn into sky. Higher demands flatter walls.
        static let skyFlatGain: Double = 3.2
        static let groundFlatGain: Double = 2.4
        static let skyThreshold: Double = 0.38
        static let groundThreshold: Double = 0.38
        /// Bright regions (windows, lit ceilings) turn into sky between these linear luminances,
        /// even when they have texture such as trees behind glass.
        static let glowLow: Double = 0.42
        static let glowHigh: Double = 0.66
        /// Object mask. Edge energy above `busyLow` counts as a textured object unless it glows.
        static let busyLow: Double = 0.34
        static let busyGain: Double = 5
        /// Saliency heat above this counts as an object unless it glows.
        static let heatThreshold: Double = 0.55
        /// Gap kept between sky or swapped ground and any object: working-size pixels before the
        /// masks are grown, then full-resolution pixels after. Sky never cuts into a silhouette.
        static let objectMargin: Double = 3
        static let objectMarginFull: Double = 2
        /// Share of a salient box that must be a detected object before it may float.
        static let floatCoverage: CGFloat = 0.12
        /// Float lift as a share of frame height, and the bob around it.
        static let floatLift: CGFloat = 0.17
        static let floatBob: CGFloat = 0.012
        static let bobSpeed: Double = 0.9
        /// Points per second the clouds and waves drift, as a share of width.
        static let drift: CGFloat = 0.008
    }

    private let context: CIContext
    private let still: Bool
    private let sessionSeed: UInt64
    private let personRequest: VNGeneratePersonSegmentationRequest
    private let saliencyRequest = VNGenerateObjectnessBasedSaliencyImageRequest()
    private let foregroundRequest = VNGenerateForegroundInstanceMaskRequest()
    private let cel: CelHistory?
    private let palette: FrameHistory?
    private let regions: FrameHistory?
    private let lineHistory: FrameHistory?
    private let start = CFAbsoluteTimeGetCurrent()
    private let anime = AnimeStylizer.shared

    private var person: CIImage?
    /// Foreground object instances (Vision, iOS 17), gray, at working size.
    private var objects: CIImage?
    /// Objectness saliency heat map, gray, at working size.
    private var salientHeat: CIImage?
    private var floatBoxes: [CGRect] = []
    private var frameIndex = 0
    private var plan = SurrealPlan(upper: .sky, ground: .keep, floats: 1, whale: true, whalePhase: 0, textureSeed: 1)
    private var planFraming = Int.min
    private var textures: SonnyBoyTextures?

    init(context: CIContext, still: Bool, seed: UInt64) {
        self.context = context
        self.still = still
        self.sessionSeed = seed
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = still ? .accurate : .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        personRequest = request
        cel = still ? nil : CelHistory(context: context)
        palette = still ? nil : FrameHistory(context: context)
        regions = still ? nil : FrameHistory(context: context)
        lineHistory = still ? nil : FrameHistory(context: context)
    }

    /// `horizon` is a 0...1 height, y-up. Surfaces above it may turn into sky; below it, ground.
    /// `framing` changes whenever a new hand frame starts, which picks a new plan.
    /// `window` is the hand window in 0...1 coordinates, y-up. Only it is redrawn by the model, and
    /// clouds and the whale are sized to it. `waitForModel` runs the model on this exact frame
    /// (for a photo) instead of showing the last live result.
    func render(
        _ image: CIImage,
        horizon: CGFloat,
        framing: Int,
        window: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        waitForModel: Bool = false
    ) -> CIImage {
        let full = image.normalizedOrigin()
        let fullExtent = full.extent
        guard fullExtent.width > 16, fullExtent.height > 16 else { return full }

        let small = IllustrationStyle.downscaled(full, scale: Knob.workScale)
        let extent = small.extent
        if framing != planFraming {
            adoptPlan(framing: framing, sample: small)
        }
        frameIndex += 1
        if still || person == nil || frameIndex % 3 == 0 {
            segmentPeople(small)
        }
        if still || frameIndex % 8 == 4 || (objects == nil && frameIndex % 4 == 2) {
            segmentObjects(small)
        }
        if still || frameIndex % 10 == 1 || (floatBoxes.isEmpty && frameIndex % 6 == 1) {
            findSalient(small)
        }

        let windowRect = pixelRect(window, in: fullExtent)
        let base: CIImage
        let guide: CIImage
        /// Traced outlines, only for the fallback filter; the model draws its own.
        var lines: CIImage?
        if let drawing = modelDrawing(full, window: windowRect, wait: still || waitForModel) {
            base = drawing.image.composited(over: full).cropped(to: fullExtent)
            guide = base
        } else {
            let layers = SonnyBoyStyle.paint(full: full, small: small, history: cel, palette: palette)
            base = layers.fills
            guide = layers.regions
            lines = SonnyBoyStyle.lineMask(layers.regions, history: lineHistory)
        }
        let level = min(max(horizon, 0.05), 0.95)
        let packed = regionMasks(small, horizonY: extent.minY + extent.height * level)
        let stable = regions?.blend(packed, keep: Knob.regionKeep) ?? packed

        var scene = base
        var ink = lines
        let time = CFAbsoluteTimeGetCurrent() - start
        if person != nil {
            // Grown with the drawing as the guide, then cut hard, so mask borders land on the
            // drawing's own sharp borders instead of a stretched low-res blob.
            let masks = SonnyBoyStyle.guidedUpsample(stable, guide: guide)
            let objectGuard = dilated(cut(grayChannel(masks, index: 2)), radius: Knob.objectMarginFull)
            let free = StableInk.affine(objectGuard, scale: -1, bias: 1)
            let sky = StableInk.multiply(cut(grayChannel(masks, index: 0)), free)
            let ground = plan.ground == .keep
                ? CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: fullExtent)
                : StableInk.multiply(cut(grayChannel(masks, index: 1)), free)
            let horizonY = fullExtent.minY + fullExtent.height * level
            let upper = upperLayer(fullExtent, window: windowRect, horizonY: horizonY, time: time)
            scene = upper.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: scene,
                kCIInputMaskImageKey: sky
            ]).cropped(to: fullExtent)
            if plan.ground != .keep {
                let groundFill = groundLayer(fullExtent, horizonY: horizonY, time: time, upper: upper)
                scene = groundFill.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: scene,
                    kCIInputMaskImageKey: ground
                ]).cropped(to: fullExtent)
            }
            // Contours inside a swapped area belong to the old wall or floor, so they are dropped.
            let edges = boundaries(sky: sky, ground: ground)
            if let traced = lines {
                let kept = StableInk.affine(brighter(sky, ground), scale: -1, bias: 1)
                ink = brighter(StableInk.multiply(traced, kept), edges)
            } else {
                ink = edges
            }
        }
        if let ink {
            scene = SonnyBoyStyle.inked(scene, lines: ink)
        }

        if plan.floats > 0, !floatBoxes.isEmpty, let objects {
            let silhouettes = cut(SonnyBoyStyle.guidedUpsample(objects, guide: guide))
            let object = lines.map { SonnyBoyStyle.inked(base, lines: $0) } ?? base
            scene = floating(object, over: scene, boxes: floatBoxes, silhouettes: silhouettes, extent: fullExtent, time: time)
        }
        return scene
    }

    /// The model's drawing of the window, slightly padded so the window edge is inside it.
    /// Live, this is the last finished result, which may be a frame or two old.
    private func modelDrawing(_ full: CIImage, window: CGRect, wait: Bool) -> AnimeStylizer.Result? {
        let extent = full.extent
        let pad = max(window.width, window.height) * 0.04
        let rect = window.insetBy(dx: -pad, dy: -pad).intersection(extent).integral
        guard !rect.isNull, rect.width >= 16, rect.height >= 16 else { return nil }
        if wait {
            return anime.stylizeNow(full, rect: rect)
        }
        guard anime.state == .ready else { return nil }
        anime.submit(full, rect: rect)
        return anime.latest(for: extent)
    }

    // MARK: - Plan

    private func adoptPlan(framing: Int, sample: CIImage) {
        planFraming = framing
        let mixed = sessionSeed ^ (UInt64(truncatingIfNeeded: framing) &* 0x9E3779B97F4A7C15)
        plan = SurrealPlan.make(seed: mixed, groundIsWater: lowerBandLooksLikeWater(sample))
        textures = SonnyBoyTextures(seed: plan.textureSeed)
        if !still {
            anime.reset()
        }
        cel?.reset()
        palette?.reset()
        regions?.reset()
        lineHistory?.reset()
        floatBoxes = []
        person = nil
        objects = nil
        salientHeat = nil
    }

    private func lowerBandLooksLikeWater(_ image: CIImage) -> Bool {
        let extent = image.extent
        let band = CGRect(x: extent.minX, y: extent.minY, width: extent.width, height: extent.height * 0.3)
        guard let color = average(image, in: band) else { return false }
        return color.blue > color.red + 0.08 && color.blue > color.green - 0.02
    }

    // MARK: - Vision

    private func segmentPeople(_ small: CIImage) {
        let handler = VNImageRequestHandler(ciImage: small, orientation: .up, options: [:])
        do {
            try handler.perform([personRequest])
        } catch {
            return
        }
        guard let buffer = personRequest.results?.first?.pixelBuffer,
              let mask = scaledMask(buffer, extent: small.extent) else { return }
        person = mask
    }

    /// Every foreground object Vision finds, as one gray mask. An empty scene gives black.
    private func segmentObjects(_ small: CIImage) {
        let handler = VNImageRequestHandler(ciImage: small, orientation: .up, options: [:])
        do {
            try handler.perform([foregroundRequest])
        } catch {
            return
        }
        guard let observation = foregroundRequest.results?.first else {
            objects = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: small.extent)
            return
        }
        guard let buffer = try? observation.generateScaledMaskForImage(
            forInstances: observation.allInstances,
            from: handler
        ) else { return }
        objects = scaledMask(buffer, extent: small.extent)
    }

    /// A one-channel Vision mask stretched over `extent` as an opaque gray image.
    private func scaledMask(_ buffer: CVPixelBuffer, extent: CGRect) -> CIImage? {
        let raw = CIImage(cvPixelBuffer: buffer)
        let rawExtent = raw.extent
        guard rawExtent.width > 1, rawExtent.height > 1 else { return nil }
        let scaled = raw
            .transformed(by: CGAffineTransform(
                scaleX: extent.width / rawExtent.width,
                y: extent.height / rawExtent.height
            ))
            .normalizedOrigin()
            .cropped(to: extent)
        return gray(fromRed: scaled)
    }

    private func findSalient(_ small: CIImage) {
        let handler = VNImageRequestHandler(ciImage: small, orientation: .up, options: [:])
        do {
            try handler.perform([saliencyRequest])
        } catch {
            return
        }
        guard let observation = saliencyRequest.results?.first else { return }
        let extent = small.extent
        if let heat = scaledMask(observation.pixelBuffer, extent: extent) {
            salientHeat = heat
        }
        guard let found = observation.salientObjects else { return }
        var candidates: [(box: CGRect, score: CGFloat)] = []
        for object in found {
            let box = object.boundingBox
            let area = box.width * box.height
            guard area > 0.01, area < 0.28 else { continue }
            if let person, personCoverage(person, box: box, extent: extent) > 0.35 { continue }
            // Only things Vision segmented as objects float, never a patch of wall.
            guard let objects, personCoverage(objects, box: box, extent: extent) > Knob.floatCoverage else { continue }
            let score = CGFloat(object.confidence) * (1 - abs(area - 0.08) * 2)
            if score > 0 {
                candidates.append((box, score))
            }
        }
        candidates.sort { $0.score > $1.score }
        var picked: [CGRect] = []
        for candidate in candidates where picked.count < 2 {
            if picked.allSatisfy({ overlap($0, candidate.box) < 0.2 }) {
                picked.append(candidate.box)
            }
        }
        guard !picked.isEmpty else { return }
        if still || floatBoxes.isEmpty {
            floatBoxes = picked
            return
        }
        floatBoxes = picked.map { next in
            guard let current = floatBoxes.min(by: { distance($0, next) < distance($1, next) }),
                  distance(current, next) < 0.2 else {
                return next
            }
            return CGRect(
                x: current.minX * 0.7 + next.minX * 0.3,
                y: current.minY * 0.7 + next.minY * 0.3,
                width: current.width * 0.7 + next.width * 0.3,
                height: current.height * 0.7 + next.height * 0.3
            )
        }
    }

    /// Intersection over the smaller box.
    private func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let shared = a.intersection(b)
        guard !shared.isNull else { return 0 }
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 ? shared.width * shared.height / smaller : 0
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }

    private func pixelRect(_ unit: CGRect, in extent: CGRect) -> CGRect {
        let rect = CGRect(
            x: extent.minX + unit.minX * extent.width,
            y: extent.minY + unit.minY * extent.height,
            width: unit.width * extent.width,
            height: unit.height * extent.height
        ).intersection(extent)
        return rect.isNull || rect.width < 8 || rect.height < 8 ? extent : rect
    }

    private func personCoverage(_ person: CIImage, box: CGRect, extent: CGRect) -> CGFloat {
        let rect = CGRect(
            x: extent.minX + box.minX * extent.width,
            y: extent.minY + box.minY * extent.height,
            width: box.width * extent.width,
            height: box.height * extent.height
        )
        return average(person, in: rect)?.red ?? 0
    }

    private func average(_ image: CIImage, in rect: CGRect) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        let area = rect.intersection(image.extent)
        guard !area.isNull, area.width >= 1, area.height >= 1 else { return nil }
        let averaged = image.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: area)
        ])
        let outExtent = averaged.extent
        let bounds = outExtent.isInfinite || outExtent.isNull
            ? CGRect(x: area.minX, y: area.minY, width: 1, height: 1)
            : CGRect(x: outExtent.minX, y: outExtent.minY, width: 1, height: 1)
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(averaged, toBitmap: &pixel, rowBytes: 4, bounds: bounds, format: .RGBA8, colorSpace: nil)
        return (CGFloat(pixel[0]) / 255, CGFloat(pixel[1]) / 255, CGFloat(pixel[2]) / 255)
    }

    // MARK: - Regions

    /// Packs three gray masks into one opaque image: red = sky, green = ground, blue = objects
    /// (people included). Sky and ground already stay clear of objects by `objectMargin`.
    /// One buffer, so one temporal blend keeps all three steady.
    private func regionMasks(_ small: CIImage, horizonY: CGFloat) -> CIImage {
        let extent = small.extent
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        let personMask = person ?? black
        let instances = objects ?? black
        let heat = salientHeat ?? black

        let luminance = small.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
            kCIInputBrightnessKey: 0,
            kCIInputContrastKey: 1
        ]).cropped(to: extent)
        let energy = luminance.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2])
            .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 5])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 7])
            .cropped(to: extent)

        let notPerson = StableInk.affine(personMask, scale: -1, bias: 1)
        let flatUp = StableInk.affine(energy, scale: -Knob.skyFlatGain, bias: 1)
        let flatDown = StableInk.affine(energy, scale: -Knob.groundFlatGain, bias: 1)
        let bright = StableInk.affine(luminance, scale: 0.75, bias: 0.4)
        let glowScale = 1 / max(Knob.glowHigh - Knob.glowLow, 0.01)
        let glow = StableInk.affine(
            luminance.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 4])
                .cropped(to: extent),
            scale: glowScale,
            bias: -Knob.glowLow * glowScale
        )
        let above = SonnyBoyStyle.ramp(
            extent,
            from: horizonY - extent.height * 0.03,
            to: horizonY + extent.height * 0.10,
            rising: true
        )
        let below = SonnyBoyStyle.ramp(
            extent,
            from: horizonY - extent.height * 0.12,
            to: horizonY - extent.height * 0.02,
            rising: false
        )

        let skyLike = brighter(StableInk.multiply(flatUp, bright), glow)

        // Anything that is an object: people, Vision's foreground instances, salient spots, and
        // busy texture. Bright glowing areas (windows) are not objects unless Vision segmented them.
        let notGlow = StableInk.affine(glow, scale: -1, bias: 1)
        let busy = StableInk.affine(energy, scale: Knob.busyGain, bias: -Knob.busyLow * Knob.busyGain)
        let hot = StableInk.affine(heat, scale: 4, bias: -Knob.heatThreshold * 4)
        let objectsAll = brighter(
            brighter(personMask, instances),
            StableInk.multiply(brighter(busy, hot), notGlow)
        )
        let objectGuard = objectsAll.clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: Knob.objectMargin])
            .cropped(to: extent)
        let free = StableInk.multiply(StableInk.affine(objectGuard, scale: -1, bias: 1), notPerson)

        let skyRaw = StableInk.multiply(StableInk.multiply(above, skyLike), free)
        let groundRaw = StableInk.multiply(StableInk.multiply(below, flatDown), free)
        let sky = shaped(skyRaw, threshold: Knob.skyThreshold)
        let ground = shaped(groundRaw, threshold: Knob.groundThreshold)
        let foreground = shaped(objectsAll, threshold: 0.5)

        let red = channel(sky, index: 0)
        let green = channel(ground, index: 1)
        let blue = channel(foreground, index: 2)
        // Maximum, not addition: each channel is zero in the other two images and alpha stays 1.
        return red
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: green])
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: blue])
            .cropped(to: extent)
    }

    /// Blobs into graphic shapes: merge, cut at `threshold`, then a soft edge.
    private func shaped(_ raw: CIImage, threshold: Double) -> CIImage {
        let extent = raw.extent
        return raw.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 3])
            .cropped(to: extent)
            .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": threshold])
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.2])
            .cropped(to: extent)
    }

    /// Gray mask moved into one color channel of an opaque image.
    private func channel(_ mask: CIImage, index: Int) -> CIImage {
        let extent = mask.extent
        let pick = CIVector(x: 1, y: 0, z: 0, w: 0)
        let none = CIVector(x: 0, y: 0, z: 0, w: 0)
        return mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": index == 0 ? pick : none,
            "inputGVector": index == 1 ? pick : none,
            "inputBVector": index == 2 ? pick : none,
            "inputAVector": none,
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ]).cropped(to: extent)
    }

    /// Hard 0-or-1 version of a gray mask.
    private func cut(_ mask: CIImage) -> CIImage {
        let extent = mask.extent
        let binary = mask.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.5])
            .cropped(to: extent)
        return StableInk.opaque(binary)
    }

    /// Per-pixel maximum of two opaque gray masks.
    private func brighter(_ a: CIImage, _ b: CIImage) -> CIImage {
        a.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: b])
            .cropped(to: a.extent)
    }

    /// One channel of the packed masks as an opaque gray image.
    private func grayChannel(_ packed: CIImage, index: Int) -> CIImage {
        let extent = packed.extent
        let pick = CIVector(
            x: index == 0 ? 1 : 0,
            y: index == 1 ? 1 : 0,
            z: index == 2 ? 1 : 0,
            w: 0
        )
        return packed.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": pick,
            "inputGVector": pick,
            "inputBVector": pick,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ]).cropped(to: extent)
    }

    /// Vision's one-channel mask may read as red only; copy red into all three channels.
    private func gray(fromRed image: CIImage) -> CIImage {
        let extent = image.extent
        let red = CIVector(x: 1, y: 0, z: 0, w: 0)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": red,
            "inputGVector": red,
            "inputBVector": red,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ]).cropped(to: extent)
    }

    // MARK: - Layers

    private func upperLayer(_ extent: CGRect, window: CGRect, horizonY: CGFloat, time: CFTimeInterval) -> CIImage {
        switch plan.upper {
        case .blank:
            return CIImage(color: SonnyBoyStyle.Knob.blank).cropped(to: extent)
        case .sky:
            let top = max(window.maxY, horizonY + 1)
            var sky = SonnyBoyStyle.gradient(
                CGRect(x: extent.minX, y: horizonY, width: extent.width, height: top - horizonY),
                bottom: SonnyBoyStyle.Knob.skyLow,
                top: SonnyBoyStyle.Knob.skyTop
            ).clampedToExtent().cropped(to: extent)
            if let textures {
                let shift = CGFloat(time) * window.width * Knob.drift
                let clouds = SonnyBoyArt.cloudBand(
                    textures.clouds,
                    over: extent,
                    window: window,
                    bottom: horizonY - window.height * 0.06,
                    shift: shift
                )
                sky = clouds.composited(over: sky).cropped(to: extent)
            }
            if plan.whale {
                let whale = SonnyBoyArt.swimmingWhale(
                    in: window,
                    horizonY: horizonY,
                    time: time,
                    phase: plan.whalePhase,
                    extent: extent
                )
                sky = whale.composited(over: sky).cropped(to: extent)
            }
            return sky
        }
    }

    private func groundLayer(_ extent: CGRect, horizonY: CGFloat, time: CFTimeInterval, upper: CIImage) -> CIImage {
        let shift = CGFloat(time) * extent.width * Knob.drift * 0.6
        switch plan.ground {
        case .keep:
            return SonnyBoyArt.clear(extent)
        case .sky:
            return upper
        case .sand:
            return CIImage(color: SonnyBoyStyle.Knob.sand).cropped(to: extent)
        case .sea:
            let water = SonnyBoyStyle.gradient(
                extent,
                bottom: SonnyBoyStyle.Knob.seaNear,
                top: SonnyBoyStyle.Knob.seaFar
            )
            guard let textures else { return water }
            let waves = SonnyBoyStyle.tiled(textures.waves, over: extent, tileWidth: extent.width * 0.9, shift: shift, y: 0)
            return waves.composited(over: water).cropped(to: extent)
        case .grass:
            let field = CIImage(color: SonnyBoyStyle.Knob.grass).cropped(to: extent)
            guard let textures else { return field }
            let tufts = SonnyBoyStyle.tiled(textures.tufts, over: extent, tileWidth: extent.width * 0.8, shift: 0, y: 0)
            return tufts.composited(over: field).cropped(to: extent)
        }
    }

    /// Thin lines where sky and ground meet everything else, so the swap reads as one drawing.
    /// Traced on the sharp full-resolution masks, so the line is as thin as the image lines.
    /// The sky's edge runs around every object in front of it, which outlines those objects too.
    private func boundaries(sky: CIImage, ground: CIImage) -> CIImage {
        let extent = sky.extent
        let radius = SonnyBoyStyle.Knob.boundaryRadius
        let rings = brighter(StableInk.outline(sky, radius: radius), StableInk.outline(ground, radius: radius))
        return StableInk.opaque(
            rings.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.5]).cropped(to: extent)
        )
    }

    /// Grows a hard gray mask by `radius` pixels.
    private func dilated(_ mask: CIImage, radius: Double) -> CIImage {
        let extent = mask.extent
        return mask.clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
    }

    /// Copies salient objects and lifts them into the air, bobbing slowly, each with a soft shadow
    /// on the spot it rose from. With one object and two floats, a smaller second copy rides beside it.
    /// Each copy is cut along the object's own silhouette, so its edge is as sharp as the drawing.
    private func floating(
        _ base: CIImage,
        over scene: CIImage,
        boxes: [CGRect],
        silhouettes: CIImage,
        extent: CGRect,
        time: CFTimeInterval
    ) -> CIImage {
        var copies: [(rect: CGRect, scale: CGFloat, dx: CGFloat, lift: CGFloat)] = []
        for index in 0..<plan.floats {
            let box = boxes.count > index ? boxes[index] : boxes[0]
            let rect = CGRect(
                x: extent.minX + box.minX * extent.width,
                y: extent.minY + box.minY * extent.height,
                width: box.width * extent.width,
                height: box.height * extent.height
            ).intersection(extent)
            guard !rect.isNull, rect.width > 8, rect.height > 8 else { continue }
            let phase = Double(index) * 2.1
            let bob = CGFloat(sin(time * Knob.bobSpeed + phase)) * extent.height * Knob.floatBob
            let lift = extent.height * (Knob.floatLift + CGFloat(index) * 0.06) + bob
            let repeated = boxes.count <= index
            let scale: CGFloat = repeated ? 0.62 : 1
            let side: CGFloat = repeated ? (rect.midX < extent.midX ? 1 : -1) : 0
            copies.append((rect, scale, side * rect.width * 0.9, lift))
        }

        var result = scene
        for copy in copies {
            let rest = extent.height * Knob.floatLift
            let strength = max(0.35, min(1, 1.25 - copy.lift / max(rest, 1) * 0.5))
            let shadow = SonnyBoyArt.contactShadow(
                center: CGPoint(x: copy.rect.midX + copy.dx, y: copy.rect.minY + copy.rect.height * 0.04),
                width: copy.rect.width * copy.scale * 0.95,
                strength: strength,
                extent: extent
            )
            result = shadow.composited(over: result).cropped(to: extent)
        }
        for copy in copies {
            let patch = cutout(base, silhouettes: silhouettes, rect: copy.rect, extent: extent)
            let rect = copy.rect
            let transform = CGAffineTransform(translationX: -rect.midX, y: -rect.midY)
                .concatenating(CGAffineTransform(scaleX: copy.scale, y: copy.scale))
                .concatenating(CGAffineTransform(translationX: rect.midX + copy.dx, y: rect.midY + copy.lift))
            result = patch.transformed(by: transform).composited(over: result).cropped(to: extent)
        }
        return result
    }

    /// The object pixels inside `rect`, transparent everywhere else. Hard-edged.
    private func cutout(_ base: CIImage, silhouettes: CIImage, rect: CGRect, extent: CGRect) -> CIImage {
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        let mask = silhouettes.cropped(to: rect).composited(over: black).cropped(to: extent)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        return base.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: mask
        ]).cropped(to: rect)
    }
}
