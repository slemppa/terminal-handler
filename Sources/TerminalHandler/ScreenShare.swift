import AppKit
import ApplicationServices
import ImageIO
import Observation
import OSLog
import ScreenCaptureKit
import Synchronization
import THCore
import UniformTypeIdentifiers

/// The phone's screen view, Mac side: frames of the main display for
/// `/jarvis/screen/frame` and clicks and keys for `/jarvis/screen/input`.
/// Both run on the HTTP server's own threads and block until done.
///
/// Needs Screen Recording (frames) and Accessibility (input). Off until
/// `jarvisScreenEnabled` is turned on from the island's menu.
nonisolated enum ScreenShare {
    private static let log = Logger(subsystem: "fi.slemppa.TerminalHandler", category: "screen")
    private static let askedForCapture = Mutex(false)
    private static let askedForInput = Mutex(false)

    nonisolated struct Frame: Sendable {
        var jpeg: Data
        /// The display in points, which is what taps are mapped to.
        var displayWidth: Double
        var displayHeight: Double
    }

    nonisolated enum Failure: Error, Sendable {
        case noCapturePermission
        case noInputPermission
        case failed(String)

        var status: Int {
            switch self {
            case .noCapturePermission, .noInputPermission: 403
            case .failed: 500
            }
        }

        /// Shown on the phone as is.
        var message: String {
            switch self {
            case .noCapturePermission:
                "Macilta puuttuu Näytön tallennus -lupa. Salli Terminal Handler: Järjestelmäasetukset → Yksityisyys ja suojaus → Näytön ja järjestelmän äänen tallennus."
            case .noInputPermission:
                "Macilta puuttuu Esteettömyys-lupa. Salli Terminal Handler: Järjestelmäasetukset → Yksityisyys ja suojaus → Esteettömyys."
            case .failed(let why): "Ruudun kaappaus epäonnistui: \(why)"
            }
        }
    }

    // MARK: Permissions

    /// Asks once per launch for whatever is missing. Called when sharing is
    /// turned on, so the prompts come while Sami is at the Mac.
    @MainActor static func askForPermissions() {
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
    }

    private static func ensureCapturePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        let first = askedForCapture.withLock { asked in defer { asked = true }; return !asked }
        if first { Task { @MainActor in _ = CGRequestScreenCaptureAccess() } }
        return false
    }

    private static func ensureInputPermission() -> Bool {
        if AXIsProcessTrusted() { return true }
        let first = askedForInput.withLock { asked in defer { asked = true }; return !asked }
        if first {
            Task { @MainActor in
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
        }
        return false
    }

    // MARK: Frames

    /// Blocks the calling (server) thread for at most `timeout` seconds.
    static func capture(_ request: ScreenAPI.FrameRequest, timeout: TimeInterval = 5) -> Result<Frame, Failure> {
        guard ensureCapturePermission() else { return .failure(.noCapturePermission) }
        let box = ResultBox()
        Task.detached {
            let frame = await captureNow(request)
            box.set(frame)
        }
        guard box.done.wait(timeout: .now() + timeout) == .success else {
            return .failure(.failed("aikakatkaisu"))
        }
        return box.value ?? .failure(.failed("ei kuvaa"))
    }

    private static func captureNow(_ request: ScreenAPI.FrameRequest) async -> Result<Frame, Failure> {
        do {
            let mainID = CGMainDisplayID()
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
                return .failure(.failed("näyttöä ei löydy"))
            }
            let bounds = CGDisplayBounds(display.displayID)
            let size = ScreenAPI.frameSize(width: bounds.width, height: bounds.height, maxSide: request.maxSide)
            let config = SCStreamConfiguration()
            config.width = size.width
            config.height = size.height
            config.showsCursor = true
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let jpeg = jpegData(image, quality: request.quality) else {
                return .failure(.failed("JPEG-muunnos"))
            }
            return .success(Frame(jpeg: jpeg, displayWidth: bounds.width, displayHeight: bounds.height))
        } catch {
            log.error("capture failed: \(error.localizedDescription)")
            // A revoked permission shows up here, not in the preflight.
            if !CGPreflightScreenCaptureAccess() { return .failure(.noCapturePermission) }
            return .failure(.failed(error.localizedDescription))
        }
    }

    private static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Hands the async capture's result back to the waiting thread.
    nonisolated private final class ResultBox: Sendable {
        let done = DispatchSemaphore(value: 0)
        private let result = Mutex<Result<Frame, Failure>?>(nil)

        var value: Result<Frame, Failure>? { result.withLock { $0 } }

        func set(_ value: Result<Frame, Failure>) {
            result.withLock { $0 = value }
            done.signal()
        }
    }

    // MARK: Input

    /// Clicks, scrolls or types on the main display.
    static func perform(_ input: ScreenInput) -> Failure? {
        guard ensureInputPermission() else { return .noInputPermission }
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let source = CGEventSource(stateID: .hidSystemState)

        func point(_ p: ScreenPoint) -> CGPoint {
            let local = p.on(width: bounds.width, height: bounds.height)
            // Keep off the very last pixel, which belongs to the next display.
            return CGPoint(x: bounds.minX + min(local.x, bounds.width - 1), y: bounds.minY + min(local.y, bounds.height - 1))
        }

        func mouse(_ type: CGEventType, at location: CGPoint, button: CGMouseButton = .left, clicks: Int = 1) {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: button) else { return }
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
            event.post(tap: .cghidEventTap)
        }

        func key(_ code: UInt16, flags: CGEventFlags = []) {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
                event.flags = flags
                event.post(tap: .cghidEventTap)
            }
        }

        switch input {
        case .move(let p):
            mouse(.mouseMoved, at: point(p))

        case .tap(let p, let clicks, let button):
            let location = point(p)
            mouse(.mouseMoved, at: location)
            switch button {
            case .left:
                mouse(.leftMouseDown, at: location, clicks: clicks)
                mouse(.leftMouseUp, at: location, clicks: clicks)
            case .right:
                mouse(.rightMouseDown, at: location, button: .right, clicks: clicks)
                mouse(.rightMouseUp, at: location, button: .right, clicks: clicks)
            }

        case .drag(let from, let to):
            let start = point(from), end = point(to)
            mouse(.mouseMoved, at: start)
            mouse(.leftMouseDown, at: start)
            // Small steps, so windows and sliders follow instead of jumping.
            let steps = 16
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                mouse(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
                usleep(8_000)
            }
            mouse(.leftMouseUp, at: end)

        case .scroll(let p, let dx, let dy):
            mouse(.mouseMoved, at: point(p))
            CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                    wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0)?
                .post(tap: .cghidEventTap)

        case .text(let text):
            for character in text {
                switch character {
                case "\n", "\r\n", "\r": key(36)
                case "\t": key(48)
                default:
                    let units = Array(String(character).utf16)
                    for down in [true, false] {
                        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                        event.flags = []
                        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                        event.post(tap: .cghidEventTap)
                    }
                }
                // Some apps drop characters that come faster than this.
                usleep(1_500)
            }

        case .key(let k, let modifiers):
            var flags: CGEventFlags = []
            for modifier in modifiers {
                switch modifier {
                case .command: flags.insert(.maskCommand)
                case .shift: flags.insert(.maskShift)
                case .option: flags.insert(.maskAlternate)
                case .control: flags.insert(.maskControl)
                }
            }
            key(k.code, flags: flags)
        }
        return nil
    }
}

/// Whether the phone is looking at the screen right now, for the island.
/// A frame request counts as looking for a few seconds after it.
@Observable
final class ScreenShareMonitor {
    private(set) var active = false
    @ObservationIgnored private var lastSeen = Date.distantPast
    @ObservationIgnored private var watcher: Task<Void, Never>?

    static let idleAfter: TimeInterval = 4

    func seen() {
        lastSeen = .now
        guard !active else { return }
        active = true
        Notifier.screenShareStarted()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if Date.now.timeIntervalSince(self.lastSeen) > Self.idleAfter {
                    self.active = false
                    return
                }
            }
        }
    }
}
