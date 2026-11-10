import CoreImage
import Metal
import SwiftUI
import UIKit

protocol PreviewSurface: AnyObject {
    var aspect: CGFloat { get }
    func present(_ buffer: CVPixelBuffer, recycle: @escaping (CVPixelBuffer) -> Void)
    func showFocus(at point: CGPoint)
}

/// Full-screen Metal view of the stamped frame.
/// Pinch, tap-to-focus, and double-tap-to-reset live here so they land on the picture.
/// SwiftUI controls sit above this view and take their own hits.
final class CameraPreviewView: UIView, PreviewSurface {
    weak var camera: CameraController?

    private var commandQueue: MTLCommandQueue?
    private var ciContext: CIContext?
    private let reticle = CAShapeLayer()
    private var hideReticle: DispatchWorkItem?
    private var pendingFocus: DispatchWorkItem?
    private var burstCommit: DispatchWorkItem?
    private var stampTapsInBurst = 0
    private let aspectLock = NSLock()
    private var cachedAspect: CGFloat = 9.0 / 19.5
    private var didConfigureMetal = false

    override class var layerClass: AnyClass { CAMetalLayer.self }

    private var metalLayer: CAMetalLayer {
        layer as! CAMetalLayer
    }

    var aspect: CGFloat {
        aspectLock.lock()
        defer { aspectLock.unlock() }
        return cachedAspect
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isOpaque = true
        backgroundColor = .black
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = true
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.contentsGravity = .resizeAspectFill
        reticle.fillColor = UIColor.clear.cgColor
        reticle.lineWidth = 1.5
        reticle.strokeColor = UIColor(red: 1, green: 0.839, blue: 0.039, alpha: 1).cgColor
        reticle.isHidden = true
        layer.addSublayer(reticle)
        installGestures()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func bind(_ camera: CameraController) {
        self.camera = camera
        camera.attach(preview: self)
        guard commandQueue == nil, let device = camera.metalDevice else { return }
        metalLayer.device = device
        commandQueue = device.makeCommandQueue()
        ciContext = camera.ciContext
        didConfigureMetal = true
    }

    func present(_ buffer: CVPixelBuffer, recycle: @escaping (CVPixelBuffer) -> Void) {
        let size = metalLayer.drawableSize
        guard didConfigureMetal,
              size.width > 1,
              size.height > 1,
              let context = ciContext,
              let commandQueue,
              let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            recycle(buffer)
            return
        }

        let destination = CGRect(origin: .zero, size: size)
        let image = CIImage(cvPixelBuffer: buffer).filling(destination)
        context.render(
            image,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: destination,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        commandBuffer.addCompletedHandler { _ in
            recycle(buffer)
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func showFocus(at point: CGPoint) {
        let side: CGFloat = 76
        let rect = CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
        reticle.frame = bounds
        reticle.path = UIBezierPath(roundedRect: rect, cornerRadius: 1.5).cgPath
        reticle.isHidden = false
        reticle.opacity = 1
        hideReticle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.fadeReticle()
            return
        }
        hideReticle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.windowScene?.screen.scale ?? 3
        let pixels = CGSize(
            width: max(bounds.width * scale, 1),
            height: max(bounds.height * scale, 1)
        )
        if metalLayer.drawableSize != pixels {
            metalLayer.drawableSize = pixels
        }
        guard bounds.width > 1, bounds.height > 1 else { return }
        let next = bounds.width / bounds.height
        aspectLock.lock()
        cachedAspect = next
        aspectLock.unlock()
        camera?.setPreviewAspect(next)
        reticle.frame = bounds
    }

    private func installGestures() {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        // Stamp taps fire immediately. Waiting on the double-tap recognizer made the resize feel late.
        // A double-tap still resets zoom and undoes any stamp steps from that pair of taps.
        addGestureRecognizer(pinch)
        addGestureRecognizer(tap)
        addGestureRecognizer(doubleTap)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            camera?.beginPinch()
        case .changed:
            camera?.updatePinch(scale: gesture.scale)
        case .ended, .cancelled, .failed:
            camera?.endPinch()
        default:
            break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        if stampContains(point) {
            pendingFocus?.cancel()
            camera?.cycleStampSize()
            stampTapsInBurst += 1
            scheduleBurstCommit()
            return
        }
        scheduleFocus(at: point)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        pendingFocus?.cancel()
        burstCommit?.cancel()
        if stampTapsInBurst > 0 {
            camera?.revertStampBurst()
            stampTapsInBurst = 0
        }
        camera?.resetZoom()
        return
    }

    private func scheduleFocus(at point: CGPoint) {
        pendingFocus?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.camera?.focus(at: point, in: self.bounds.size)
            return
        }
        pendingFocus = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26, execute: work)
    }

    private func scheduleBurstCommit() {
        burstCommit?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stampTapsInBurst = 0
            self.camera?.commitStampBurst()
            return
        }
        burstCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func stampContains(_ point: CGPoint) -> Bool {
        guard camera?.artStyle == .postcard else { return false }
        guard bounds.width > 1, bounds.height > 1 else { return false }
        let fraction = camera?.stampWidthFraction() ?? StampScale.large.widthFraction
        let layout = StampGeometry.layout(
            in: CGRect(origin: .zero, size: bounds.size),
            widthFraction: fraction
        )
        let imagePoint = CGPoint(x: point.x, y: bounds.height - point.y)
        return layout.path.contains(imagePoint)
    }

    private func fadeReticle() {
        CATransaction.begin()
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0
        animation.duration = 0.22
        reticle.add(animation, forKey: "fade")
        reticle.opacity = 0
        CATransaction.commit()
    }
}

struct CameraPreviewRepresentable: UIViewRepresentable {
    let camera: CameraController

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.bind(camera)
        return view
    }

    func updateUIView(_ view: CameraPreviewView, context: Context) {
        view.bind(camera)
    }
}
