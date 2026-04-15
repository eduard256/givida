import SwiftUI
import AppKit

@main
struct gividaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var overlayWindow: OverlayWindow?
    var borderWindow: BorderWindow?
    let recorder = ScreenRecorder()
    var statusMenuItem: NSMenuItem!
    var recordMenuItem: NSMenuItem!
    var pauseMenuItem: NSMenuItem!
    var keyDownMonitor: Any?
    var keyUpMonitor: Any?
    var zoomPreviewWindow: ZoomPreviewWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request accessibility permission
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        if !trusted {
            print("[givida] Accessibility not granted yet — hotkeys won't work until enabled")
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "givida")
        }

        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        recordMenuItem = NSMenuItem(title: "Start Recording (⌃⌥R)", action: #selector(toggleRecording), keyEquivalent: "")
        menu.addItem(recordMenuItem)

        pauseMenuItem = NSMenuItem(title: "Pause (⌃⌥P)", action: #selector(togglePause), keyEquivalent: "")
        pauseMenuItem.isEnabled = false
        menu.addItem(pauseMenuItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Select Area", action: #selector(selectArea), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu

        // Setup global hotkeys
        setupHotkeys()

        // Recorder state callback
        recorder.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.updateMenuState(state)
            }
        }

        // Show saved border if exists
        showSavedBorder()
    }

    func setupHotkeys() {
        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let ctrlOpt: NSEvent.ModifierFlags = [.control, .option]

            if flags == ctrlOpt {
                switch event.keyCode {
                case 15: // R
                    Task { @MainActor in self.toggleRecording() }
                case 35: // P
                    Task { @MainActor in self.togglePause() }
                case 6: // Z
                    if !event.isARepeat {
                        self.recorder.startZoom()
                    }
                default: break
                }
            }
        }

        keyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self else { return }
            // If ctrl or option released while zooming, stop zoom
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if self.recorder.isZooming && !flags.contains(.control) || !flags.contains(.option) {
                // Check if both ctrl+option are no longer held
                if !flags.contains(.control) || !flags.contains(.option) {
                    self.recorder.stopZoom()
                }
            }
        }

        // Also monitor keyUp for Z release
        NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self = self else { return }
            if event.keyCode == 6 && self.recorder.isZooming {
                self.recorder.stopZoom()
            }
        }

        // Setup zoom preview callback
        recorder.onZoomPreview = { [weak self] rect in
            self?.updateZoomPreview(rect)
        }
    }

    func updateZoomPreview(_ rect: CGRect) {
        guard recorder.state == .recording || recorder.state == .paused else {
            zoomPreviewWindow?.orderOut(nil)
            zoomPreviewWindow = nil
            return
        }

        let defaults = UserDefaults.standard
        let areaSize = defaults.double(forKey: "areaSize")
        guard areaSize > 0 else { return }

        // Only show preview when zooming
        guard recorder.isZooming || (zoomPreviewWindow != nil && rect.width < areaSize - 1) else {
            zoomPreviewWindow?.orderOut(nil)
            zoomPreviewWindow = nil
            return
        }

        let areaX = defaults.double(forKey: "areaX")
        let areaY = defaults.double(forKey: "areaY")
        let areaRect = NSRect(x: areaX, y: areaY, width: areaSize, height: areaSize)

        if zoomPreviewWindow == nil {
            zoomPreviewWindow = ZoomPreviewWindow(areaRect: areaRect)
            zoomPreviewWindow?.orderFront(nil)
        }
        zoomPreviewWindow?.updateVisibleRect(rect, areaRect: areaRect)
    }

    func updateMenuState(_ state: ScreenRecorder.State) {
        switch state {
        case .idle:
            statusMenuItem.title = "Status: Idle"
            recordMenuItem.title = "Start Recording (⌃⌥R)"
            pauseMenuItem.title = "Pause (⌃⌥P)"
            pauseMenuItem.isEnabled = false
            if let button = statusItem.button {
                button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "givida")
            }
        case .recording:
            statusMenuItem.title = "Status: Recording"
            recordMenuItem.title = "Stop Recording (⌃⌥R)"
            pauseMenuItem.title = "Pause (⌃⌥P)"
            pauseMenuItem.isEnabled = true
            if let button = statusItem.button {
                button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "givida recording")
            }
        case .paused:
            statusMenuItem.title = "Status: Paused"
            recordMenuItem.title = "Stop Recording (⌃⌥R)"
            pauseMenuItem.title = "Resume (⌃⌥P)"
            pauseMenuItem.isEnabled = true
            if let button = statusItem.button {
                button.image = NSImage(systemSymbolName: "pause.circle.fill", accessibilityDescription: "givida paused")
            }
        }
    }

    @objc func toggleRecording() {
        if recorder.state == .idle {
            Task {
                try? await recorder.startRecording()
            }
        } else {
            Task {
                await recorder.stopRecording()
            }
        }
    }

    @objc func togglePause() {
        recorder.togglePause()
    }

    @objc func selectArea() {
        // Remove existing windows safely
        borderWindow?.orderOut(nil)
        borderWindow = nil
        overlayWindow?.orderOut(nil)
        overlayWindow = nil

        // Show overlay for selection
        guard let screen = NSScreen.main else { return }
        let overlay = OverlayWindow(screen: screen, delegate: self)
        overlayWindow = overlay
        NSApp.activate(ignoringOtherApps: true)
        overlay.makeKeyAndOrderFront(nil)
    }

    func showSavedBorder() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "areaX") != nil else { return }

        let x = defaults.double(forKey: "areaX")
        let y = defaults.double(forKey: "areaY")
        let size = defaults.double(forKey: "areaSize")

        guard size > 0 else { return }

        let rect = NSRect(x: x, y: y, width: size, height: size)
        borderWindow = BorderWindow(rect: rect)
        borderWindow?.orderFront(nil)
    }

    func areaSelected(rect: NSRect) {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil

        // Save to UserDefaults
        let defaults = UserDefaults.standard
        defaults.set(rect.origin.x, forKey: "areaX")
        defaults.set(rect.origin.y, forKey: "areaY")
        defaults.set(rect.width, forKey: "areaSize")

        // Show dashed border
        borderWindow?.orderOut(nil)
        borderWindow = nil
        let border = BorderWindow(rect: rect)
        borderWindow = border
        border.orderFront(nil)
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Overlay Window (darkened screen with selection square)

class OverlayWindow: NSWindow {
    weak var selectionDelegate: AppDelegate?

    init(screen: NSScreen, delegate: AppDelegate) {
        self.selectionDelegate = delegate
        super.init(contentRect: screen.frame,
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)

        self.level = .statusBar + 1
        self.isOpaque = false
        self.backgroundColor = .clear
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let overlayView = OverlayView(frame: screen.frame, delegate: delegate)
        self.contentView = overlayView
        self.makeFirstResponder(overlayView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class OverlayView: NSView {
    weak var selectionDelegate: AppDelegate?

    private var dragStart: NSPoint?
    private var currentRect: NSRect?
    private var isDragging = false
    private var isMoving = false
    private var isResizing = false
    private var moveOffset: NSPoint = .zero
    private var resizeCorner: Int = -1 // 0=TL, 1=TR, 2=BL, 3=BR

    private let confirmButtonSize: CGFloat = 36

    init(frame: NSRect, delegate: AppDelegate) {
        self.selectionDelegate = delegate
        super.init(frame: frame)

        // Load saved area if exists
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "areaX") != nil {
            let x = defaults.double(forKey: "areaX")
            let y = defaults.double(forKey: "areaY")
            let size = defaults.double(forKey: "areaSize")
            if size > 0 {
                currentRect = NSRect(x: x, y: y, width: size, height: size)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // Dark overlay
        NSColor.black.withAlphaComponent(0.5).setFill()
        dirtyRect.fill()

        // Clear the selected area
        if let rect = currentRect {
            NSColor.clear.setFill()
            let path = NSBezierPath(rect: rect)
            let ctx = NSGraphicsContext.current?.cgContext
            ctx?.setBlendMode(.copy)
            path.fill()

            // White border around selection
            NSColor.white.setStroke()
            let borderPath = NSBezierPath(rect: rect)
            borderPath.lineWidth = 2
            borderPath.stroke()

            // Corner handles
            let handleSize: CGFloat = 10
            NSColor.white.setFill()
            for corner in corners(of: rect) {
                let handleRect = NSRect(x: corner.x - handleSize/2, y: corner.y - handleSize/2, width: handleSize, height: handleSize)
                NSBezierPath(ovalIn: handleRect).fill()
            }

            // Confirm button (checkmark) below the selection
            let btnX = rect.midX - confirmButtonSize/2
            let btnY = rect.minY - confirmButtonSize - 10
            let btnRect = NSRect(x: btnX, y: btnY, width: confirmButtonSize, height: confirmButtonSize)

            NSColor.white.setFill()
            NSBezierPath(roundedRect: btnRect, xRadius: 8, yRadius: 8).fill()

            // Draw checkmark
            let checkPath = NSBezierPath()
            NSColor.black.setStroke()
            checkPath.lineWidth = 3
            checkPath.lineCapStyle = .round
            checkPath.lineJoinStyle = .round
            checkPath.move(to: NSPoint(x: btnRect.minX + 10, y: btnRect.midY))
            checkPath.line(to: NSPoint(x: btnRect.midX - 2, y: btnRect.minY + 10))
            checkPath.line(to: NSPoint(x: btnRect.maxX - 10, y: btnRect.maxY - 10))
            checkPath.stroke()
        }
    }

    private func corners(of rect: NSRect) -> [NSPoint] {
        [
            NSPoint(x: rect.minX, y: rect.maxY), // TL
            NSPoint(x: rect.maxX, y: rect.maxY), // TR
            NSPoint(x: rect.minX, y: rect.minY), // BL
            NSPoint(x: rect.maxX, y: rect.minY), // BR
        ]
    }

    private func cornerIndex(at point: NSPoint, in rect: NSRect) -> Int? {
        let threshold: CGFloat = 15
        for (i, corner) in corners(of: rect).enumerated() {
            if hypot(point.x - corner.x, point.y - corner.y) < threshold {
                return i
            }
        }
        return nil
    }

    private func confirmButtonRect() -> NSRect? {
        guard let rect = currentRect else { return nil }
        let btnX = rect.midX - confirmButtonSize/2
        let btnY = rect.minY - confirmButtonSize - 10
        return NSRect(x: btnX, y: btnY, width: confirmButtonSize, height: confirmButtonSize)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Check confirm button
        if let btnRect = confirmButtonRect(), btnRect.contains(point) {
            if let rect = currentRect {
                selectionDelegate?.areaSelected(rect: rect)
            }
            return
        }

        if let rect = currentRect {
            // Check corner resize
            if let corner = cornerIndex(at: point, in: rect) {
                isResizing = true
                resizeCorner = corner
                return
            }

            // Check move
            if rect.contains(point) {
                isMoving = true
                moveOffset = NSPoint(x: point.x - rect.origin.x, y: point.y - rect.origin.y)
                return
            }
        }

        // New selection
        isDragging = true
        dragStart = point
        currentRect = nil
    }

    private func clampRect(_ rect: NSRect) -> NSRect {
        let bounds = self.bounds
        var r = rect
        let maxSide = min(bounds.width, bounds.height)
        let side = min(r.width, maxSide)
        r.size = NSSize(width: side, height: side)
        r.origin.x = max(0, min(r.origin.x, bounds.width - side))
        r.origin.y = max(0, min(r.origin.y, bounds.height - side))
        return r
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if isDragging, let start = dragStart {
            let dx = point.x - start.x
            let dy = point.y - start.y
            var side = max(abs(dx), abs(dy))
            let maxSide = min(bounds.width, bounds.height)
            side = min(side, maxSide)
            let x = dx >= 0 ? start.x : start.x - side
            let y = dy >= 0 ? start.y : start.y - side
            currentRect = clampRect(NSRect(x: x, y: y, width: side, height: side))
            needsDisplay = true
        } else if isMoving, let rect = currentRect {
            let newX = point.x - moveOffset.x
            let newY = point.y - moveOffset.y
            currentRect = clampRect(NSRect(x: newX, y: newY, width: rect.width, height: rect.height))
            needsDisplay = true
        } else if isResizing, let rect = currentRect {
            // Resize from the opposite corner
            let oppositeCorners = [3, 2, 1, 0] // opposite of TL=BR, TR=BL, BL=TR, BR=TL
            let anchorCorner = corners(of: rect)[oppositeCorners[resizeCorner]]

            let dx = point.x - anchorCorner.x
            let dy = point.y - anchorCorner.y
            var side = max(abs(dx), abs(dy))
            let maxSide = min(bounds.width, bounds.height)
            side = min(max(side, 20), maxSide)

            let x = dx >= 0 ? anchorCorner.x : anchorCorner.x - side
            let y = dy >= 0 ? anchorCorner.y : anchorCorner.y - side
            currentRect = clampRect(NSRect(x: x, y: y, width: side, height: side))
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        isMoving = false
        isResizing = false
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            selectionDelegate?.overlayWindow?.orderOut(nil)
            selectionDelegate?.overlayWindow = nil
            selectionDelegate?.showSavedBorder()
        }
    }

    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Border Window (dashed outline of saved area)

class BorderWindow: NSWindow {
    init(rect: NSRect) {
        let padding: CGFloat = 4
        let windowRect = rect.insetBy(dx: -padding, dy: -padding)
        super.init(contentRect: windowRect,
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)

        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.hasShadow = false

        let borderView = BorderView(frame: NSRect(origin: .zero, size: windowRect.size), selectionSize: rect.size)
        self.contentView = borderView
    }
}

class BorderView: NSView {
    let selectionSize: NSSize

    init(frame: NSRect, selectionSize: NSSize) {
        self.selectionSize = selectionSize
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let padding: CGFloat = 4
        let innerRect = NSRect(x: padding, y: padding, width: selectionSize.width, height: selectionSize.height)

        let path = NSBezierPath(rect: innerRect)
        path.lineWidth = 2
        let pattern: [CGFloat] = [6, 4]
        path.setLineDash(pattern, count: 2, phase: 0)

        NSColor.white.withAlphaComponent(0.7).setStroke()
        path.stroke()
    }
}

// MARK: - Zoom Preview Window (shows visible rect during zoom)

class ZoomPreviewWindow: NSWindow {
    private let previewView: ZoomPreviewView

    init(areaRect: NSRect) {
        previewView = ZoomPreviewView(frame: NSRect(origin: .zero, size: areaRect.size))
        super.init(contentRect: areaRect,
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)
        self.level = .floating + 1
        self.isOpaque = false
        self.backgroundColor = .clear
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.hasShadow = false
        self.contentView = previewView
    }

    func updateVisibleRect(_ zoomVisibleRect: CGRect, areaRect: NSRect) {
        // Convert visible rect to local coordinates within area
        let localRect = NSRect(
            x: zoomVisibleRect.origin.x - areaRect.origin.x,
            y: zoomVisibleRect.origin.y - areaRect.origin.y,
            width: zoomVisibleRect.width,
            height: zoomVisibleRect.height
        )
        previewView.zoomVisibleRect = localRect
        previewView.needsDisplay = true
    }
}

class ZoomPreviewView: NSView {
    var zoomVisibleRect: NSRect = .zero

    override func draw(_ dirtyRect: NSRect) {
        guard zoomVisibleRect.width > 0 && zoomVisibleRect.width < bounds.width - 1 else { return }

        // Semi-transparent overlay outside visible rect
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()

        // Clear the visible area
        NSColor.clear.setFill()
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.setBlendMode(.copy)
        NSBezierPath(rect: zoomVisibleRect).fill()

        // Yellow border around zoom area
        NSColor.systemYellow.withAlphaComponent(0.8).setStroke()
        let borderPath = NSBezierPath(rect: zoomVisibleRect)
        borderPath.lineWidth = 2
        borderPath.stroke()
    }
}
