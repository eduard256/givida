import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreGraphics
import CoreImage

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

    // Area in CG coordinates (top-left origin)
    private var captureRect: CGRect = .zero
    // Area in AppKit coordinates (bottom-left origin)
    private var appKitRect: CGRect = .zero
    private var screenHeight: CGFloat = 0
    private var displayID: CGDirectDisplayID = 0

    // Zoom state
    private(set) var isZooming = false
    var zoomLevel: CGFloat = 2.5 // configurable
    private var currentZoom: CGFloat = 1.0
    private var targetZoom: CGFloat = 1.0
    private var currentCenter: CGPoint = .zero // CG coords
    private var targetCenter: CGPoint = .zero  // CG coords
    private var zoomAnimating = false

    // Spring animation parameters
    private let zoomInDuration: CGFloat = 0.4
    private let zoomOutDuration: CGFloat = 0.3
    private let followLerp: CGFloat = 0.12
    private var zoomStartTime: CFTimeInterval = 0
    private var zoomFromScale: CGFloat = 1.0
    private var zoomToScale: CGFloat = 1.0
    private var zoomFromCenter: CGPoint = .zero
    private var zoomToCenter: CGPoint = .zero
    private var isZoomTransitioning = false
    private var zoomTransitionDuration: CGFloat = 0.4

    // Display link for smooth animation
    private var displayLink: CVDisplayLink?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Preview callback
    var onZoomPreview: ((CGRect) -> Void)? // visible rect in AppKit coords

    private var areaCenter: CGPoint {
        CGPoint(x: captureRect.midX, y: captureRect.midY)
    }

    var excludeWindowNumbers: [Int] = []

    func startRecording() async throws {
        guard state == .idle else { return }

        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "areaX") != nil else { return }

        let x = defaults.double(forKey: "areaX")
        let y = defaults.double(forKey: "areaY")
        let size = defaults.double(forKey: "areaSize")
        guard size > 0 else { return }

        guard let screen = NSScreen.main else { return }
        screenHeight = screen.frame.height
        let cgY = screenHeight - y - size
        captureRect = CGRect(x: x, y: cgY, width: size, height: size)
        appKitRect = CGRect(x: x, y: y, width: size, height: size)

        currentCenter = areaCenter
        targetCenter = areaCenter
        currentZoom = 1.0
        targetZoom = 1.0

        // Get available content
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { return }
        displayID = display.displayID

        // Exclude all windows from our own app
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let excludeWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == bundleID
        }
        let filter = SCContentFilter(display: display, excludingWindows: excludeWindows)
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.width = Int(display.width)
        config.height = Int(display.height)

        // Setup output file
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "givida_\(timestamp).mp4"
        let saveDir: URL
        if let path = UserDefaults.standard.string(forKey: "saveFolder") {
            saveDir = URL(fileURLWithPath: path)
        } else {
            saveDir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        }
        outputURL = saveDir.appendingPathComponent(filename)

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
        isZooming = false
        currentZoom = 1.0
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

    // MARK: - Zoom

    private var zoomArmed = false // keys held, waiting for mouse move
    private var armedCursorPos: CGPoint = .zero

    func startZoom() {
        guard state == .recording || state == .paused else { return }
        guard !isZooming && !zoomArmed else { return }

        // Arm zoom — wait for mouse movement to actually start
        zoomArmed = true
        armedCursorPos = cursorPositionCG()
    }

    func stopZoom() {
        if zoomArmed {
            // Keys released before mouse moved — do nothing
            zoomArmed = false
            return
        }

        guard isZooming else { return }
        isZooming = false

        zoomFromScale = currentZoom
        zoomToScale = 1.0
        zoomFromCenter = currentCenter
        zoomToCenter = areaCenter
        zoomStartTime = CACurrentMediaTime()
        zoomTransitionDuration = zoomOutDuration
        isZoomTransitioning = true
    }

    private func checkArmedZoom() {
        guard zoomArmed else { return }
        let cursor = cursorPositionCG()
        let dist = hypot(cursor.x - armedCursorPos.x, cursor.y - armedCursorPos.y)
        if dist > 2 { // mouse moved — start zoom animation
            zoomArmed = false
            isZooming = true

            zoomFromScale = currentZoom
            zoomToScale = zoomLevel
            zoomFromCenter = currentCenter
            zoomToCenter = cursor
            zoomStartTime = CACurrentMediaTime()
            zoomTransitionDuration = zoomInDuration
            isZoomTransitioning = true
        }
    }

    private func cursorPositionCG() -> CGPoint {
        let nsPoint = NSEvent.mouseLocation
        return CGPoint(x: nsPoint.x, y: screenHeight - nsPoint.y)
    }

    // Called each frame to update zoom animation
    private func updateZoomState() {
        checkArmedZoom()

        if isZoomTransitioning {
            let elapsed = CGFloat(CACurrentMediaTime() - zoomStartTime)
            var t = min(elapsed / zoomTransitionDuration, 1.0)

            // Spring-like curve: critically damped
            t = springCurve(t)

            currentZoom = zoomFromScale + (zoomToScale - zoomFromScale) * t
            currentCenter = CGPoint(
                x: zoomFromCenter.x + (zoomToCenter.x - zoomFromCenter.x) * t,
                y: zoomFromCenter.y + (zoomToCenter.y - zoomFromCenter.y) * t
            )

            if elapsed >= zoomTransitionDuration {
                isZoomTransitioning = false
                currentZoom = zoomToScale
                currentCenter = zoomToCenter
            }
        } else if isZooming {
            // Follow cursor with soft lerp
            let cursorCG = cursorPositionCG()
            currentCenter = CGPoint(
                x: currentCenter.x + (cursorCG.x - currentCenter.x) * followLerp,
                y: currentCenter.y + (cursorCG.y - currentCenter.y) * followLerp
            )
        }

        // Send preview rect (in AppKit coords)
        if currentZoom > 1.001 {
            let visibleSize = captureRect.width / currentZoom
            let visibleRect = CGRect(
                x: currentCenter.x - visibleSize / 2,
                y: (screenHeight - currentCenter.y) - visibleSize / 2,
                width: visibleSize,
                height: visibleSize
            )
            DispatchQueue.main.async { [weak self] in
                self?.onZoomPreview?(visibleRect)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onZoomPreview?(self?.appKitRect ?? .zero)
            }
        }
    }

    // Critically damped spring: fast start, smooth end, no bounce
    private func springCurve(_ t: CGFloat) -> CGFloat {
        let x = t
        // Using cubic bezier approximation of critically damped spring
        // Similar to Apple's default animation curve
        return 1 - pow(1 - x, 3)
    }

    // Compute the visible rect in CG display coordinates for current zoom
    private func currentSourceRect(displayWidth: Int, displayHeight: Int) -> CGRect {
        let visibleSize = captureRect.width / currentZoom
        var rect = CGRect(
            x: currentCenter.x - visibleSize / 2,
            y: currentCenter.y - visibleSize / 2,
            width: visibleSize,
            height: visibleSize
        )

        // Don't clamp — allow going outside the selected area (but clamp to display)
        rect.origin.x = max(0, min(rect.origin.x, CGFloat(displayWidth) - rect.width))
        rect.origin.y = max(0, min(rect.origin.y, CGFloat(displayHeight) - rect.height))

        return rect
    }
}

extension ScreenRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, state == .recording else { return }
        guard let videoInput = videoInput, videoInput.isReadyForMoreMediaData else { return }
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if startTime == nil {
            startTime = timestamp
        }

        let elapsed = CMTimeSubtract(timestamp, startTime!)
        let adjusted = CMTimeSubtract(elapsed, totalPauseDuration)
        guard adjusted.seconds >= 0 else { return }

        // Update zoom animation
        updateZoomState()

        let fullWidth = CVPixelBufferGetWidth(pixelBuffer)
        let fullHeight = CVPixelBufferGetHeight(pixelBuffer)

        // Compute source rect in pixel coordinates
        let sourceRect = currentSourceRect(displayWidth: fullWidth, displayHeight: fullHeight)

        // Use CIImage to crop and scale
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // CIImage has flipped Y (origin bottom-left), convert
        let scaleY = CGFloat(fullHeight) / screenHeight
        let scaleX = CGFloat(fullWidth) / (NSScreen.main?.frame.width ?? CGFloat(fullWidth))

        let pixelRect = CGRect(
            x: sourceRect.origin.x * scaleX,
            y: CGFloat(fullHeight) - (sourceRect.origin.y + sourceRect.height) * scaleY,
            width: sourceRect.width * scaleX,
            height: sourceRect.height * scaleY
        )

        ciImage = ciImage.cropped(to: pixelRect)
        ciImage = ciImage.transformed(by: CGAffineTransform(translationX: -pixelRect.origin.x, y: -pixelRect.origin.y))

        // Scale to 1080x1080
        let outputScale = 1080.0 / pixelRect.width
        ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: outputScale, y: outputScale))

        // Render to pixel buffer
        guard let pool = adaptor?.pixelBufferPool else { return }
        var outputBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
        guard let outBuf = outputBuffer else { return }

        ciContext.render(ciImage, to: outBuf)
        adaptor?.append(outBuf, withPresentationTime: adjusted)
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
