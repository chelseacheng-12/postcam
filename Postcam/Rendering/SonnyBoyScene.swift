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
        case sea
        case sand
        case grass
        /// The ground falls away into sky.
        case sky
    }

    var upper: Upper
    var ground: Ground
    /// Copies of the most salient object, lifted into the air.
    var floats: Int
    var textureSeed: UInt64

    static func make(seed: UInt64, groundIsWater: Bool) -> SurrealPlan {
        var rng = SplitMix64(seed: seed)
        let upper: Upper = rng.unit() < 0.8 ? .sky : .blank
        let roll = rng.unit()
        var ground: Ground
        if roll < 0.35 {
            ground = .sea
        } else if roll < 0.7 {
            ground = .sand
        } else if roll < 0.85 {
            ground = .sky
        } else {
            ground = .grass
        }
        if groundIsWater {
            ground = .grass
        }
        let floatRoll = rng.unit()
        let floats = floatRoll < 0.25 ? 0 : (floatRoll < 0.7 ? 1 : 2)
        return SurrealPlan(upper: upper, ground: ground, floats: floats, textureSeed: rng.next())
    }
}

/// Sonny Boy, surreal version. People are found with person segmentation and stay as flat cel
/// figures with dark outlines. Flat surfaces above the horizon (ceilings, walls, real sky) become
/// cobalt sky or blank space. Flat ground below becomes sea, sand, grass, or more sky.
/// The most salient object can float above itself with a slow bob.
///
/// Everything runs at `workScale`. Live mode reuses masks between Vision passes and smooths them
/// over time. Still mode runs every pass once at full strength.
final class SonnyBoyScene {
    enum Knob {
        static let workScale: CGFloat = 0.42
        /// Share of last frame's sky/ground/person masks kept.
        static let regionKeep: CGFloat = 0.7
        /// How texture-free a surface must be to turn into sky. Higher demands flatter walls.
        static let skyFlatGain: Double = 3.2
        static let groundFlatGain: Double = 2.4
        static let skyThreshold: Double = 0.42
        static let groundThreshold: Double = 0.38
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
    private let cel: CelHistory?
    private let regions: FrameHistory?
    private let start = CFAbsoluteTimeGetCurrent()

    private var person: CIImage?
    private var floatBox: CGRect?
    private var frameIndex = 0
    private var plan = SurrealPlan(upper: .sky, ground: .sand, floats: 1, textureSeed: 1)
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
        regions = still ? nil : FrameHistory(context: context)
    }

    /// `horizon` is a 0...1 height, y-up. Surfaces above it may turn into sky; below it, ground.
    /// `framing` changes whenever a new hand frame starts, which picks a new plan.
    func render(_ image: CIImage, horizon: CGFloat, framing: Int) -> CIImage {
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
        if still || frameIndex % 30 == 1 || (floatBox == nil && frameIndex % 6 == 1) {
            findSalient(small)
        }

        let base = SonnyBoyStyle.cel(small, history: cel)
        let horizonY = extent.minY + extent.height * min(max(horizon, 0.05), 0.95)
        let packed = regionMasks(small, horizonY: horizonY)
        let stable = regions?.blend(packed, keep: Knob.regionKeep) ?? packed
        let skyMask = alphaChannel(stable, index: 0)
        let groundMask = alphaChannel(stable, index: 1)

        var scene = base
        let time = CFAbsoluteTimeGetCurrent() - start
        if person != nil {
            let upper = upperLayer(extent, horizonY: horizonY, time: time)
            scene = upper.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: scene,
                kCIInputMaskImageKey: skyMask
            ]).cropped(to: extent)
            let ground = groundLayer(extent, horizonY: horizonY, time: time, upper: upper)
            scene = ground.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: scene,
                kCIInputMaskImageKey: groundMask
            ]).cropped(to: extent)
            scene = outlined(scene, packed: stable)
        }

        if plan.floats > 0, let box = floatBox {
            scene = floating(base, over: scene, box: box, extent: extent, time: time)
        }
        return IllustrationStyle.upscaled(scene, to: fullExtent)
    }

    // MARK: - Plan

    private func adoptPlan(framing: Int, sample: CIImage) {
        planFraming = framing
        let mixed = sessionSeed ^ (UInt64(truncatingIfNeeded: framing) &* 0x9E3779B97F4A7C15)
        plan = SurrealPlan.make(seed: mixed, groundIsWater: lowerBandLooksLikeWater(sample))
        textures = SonnyBoyTextures(seed: plan.textureSeed)
        cel?.reset()
        regions?.reset()
        floatBox = nil
        person = nil
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
        guard let buffer = personRequest.results?.first?.pixelBuffer else { return }
        let raw = CIImage(cvPixelBuffer: buffer)
        let rawExtent = raw.extent
        guard rawExtent.width > 1, rawExtent.height > 1 else { return }
        let extent = small.extent
        let scaled = raw
            .transformed(by: CGAffineTransform(
                scaleX: extent.width / rawExtent.width,
                y: extent.height / rawExtent.height
            ))
            .normalizedOrigin()
            .cropped(to: extent)
        person = gray(fromRed: scaled)
    }

    private func findSalient(_ small: CIImage) {
        let handler = VNImageRequestHandler(ciImage: small, orientation: .up, options: [:])
        do {
            try handler.perform([saliencyRequest])
        } catch {
            return
        }
        guard let objects = saliencyRequest.results?.first?.salientObjects else { return }
        let extent = small.extent
        var best: CGRect?
        var bestScore: CGFloat = 0
        for object in objects {
            let box = object.boundingBox
            let area = box.width * box.height
            guard area > 0.01, area < 0.28 else { continue }
            if let person, personCoverage(person, box: box, extent: extent) > 0.35 { continue }
            let score = CGFloat(object.confidence) * (1 - abs(area - 0.08) * 2)
            if score > bestScore {
                bestScore = score
                best = box
            }
        }
        guard let best else { return }
        if let current = floatBox, !still {
            floatBox = CGRect(
                x: current.minX * 0.7 + best.minX * 0.3,
                y: current.minY * 0.7 + best.minY * 0.3,
                width: current.width * 0.7 + best.width * 0.3,
                height: current.height * 0.7 + best.height * 0.3
            )
        } else {
            floatBox = best
        }
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

    /// Packs three gray masks into one opaque image: red = sky, green = ground, blue = person.
    /// One buffer, so one temporal blend keeps all three steady.
    private func regionMasks(_ small: CIImage, horizonY: CGFloat) -> CIImage {
        let extent = small.extent
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        let personMask = person ?? black

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

        let skyRaw = StableInk.multiply(StableInk.multiply(StableInk.multiply(above, flatUp), bright), notPerson)
        let groundRaw = StableInk.multiply(StableInk.multiply(below, flatDown), notPerson)
        let sky = shaped(skyRaw, threshold: Knob.skyThreshold)
        let ground = shaped(groundRaw, threshold: Knob.groundThreshold)

        let red = channel(sky, index: 0)
        let green = channel(ground, index: 1)
        let blue = channel(personMask, index: 2)
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

    /// One channel of the packed masks as an alpha mask.
    private func alphaChannel(_ packed: CIImage, index: Int) -> CIImage {
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
            "inputAVector": pick,
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ]).cropped(to: extent)
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

    private func upperLayer(_ extent: CGRect, horizonY: CGFloat, time: CFTimeInterval) -> CIImage {
        switch plan.upper {
        case .blank:
            return CIImage(color: SonnyBoyStyle.Knob.blank).cropped(to: extent)
        case .sky:
            let sky = SonnyBoyStyle.gradient(
                extent,
                bottom: SonnyBoyStyle.Knob.skyLow,
                top: SonnyBoyStyle.Knob.skyTop
            )
            guard let textures else { return sky }
            let shift = CGFloat(time) * extent.width * Knob.drift
            let clouds = SonnyBoyStyle.tiled(
                textures.clouds,
                over: extent,
                tileWidth: extent.width * 1.25,
                shift: shift,
                y: horizonY - extent.height * 0.05
            )
            return clouds.composited(over: sky).cropped(to: extent)
        }
    }

    private func groundLayer(_ extent: CGRect, horizonY: CGFloat, time: CFTimeInterval, upper: CIImage) -> CIImage {
        let shift = CGFloat(time) * extent.width * Knob.drift * 0.6
        switch plan.ground {
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

    /// Thin dark lines where sky, ground, and people meet, so the swap reads as one drawing.
    private func outlined(_ scene: CIImage, packed: CIImage) -> CIImage {
        let extent = scene.extent
        let skyRing = StableInk.outline(grayChannel(packed, index: 0), radius: 1)
        let groundRing = StableInk.outline(grayChannel(packed, index: 1), radius: 1)
        let personRing = StableInk.outline(grayChannel(packed, index: 2), radius: 1.2)
        let rings = skyRing
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: groundRing])
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: personRing])
            .cropped(to: extent)
        let cut = rings.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.35]).cropped(to: extent)
        let ink = StableInk.ink(cut, color: SonnyBoyStyle.Knob.ink, soften: 0.5)
        return ink.applyingFilter("CIMultiplyBlendMode", parameters: [
            kCIInputBackgroundImageKey: scene
        ]).cropped(to: extent)
    }

    /// Copies the salient object and lifts it into the air, bobbing slowly.
    private func floating(_ base: CIImage, over scene: CIImage, box: CGRect, extent: CGRect, time: CFTimeInterval) -> CIImage {
        let rect = CGRect(
            x: extent.minX + box.minX * extent.width,
            y: extent.minY + box.minY * extent.height,
            width: box.width * extent.width,
            height: box.height * extent.height
        ).intersection(extent)
        guard !rect.isNull, rect.width > 8, rect.height > 8 else { return scene }

        let parameters: [String: Any] = [
            "inputExtent": CIVector(cgRect: rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.08)),
            "inputRadius": min(rect.width, rect.height) * 0.2,
            "inputColor": CIColor(red: 1, green: 1, blue: 1)
        ]
        guard let shape = CIFilter(name: "CIRoundedRectangleGenerator", parameters: parameters)?.outputImage else {
            return scene
        }
        let feather = shape.cropped(to: extent)
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 3])
            .cropped(to: extent)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        let patch = base.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: feather
        ]).cropped(to: rect)

        var result = scene
        for copy in 0..<plan.floats {
            let phase = Double(copy) * 2.1
            let bob = CGFloat(sin(time * Knob.bobSpeed + phase)) * extent.height * Knob.floatBob
            let lift = extent.height * (Knob.floatLift + CGFloat(copy) * 0.12) + bob
            let scale: CGFloat = copy == 0 ? 1 : 0.62
            let side: CGFloat = copy == 0 ? 0 : (rect.midX < extent.midX ? 1 : -1)
            let dx = side * rect.width * 0.9
            let transform = CGAffineTransform(translationX: -rect.midX, y: -rect.midY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: rect.midX + dx, y: rect.midY + lift))
            result = patch.transformed(by: transform).composited(over: result).cropped(to: extent)
        }
        return result
    }
}
