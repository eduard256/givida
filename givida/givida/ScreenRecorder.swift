import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreGraphics

class ScreenRecorder: NSObject {
    enum State {
        case idle, recording, paused
    }

    private(set) var state: State = .idle
    var onStateChange: ((State) -> Void)?

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: CMTime?
    private var pauseStart: CMTime?
    private var totalPauseDuration: CMTime = .zero
    private var outputURL: URL?
    private var captureRect: CGRect = .zero

    func startRecording() async throws {
        guard state == .idle else { return }

        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "areaX") != nil else { return }

        let x = defaults.double(forKey: "areaX")
        let y = defaults.double(forKey: "areaY")
        let size = defaults.double(forKey: "areaSize")
        guard size > 0 else { return }

        // Convert from bottom-left (AppKit) to top-left (CGDisplay) coordinates
        guard let screen = NSScreen.main else { return }
        let screenHeight = screen.frame.height
        let cgY = screenHeight - y - size
        captureRect = CGRect(x: x, y: cgY, width: size, height: size)

        // Get available content
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { return }

        // Configure stream to capture the full display
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()

        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.sourceRect = captureRect
        config.width = 1080
        config.height = 1080

        // Setup output file
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "givida_\(timestamp).mp4"
        let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        outputURL = desktopURL.appendingPathComponent(filename)

        // Setup AVAssetWriter
        assetWriter = try AVAssetWriter(outputURL: outputURL!, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1080,
            AVVideoHeightKey: 1080,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ]
        ]

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput!.expectsMediaDataInRealTime = true

        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput!,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 1080,
                kCVPixelBufferHeightKey as String: 1080,
            ]
        )

        assetWriter!.add(videoInput!)
        assetWriter!.startWriting()
        assetWriter!.startSession(atSourceTime: .zero)

        startTime = nil
        totalPauseDuration = .zero

        // Start capture
        stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream!.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream!.startCapture()

        state = .recording
        onStateChange?(state)
    }

    func stopRecording() async {
        guard state == .recording || state == .paused else { return }

        try? await stream?.stopCapture()
        stream = nil

        videoInput?.markAsFinished()
        await assetWriter?.finishWriting()

        state = .idle
        startTime = nil
        onStateChange?(state)
    }

    func togglePause() {
        if state == .recording {
            pauseStart = CMClockGetTime(CMClockGetHostTimeClock())
            state = .paused
            onStateChange?(state)
        } else if state == .paused {
            if let pauseStart = pauseStart {
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                totalPauseDuration = CMTimeAdd(totalPauseDuration, CMTimeSubtract(now, pauseStart))
            }
            pauseStart = nil
            state = .recording
            onStateChange?(state)
        }
    }
}

extension ScreenRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, state == .recording else { return }
        guard let videoInput = videoInput, videoInput.isReadyForMoreMediaData else { return }
        guard let imageBuffer = sampleBuffer.imageBuffer else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if startTime == nil {
            startTime = timestamp
        }

        let elapsed = CMTimeSubtract(timestamp, startTime!)
        let adjusted = CMTimeSubtract(elapsed, totalPauseDuration)

        guard adjusted.seconds >= 0 else { return }

        adaptor?.append(imageBuffer, withPresentationTime: adjusted)
    }
}

extension ScreenRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            state = .idle
            onStateChange?(state)
        }
    }
}
