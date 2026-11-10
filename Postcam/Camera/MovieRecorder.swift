import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import os

struct RecordedMovie {
    var url: URL
    var duration: TimeInterval
}

enum RecordingFinish {
    case saved(RecordedMovie)
    case tooShort
    case failed(String)
}

/// Writes already-stamped frames plus microphone audio. Video frames are BGRA copies
/// we own; this type compresses them on the way into the file.
final class MovieRecorder {
    private let context: CIContext
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.chelseacheng.postcam", category: "recorder")

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var url: URL?
    private var accepting = false
    private var started = false
    private var failed = false
    private var width = 0
    private var height = 0
    private var startTime: CMTime?
    private var lastTime: CMTime?
    private var audioFormat: AudioStreamBasicDescription?
    private var earlyAudio: [CMSampleBuffer] = []

    init(context: CIContext) {
        self.context = context
    }

    var isAccepting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return accepting
    }

    func begin(url: URL, audioFormat: AudioStreamBasicDescription?) {
        lock.lock()
        defer { lock.unlock() }
        resetLocked()
        try? FileManager.default.removeItem(at: url)
        self.url = url
        self.audioFormat = audioFormat
        self.accepting = true
        self.failed = false
    }

    func stopAccepting() {
        lock.lock()
        accepting = false
        lock.unlock()
    }

    func appendVideo(_ buffer: CVPixelBuffer, at time: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        guard accepting, !failed else { return }
        if writer == nil {
            guard openWriter(matching: buffer, at: time) else { return }
        }
        guard let writer, writer.status == .writing,
              let input = videoInput, input.isReadyForMoreMediaData,
              let adaptor else { return }

        guard let destination = makePixelBuffer() else { return }
        let image = CIImage(cvPixelBuffer: buffer).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        context.render(
            image,
            to: destination,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        if adaptor.append(destination, withPresentationTime: time) {
            lastTime = time
            flushAudioLocked()
        } else {
            logger.error("Video append failed: \(writer.error?.localizedDescription ?? "unknown", privacy: .public)")
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard accepting, !failed else { return }
        guard started, let input = audioInput, writer?.status == .writing else {
            if earlyAudio.count < 64 {
                earlyAudio.append(sampleBuffer)
            }
            return
        }
        writeAudioLocked(sampleBuffer, input: input)
    }

    func finish() async -> RecordingFinish {
        let writer: AVAssetWriter?
        let url: URL?
        let start: CMTime?
        let end: CMTime?
        lock.lock()
        accepting = false
        writer = self.writer
        url = self.url
        start = startTime
        end = lastTime
        if started {
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
        }
        lock.unlock()

        guard let writer, let url else {
            return .failed("The recording never started.")
        }

        if writer.status == .writing {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                writer.finishWriting { continuation.resume() }
            }
        }

        let status = writer.status
        let message = writer.error?.localizedDescription
        lock.lock()
        resetLocked()
        lock.unlock()

        guard status == .completed, let start, let end else {
            try? FileManager.default.removeItem(at: url)
            return .failed(message ?? "Couldn't finish the video.")
        }
        let duration = CMTimeGetSeconds(CMTimeSubtract(end, start))
        guard duration.isFinite, duration >= 0.4 else {
            try? FileManager.default.removeItem(at: url)
            return .tooShort
        }
        return .saved(RecordedMovie(url: url, duration: duration))
    }

    private func openWriter(matching buffer: CVPixelBuffer, at time: CMTime) -> Bool {
        guard let url else { return false }
        var width = CVPixelBufferGetWidth(buffer)
        var height = CVPixelBufferGetHeight(buffer)
        width -= width % 2
        height -= height % 2
        guard width >= 2, height >= 2 else { return false }
        self.width = width
        self.height = height

        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: width * height * 6,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 30,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(videoInput) else {
                fail("Couldn't add a video track.")
                return false
            }
            writer.add(videoInput)

            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: attributes
            )

            if let format = audioFormat, format.mSampleRate >= 8000, format.mChannelsPerFrame > 0 {
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: format.mSampleRate,
                    AVNumberOfChannelsKey: Int(format.mChannelsPerFrame),
                    AVEncoderBitRateKey: 128_000
                ]
                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                audioInput.expectsMediaDataInRealTime = true
                if writer.canAdd(audioInput) {
                    writer.add(audioInput)
                    self.audioInput = audioInput
                }
            }

            guard writer.startWriting() else {
                fail(writer.error?.localizedDescription ?? "Couldn't start the file.")
                return false
            }
            writer.startSession(atSourceTime: time)
            self.writer = writer
            self.videoInput = videoInput
            self.adaptor = adaptor
            self.started = true
            self.startTime = time
            return true
        } catch {
            fail(error.localizedDescription)
            return false
        }
    }

    private func makePixelBuffer() -> CVPixelBuffer? {
        if let pool = adaptor?.pixelBufferPool {
            var buffer: CVPixelBuffer?
            if CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer {
                return buffer
            }
        }
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        let status = CVPixelBufferCreate(
            nil,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess else { return nil }
        return buffer
    }

    private func flushAudioLocked() {
        guard let input = audioInput else {
            earlyAudio.removeAll()
            return
        }
        let buffered = earlyAudio
        earlyAudio.removeAll()
        for sample in buffered {
            writeAudioLocked(sample, input: input)
        }
    }

    private func writeAudioLocked(_ sampleBuffer: CMSampleBuffer, input: AVAssetWriterInput) {
        guard let startTime else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTimeCompare(timestamp, startTime) >= 0 else { return }
        guard input.isReadyForMoreMediaData else { return }
        if !input.append(sampleBuffer) {
            logger.error("Audio append failed")
        }
    }

    private func fail(_ message: String) {
        failed = true
        logger.error("\(message, privacy: .public)")
    }

    private func resetLocked() {
        writer = nil
        videoInput = nil
        audioInput = nil
        adaptor = nil
        url = nil
        accepting = false
        started = false
        failed = false
        width = 0
        height = 0
        startTime = nil
        lastTime = nil
        earlyAudio.removeAll()
    }
}
