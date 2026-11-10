import AVFoundation
import Combine
import CoreImage
import CoreMedia
import Metal
import os
import UIKit

enum CaptureMode: String, CaseIterable, Identifiable {
    case video
    case photo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: return "VIDEO"
        case .photo: return "PHOTO"
        }
    }
}

private enum ModeKey {
    static let captureMode = "postcam.capture.mode"
    static let artStyle = "postcam.art.style"
}

enum CameraError: LocalizedError {
    case noDevice
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return "This device doesn't have a camera Postcam can use. Run it on an iPhone."
        case .cannotAddInput:
            return "The camera couldn't be opened."
        case .cannotAddOutput:
            return "The camera couldn't start a preview."
        }
    }
}

/// Live camera. Frames are stamped on the video queue, copied into a buffer we own,
/// then shown and (while recording) encoded. Device configuration stays on `sessionQueue`.
final class CameraController: NSObject, ObservableObject {
    /// Portrait interface. Both cameras are rotated 90° clockwise into that orientation.
    /// If a device previews sideways, this is the number to change.
    static let portraitRotation: CGFloat = 90
    /// The front camera previews mirrored, like a mirror. Saved photos and videos are flipped back
    /// to the true view, which is the iPhone Camera default. Set true to save them as previewed.
    static let saveFrontCameraMirrored = false

    @Published var authorization: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published var unavailableReason: String?
    @Published var mode: CaptureMode
    @Published var artStyle: ArtStyle
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var lenses: [LensChoice] = [LensChoice(displayFactor: 1, deviceZoom: 1)]
    @Published var zoomDisplay: CGFloat = 1
    @Published var isAdjustingZoom = false
    @Published var flashEnabled = false
    @Published var backTorchAvailable = false
    @Published var position: AVCaptureDevice.Position = .back
    @Published var shutterBlink = false
    @Published var screenFlash = false

    var onPhoto: ((UIImage) -> Void)?
    var onVideo: ((URL, UIImage, TimeInterval) -> Void)?
    var onStatus: ((String) -> Void)?

    let compositor: StampCompositor
    private let settings: StampSettings
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.chelseacheng.postcam.session")
    private let videoQueue = DispatchQueue(label: "com.chelseacheng.postcam.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.chelseacheng.postcam.audio", qos: .userInitiated)
    private let frames: FramePublisher
    private let recorder: MovieRecorder
    private let logger = Logger(subsystem: "com.chelseacheng.postcam", category: "camera")

    private let stateLock = NSLock()
    private var shared = Shared()
    private var zoomMap = ZoomMap.identity
    private var videoDevice: AVCaptureDevice?
    private var zoomObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private var isConfigured = false
    private var videoAdded = false
    private var audioAdded = false
    private var micAuthorized = false
    private var askedForVideo = false
    private var pinchStart: CGFloat = 1
    private var readoutToken = 0
    private var recordTimer: Timer?
    private var recordingStarted = Date()
    private var lastPhotoTime: CFAbsoluteTime = 0
    private var burstOrigin: StampScale?

    // Video queue only.
    private var capturePhotoOnNextFrame = false
    private var turnTorchOffAfterPhoto = false
    private var recordingThumbnail: UIImage?

    private var lastFramePosition: AVCaptureDevice.Position?
    private let handTracker: HandFrameTracker
    private let postcardHistory: CelHistory
    private weak var previewSurface: PreviewSurface?
    private let previewLock = NSLock()

    var metalDevice: MTLDevice? { compositor.metalDevice }
    var ciContext: CIContext { compositor.context }

    var flashAvailable: Bool {
        if position == .front { return mode == .photo }
        return backTorchAvailable
    }

    init(compositor: StampCompositor, settings: StampSettings) {
        let storedMode = UserDefaults.standard.string(forKey: ModeKey.captureMode) ?? ""
        let storedStyle = UserDefaults.standard.string(forKey: ModeKey.artStyle) ?? ""
        mode = CaptureMode(rawValue: storedMode) ?? .photo
        artStyle = ArtStyle(rawValue: storedStyle) ?? .postcard
        self.compositor = compositor
        self.settings = settings
        frames = FramePublisher(context: compositor.context)
        recorder = MovieRecorder(context: compositor.context)
        handTracker = HandFrameTracker(context: compositor.context)
        postcardHistory = CelHistory(context: compositor.context)
        super.init()
        stateLock.lock()
        shared.artStyle = artStyle
        stateLock.unlock()
        installObservers()
    }

    deinit {
        zoomObservation?.invalidate()
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Lifecycle

    func start() {
        sessionQueue.async { self.setWantsRunning(true) }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            publish { self.authorization = .authorized }
            prepareMicrophoneAndRun()
        case .notDetermined:
            guard !askedForVideo else { return }
            askedForVideo = true
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.askedForVideo = false
                    self.authorization = granted ? .authorized : .denied
                    if granted { self.prepareMicrophoneAndRun() }
                }
            }
        case .denied, .restricted:
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            publish { self.authorization = status }
        @unknown default:
            publish { self.authorization = .denied }
        }
    }

    func stop() {
        if isRecording {
            stopRecording()
        }
        sessionQueue.async {
            self.setWantsRunning(false)
            self.setTorch(false)
            guard !self.wantsRunning() else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func attach(preview: PreviewSurface) {
        previewLock.lock()
        previewSurface = preview
        previewLock.unlock()
    }

    func setPreviewAspect(_ aspect: CGFloat) {
        guard aspect > 0.2, aspect < 3 else { return }
        stateLock.lock()
        shared.previewAspect = aspect
        stateLock.unlock()
    }

    // MARK: - Controls

    func setMode(_ mode: CaptureMode) {
        guard !isRecording, self.mode != mode else { return }
        self.mode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: ModeKey.captureMode)
        if mode == .video, position == .front, flashEnabled {
            flashEnabled = false
        }
    }

    func setArtStyle(_ style: ArtStyle) {
        guard artStyle != style else { return }
        artStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: ModeKey.artStyle)
        stateLock.lock()
        shared.artStyle = style
        stateLock.unlock()
    }

    func toggleFlash() {
        guard flashAvailable else { return }
        flashEnabled.toggle()
        let enabled = flashEnabled
        let videoMode = mode == .video
        sessionQueue.async {
            let back = self.currentPosition() == .back
            if videoMode && back {
                self.setTorch(enabled)
            } else if !enabled {
                self.setTorch(false)
            }
        }
    }

    func switchCamera() {
        guard !isRecording else { return }
        sessionQueue.async {
            let next: AVCaptureDevice.Position = self.currentPosition() == .back ? .front : .back
            do {
                try self.configure(position: next)
            } catch {
                self.report(error.localizedDescription)
            }
        }
    }

    func takePhoto() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPhotoTime > 0.35 else { return }
        guard !isRecording else { return }
        guard hasFrame() else {
            report("The camera isn't ready yet.")
            return
        }
        lastPhotoTime = now
        settings.refreshDate()
        shutterBlink = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.shutterBlink = false
            return
        }

        let useScreen = flashEnabled && position == .front
        if useScreen {
            screenFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
                self?.screenFlash = false
                return
            }
        }

        sessionQueue.async {
            let useTorch = self.flashEnabled && self.currentPosition() == .back && (self.videoDevice?.hasTorch ?? false)
            if useTorch {
                self.setTorch(true)
            }
            let delay = useTorch ? 0.22 : (useScreen ? 0.12 : 0)
            self.videoQueue.asyncAfter(deadline: .now() + delay) {
                self.capturePhotoOnNextFrame = true
                self.turnTorchOffAfterPhoto = useTorch
            }
        }
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func selectLens(_ lens: LensChoice) {
        beginReadout()
        sessionQueue.async { self.applyZoom(lens.deviceZoom, animated: true) }
    }

    func beginPinch() {
        readoutToken += 1
        isAdjustingZoom = true
        sessionQueue.async {
            self.pinchStart = self.videoDevice?.videoZoomFactor ?? 1
        }
    }

    func updatePinch(scale: CGFloat) {
        let scale = max(scale, 0.01)
        sessionQueue.async {
            self.applyZoom(self.pinchStart * scale, animated: false)
        }
    }

    func endPinch() {
        beginReadout()
    }

    func resetZoom() {
        beginReadout()
        sessionQueue.async {
            self.applyZoom(self.zoomMap.deviceZoom(forDisplay: 1), animated: true)
        }
    }

    func isLensActive(_ lens: LensChoice) -> Bool {
        abs(lens.displayFactor - zoomDisplay) < max(0.07, lens.displayFactor * 0.08)
    }

    func closestLens() -> LensChoice? {
        lenses.min { abs($0.displayFactor - zoomDisplay) < abs($1.displayFactor - zoomDisplay) }
    }

    func focus(at point: CGPoint, in viewSize: CGSize) {
        guard viewSize.width > 1, viewSize.height > 1 else { return }
        currentPreview()?.showFocus(at: point)
        sessionQueue.async { self.applyFocus(at: point, in: viewSize) }
    }

    func stampWidthFraction() -> CGFloat {
        settings.currentWidthFraction()
    }

    func cycleStampSize() {
        if burstOrigin == nil {
            burstOrigin = settings.scale
        }
        settings.cycleScale()
        Haptic.light()
    }

    func revertStampBurst() {
        guard let origin = burstOrigin else { return }
        burstOrigin = nil
        settings.setScale(origin)
    }

    func commitStampBurst() {
        burstOrigin = nil
    }

    // MARK: - Session

    private func prepareMicrophoneAndRun() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                self?.sessionQueue.async {
                    self?.micAuthorized = granted
                    self?.configureIfNeededAndStart()
                    return
                }
                return
            }
        case .authorized:
            sessionQueue.async {
                self.micAuthorized = true
                self.configureIfNeededAndStart()
            }
        default:
            sessionQueue.async {
                self.micAuthorized = false
                self.configureIfNeededAndStart()
            }
        }
    }

    private func configureIfNeededAndStart() {
        guard wantsRunning() else { return }
        if !isConfigured {
            do {
                try configure(position: .back)
                isConfigured = true
                compositor.warmUp()
            } catch {
                let message = error.localizedDescription
                logger.error("configure failed: \(message, privacy: .public)")
                DispatchQueue.main.async { self.unavailableReason = message }
                return
            }
        } else if micAuthorized && !audioAdded {
            session.beginConfiguration()
            addAudioOutputIfNeeded()
            session.commitConfiguration()
        }
        AudioRoute.capture()
        guard wantsRunning() else { return }
        if !session.isRunning {
            session.startRunning()
        }
    }

    private func configure(position: AVCaptureDevice.Position) throws {
        try configureSession(position: position)
        // Swapping the input replaces the video connection when the configuration commits, and the
        // new connection starts with no rotation and no mirroring. Settings applied inside the
        // configuration block can land on the connection that is about to go away, so apply them
        // again once the commit is done.
        applyConnectionSettings(for: position)
    }

    private func configureSession(position: AVCaptureDevice.Position) throws {
        guard let device = makeDevice(position: position) else { throw CameraError.noDevice }
        let input = try AVCaptureDeviceInput(device: device)

        setTorch(false)
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for existing in session.inputs {
            session.removeInput(existing)
        }
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)

        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        } else if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
        }

        if !videoAdded {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            guard session.canAddOutput(videoOutput) else { throw CameraError.cannotAddOutput }
            session.addOutput(videoOutput)
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            videoAdded = true
        }

        addAudioOutputIfNeeded()
        applyConnectionSettings(for: position)
        let displayZoom = configureDevice(device)

        videoDevice = device
        stateLock.lock()
        shared.position = position
        stateLock.unlock()

        let lenses = zoomMap.lenses
        let torch = device.hasTorch
        let name = device.localizedName
        let type = String(describing: device.deviceType)
        logger.info("Using \(name, privacy: .public) (\(type, privacy: .public))")
        DispatchQueue.main.async {
            self.position = position
            self.backTorchAvailable = torch
            self.lenses = lenses
            self.zoomDisplay = displayZoom
            self.flashEnabled = false
            self.unavailableReason = nil
        }
    }

    private func addAudioOutputIfNeeded() {
        guard micAuthorized, !audioAdded, session.canAddOutput(audioOutput) else { return }
        session.addOutput(audioOutput)
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        audioAdded = true
    }

    /// Same for both cameras: portrait rotation on the connection, and the front camera mirrored
    /// like a mirror. Each frame then reads the state of the connection it came from, so a frame
    /// that slips through before these settings land is still drawn upright.
    private func applyConnectionSettings(for position: AVCaptureDevice.Position) {
        guard let connection = videoOutput.connection(with: .video) else {
            let name = String(describing: position)
            logger.info("No video connection yet for \(name, privacy: .public)")
            return
        }
        if connection.isVideoRotationAngleSupported(Self.portraitRotation) {
            connection.videoRotationAngle = Self.portraitRotation
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = position == .front
        }
        let angle = Double(connection.videoRotationAngle)
        let mirrored = connection.isVideoMirrored
        logger.info("Connection angle \(angle) mirrored \(mirrored)")
    }

    @discardableResult
    private func configureDevice(_ device: AVCaptureDevice) -> CGFloat {
        let map = ZoomMap.make(for: device)
        zoomMap = map
        stateLock.lock()
        shared.wideZoom = map.wideAngleDeviceZoom
        stateLock.unlock()

        let oneX = min(max(map.deviceZoom(forDisplay: 1), device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = true
            }
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = true
            }
            device.videoZoomFactor = oneX
            device.unlockForConfiguration()
        } catch {
            logger.error("device setup: \(error.localizedDescription, privacy: .public)")
        }

        zoomObservation?.invalidate()
        zoomObservation = device.observe(\.videoZoomFactor, options: [.new]) { [weak self] device, _ in
            self?.publishDisplayZoom(device.videoZoomFactor)
            return
        }
        return map.display(for: oneX)
    }

    private func makeDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        let discovered = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position).devices
        for type in types {
            if let match = discovered.first(where: { $0.deviceType == type }) {
                return match
            }
        }
        return discovered.first
    }

    private func applyZoom(_ factor: CGFloat, animated: Bool) {
        guard let device = videoDevice else { return }
        let lower = device.minAvailableVideoZoomFactor
        let upper = min(device.maxAvailableVideoZoomFactor, zoomMap.maxDeviceZoom)
        let clamped = min(max(factor, lower), max(upper, lower))
        do {
            try device.lockForConfiguration()
            if animated, abs(device.videoZoomFactor - clamped) > 0.02 {
                device.ramp(toVideoZoomFactor: clamped, withRate: 4.5)
            } else {
                if device.isRampingVideoZoom {
                    device.cancelVideoZoomRamp()
                }
                device.videoZoomFactor = clamped
            }
            device.unlockForConfiguration()
            publishDisplayZoom(clamped)
        } catch {
            logger.error("zoom: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyFocus(at point: CGPoint, in viewSize: CGSize) {
        guard let device = videoDevice else { return }
        let nx = point.x / viewSize.width
        let ny = point.y / viewSize.height
        let raw: CGPoint = currentPosition() == .front
            ? CGPoint(x: ny, y: nx)
            : CGPoint(x: ny, y: 1 - nx)
        let interest = CGPoint(x: min(max(raw.x, 0), 1), y: min(max(raw.y, 0), 1))
        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusPointOfInterest = interest
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposurePointOfInterest = interest
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        } catch {
            logger.error("focus: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func setTorch(_ on: Bool) {
        guard let device = videoDevice, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            if on {
                try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            } else {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
        } catch {
            logger.error("torch: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Recording

    private func startRecording() {
        guard !isRecording else { return }
        guard hasFrame() else {
            report("The camera isn't ready yet.")
            return
        }
        settings.refreshDate()
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            report("Recording without audio. Microphone access is off.")
        }
        isRecording = true
        recordingDuration = 0
        recordingStarted = Date()
        startRecordTimer()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        videoQueue.async {
            self.recordingThumbnail = nil
            self.recorder.begin(url: url, audioFormat: self.currentAudioFormat())
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recordTimer?.invalidate()
        recordTimer = nil
        videoQueue.async {
            self.recorder.stopAccepting()
            let thumbnail = self.recordingThumbnail
            self.recordingThumbnail = nil
            Task {
                let result = await self.recorder.finish()
                DispatchQueue.main.async {
                    self.recordingDuration = 0
                    switch result {
                    case .saved(let movie):
                        self.onVideo?(movie.url, thumbnail ?? Self.placeholderThumbnail(), movie.duration)
                    case .tooShort:
                        self.report("That clip was too short to keep.")
                    case .failed(let message):
                        self.report(message)
                    }
                }
            }
        }
    }

    private static func placeholderThumbnail() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    private func startRecordTimer() {
        recordTimer?.invalidate()
        let start = recordingStarted
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.isRecording else { return }
            self.recordingDuration = Date().timeIntervalSince(start)
        }
        recordTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Frames

    private func handleVideo(_ sampleBuffer: CMSampleBuffer, connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let snapshot = currentShared()

        let portPosition = connection.inputPorts.first?.sourceDevicePosition ?? .unspecified
        let front = (portPosition == .unspecified ? snapshot.position : portPosition) == .front
        let mirrored = connection.isVideoMirrored
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        // Normal case for both cameras: the connection already rotated to portrait (and mirrored the
        // front camera), so the buffer is used as is.
        // Fallback when a buffer is still landscape: an unmirrored sensor buffer needs a quarter turn
        // clockwise (.right) for either camera. A landscape buffer the connection already mirrored
        // left to right would come out of that turn upside down, so it takes the counterclockwise
        // turn (.left) instead. Both end up the same as the portrait case.
        if image.extent.width > image.extent.height + 1 {
            image = image.oriented(mirrored ? .left : .right)
        }
        if front && !mirrored {
            image = image.oriented(.upMirrored)
        }
        image = image.normalizedOrigin().croppedToEvenAspect(snapshot.previewAspect)

        if lastFramePosition != snapshot.position {
            lastFramePosition = snapshot.position
            postcardHistory.reset()
            let rawWidth = CVPixelBufferGetWidth(pixelBuffer)
            let rawHeight = CVPixelBufferGetHeight(pixelBuffer)
            let side = front ? "front" : "back"
            let angle = Double(connection.videoRotationAngle)
            logger.info("\(side, privacy: .public) buffer \(rawWidth)x\(rawHeight) angle \(angle) mirrored \(mirrored)")
        }
        if !snapshot.hasFrame {
            stateLock.lock()
            shared.hasFrame = true
            stateLock.unlock()
        }

        let capturing = capturePhotoOnNextFrame
        let copy = settings.copyForCurrentFrame()
        let output: CIImage
        switch snapshot.artStyle {
        case .postcard:
            output = compositor.composite(image, copy: copy, history: postcardHistory)
        case .sonnyBoy:
            output = handTracker.styled(image, forceFull: capturing)
        }
        guard let buffer = frames.render(output) else { return }
        let unmirror = front && !Self.saveFrontCameraMirrored
        // The postcard stamp has printed text, so flipping its output would write it backwards.
        // Postcard videos keep the previewed view; postcard photos are drawn again from the true view.
        let flipForSave = unmirror && snapshot.artStyle == .sonnyBoy

        let recycle: (CVPixelBuffer) -> Void = { [weak self] buffer in
            self?.frames.recycle(buffer)
            return
        }

        if recorder.isAccepting {
            if recordingThumbnail == nil {
                recordingThumbnail = compositor.thumbnail(from: Self.saved(buffer, mirrored: flipForSave))
            }
            recorder.appendVideo(buffer, at: time, mirrored: flipForSave)
        }

        if capturePhotoOnNextFrame {
            capturePhotoOnNextFrame = false
            let restoreTorch = turnTorchOffAfterPhoto
            turnTorchOffAfterPhoto = false
            let photoImage: CIImage
            if unmirror && snapshot.artStyle == .postcard {
                let trueView = image.oriented(.upMirrored).normalizedOrigin()
                photoImage = compositor.composite(trueView, copy: copy)
            } else {
                photoImage = Self.saved(buffer, mirrored: flipForSave)
            }
            if let photo = compositor.uiImage(from: photoImage) {
                DispatchQueue.main.async {
                    self.onPhoto?(photo)
                    return
                }
            }
            if restoreTorch {
                sessionQueue.async { self.setTorch(false) }
            }
        }

        if let preview = currentPreview() {
            preview.present(buffer, recycle: recycle)
        } else {
            recycle(buffer)
        }
    }

    private static func saved(_ buffer: CVPixelBuffer, mirrored: Bool) -> CIImage {
        let image = CIImage(cvPixelBuffer: buffer)
        guard mirrored else { return image }
        return image.oriented(.upMirrored).normalizedOrigin()
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        if currentAudioFormat() == nil,
           let format = CMSampleBufferGetFormatDescription(sampleBuffer),
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            stateLock.lock()
            shared.audioFormat = basic
            stateLock.unlock()
        }
        recorder.appendAudio(sampleBuffer)
    }

    // MARK: - Shared state

    private struct Shared {
        var position: AVCaptureDevice.Position = .back
        var previewAspect: CGFloat = 9.0 / 19.5
        var wantsRunning = false
        var wideZoom: CGFloat = 1
        var hasFrame = false
        var artStyle: ArtStyle = .postcard
        var audioFormat: AudioStreamBasicDescription?
    }

    private func currentShared() -> Shared {
        stateLock.lock()
        defer { stateLock.unlock() }
        return shared
    }

    private func currentPosition() -> AVCaptureDevice.Position {
        currentShared().position
    }

    private func wantsRunning() -> Bool {
        currentShared().wantsRunning
    }

    private func setWantsRunning(_ value: Bool) {
        stateLock.lock()
        shared.wantsRunning = value
        stateLock.unlock()
    }

    private func hasFrame() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return shared.hasFrame
    }

    private func currentAudioFormat() -> AudioStreamBasicDescription? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return shared.audioFormat
    }

    private func currentPreview() -> PreviewSurface? {
        previewLock.lock()
        defer { previewLock.unlock() }
        return previewSurface
    }

    private func publishDisplayZoom(_ deviceZoom: CGFloat) {
        stateLock.lock()
        let wide = shared.wideZoom
        stateLock.unlock()
        let display = wide > 0 ? deviceZoom / wide : deviceZoom
        DispatchQueue.main.async { self.zoomDisplay = display }
    }

    private func beginReadout() {
        readoutToken += 1
        let token = readoutToken
        isAdjustingZoom = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.readoutToken == token else { return }
            self.isAdjustingZoom = false
        }
    }

    private func publish(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }

    private func report(_ text: String) {
        DispatchQueue.main.async {
            self.onStatus?(text)
            return
        }
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let error = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "unknown"
            self.logger.error("session error: \(error, privacy: .public)")
            self.sessionQueue.async {
                guard self.wantsRunning(), !self.session.isRunning else { return }
                self.session.startRunning()
            }
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            self?.sessionQueue.async {
                self?.configureIfNeededAndStart()
                return
            }
            return
        })
        observers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stop()
            return
        })
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.start()
            return
        })
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === audioOutput {
            handleAudio(sampleBuffer)
        } else {
            handleVideo(sampleBuffer, connection: connection)
        }
    }
}
