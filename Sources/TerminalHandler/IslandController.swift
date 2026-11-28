import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// UI state shared by the panel and the SwiftUI view.
@Observable
final class IslandState {
    static let pillHeight: CGFloat = 30

    var expanded = false
    /// Opened with the hotkey: ⌘1…⌘9 and Esc are live until it closes.
    var keyboardMode = false
    /// The list opens downwards in the top half of the screen, upwards in the bottom half.
    var opensDownward = true
    var dragging = false
    /// Snapped into the menu bar: flush with the top edge, square top corners.
    var docked = false
    /// How far the collapsed pill sits from the panel's centre line, when the
    /// panel is pushed back on screen near a side edge.
    var shiftX: CGFloat = 0
    var pillWidth: CGFloat = 64
    /// Bumped to make the island bounce for attention.
    var attention = 0
    /// The island's frame inside the panel (top-left origin), used for hit testing.
    var islandFrame = CGRect.zero
}

/// Borderless, non-activating panel that floats above every app and Space.
final class IslandPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A spring described the way Apple describes it: damping ratio (1 = no
/// overshoot) and response (seconds to reach the target, not a duration).
private struct Spring {
    var value: CGFloat
    var velocity: CGFloat
    var target: CGFloat
    var damping: CGFloat = 1
    var response: CGFloat = 0.4

    mutating func step(_ dt: CGFloat) {
        let stiffness = pow(2 * .pi / response, 2)
        let friction = 4 * .pi * damping / response
        velocity += (-stiffness * (value - target) - friction * velocity) * dt
        value += velocity * dt
    }

    var settled: Bool { abs(value - target) < 0.3 && abs(velocity) < 4 }
}

/// Bridges the display link's Objective-C callback to a closure.
private final class DisplayLinkTarget: NSObject {
    let onTick: (CADisplayLink) -> Void
    init(_ onTick: @escaping (CADisplayLink) -> Void) { self.onTick = onTick }
    @objc func tick(_ link: CADisplayLink) { onTick(link) }
}

final class IslandController {
    static let panelSize = CGSize(width: 440, height: 600)
    /// How far below the menu bar a drop is still pulled into it.
    private static let dockReach: CGFloat = 60
    private static let anchorKey = "islandAnchor"

    private let model: AppModel
    private let state = IslandState()
    private let panel = IslandPanel()
    private var mouseTimer: Timer?
    private var insideSince: Date?
    private var outsideSince: Date?
    private var autoCollapseAt: Date?
    /// Centre of the pill in screen coordinates.
    private var anchor: CGPoint
    private var dragStart: (mouse: CGPoint, anchor: CGPoint)?
    private var mouseDownAt: CGPoint?
    private var mouseMonitor: Any?
    /// Recent drag positions, for the release velocity.
    private var samples: [(time: TimeInterval, point: CGPoint)] = []
    private var springX = Spring(value: 0, velocity: 0, target: 0)
    private var springY = Spring(value: 0, velocity: 0, target: 0)
    private var displayLink: CADisplayLink?
    private lazy var linkTarget = DisplayLinkTarget { [weak self] link in self?.step(link) }
    private var flying: Bool { displayLink != nil }

    init(model: AppModel) {
        self.model = model
        anchor = .zero
        anchor = resolved(Self.savedAnchor() ?? Self.defaultAnchor())
        let host = FirstMouseHostingView(rootView: IslandView(model: model, state: state, controller: self))
        host.sizingOptions = []
        panel.contentView = host
        placePanel()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.anchor = self.resolved(self.anchor)
                self.placePanel()
            }
        }
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        // Dragging is handled at the AppKit level so it works from any state
        // and is not fought over by SwiftUI's buttons and hover tracking.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handleMouse(event) ?? event
        }
        model.jarvis.onPhaseChange = { [weak self] phase in self?.jarvisPhaseChanged(phase) }
        let toggle = HotkeyDefaults.toggle
        HotkeyCenter.shared.register(id: 1, keyCode: toggle.keyCode, modifiers: toggle.modifiers) { [weak self] in
            self?.toggleFromKeyboard()
        }
    }

    // MARK: Placement

    private static func defaultAnchor() -> CGPoint {
        let visible = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(x: visible.maxX - 240, y: visible.maxY - IslandState.pillHeight / 2 - 12)
    }

    private static func savedAnchor() -> CGPoint? {
        guard let values = UserDefaults.standard.array(forKey: anchorKey) as? [Double], values.count == 2 else { return nil }
        return CGPoint(x: values[0], y: values[1])
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.screens.first { $0.frame.contains(anchor) }
            ?? NSScreen.main
    }

    /// The pill is near enough the top edge to belong in the menu bar.
    private func isDockable(_ point: CGPoint, on screen: NSScreen) -> Bool {
        // An auto-hidden menu bar has no height of its own; use the usual one.
        let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        return point.y + IslandState.pillHeight / 2 >= screen.frame.maxY - menuBarHeight - Self.dockReach
    }

    /// Keeps the pill on screen, and snaps it into the menu bar when it is
    /// brought close enough to the top edge.
    private func resolved(_ point: CGPoint) -> CGPoint {
        guard let screen = screen(containing: point) else { return point }
        let frame = screen.frame
        let visible = screen.visibleFrame
        let half = IslandState.pillHeight / 2
        let halfWidth = state.pillWidth / 2
        var x = min(max(point.x, frame.minX + halfWidth + 4), frame.maxX - halfWidth - 4)

        let docked = isDockable(point, on: screen)
        state.docked = docked
        guard docked else {
            return CGPoint(x: x, y: min(max(point.y, frame.minY + half + 4), visible.maxY - half - 4))
        }
        // The camera notch would hide the pill: slide it to the nearer side.
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let notch = (left.maxX - 6)...(right.minX + 6)
            if x + halfWidth > notch.lowerBound && x - halfWidth < notch.upperBound {
                x = x < (notch.lowerBound + notch.upperBound) / 2 ? notch.lowerBound - halfWidth : notch.upperBound + halfWidth
            }
        }
        return CGPoint(x: x, y: frame.maxY - half)
    }

    /// Positions the panel so the pill sits on `anchor` and the list has room to open.
    private func placePanel() {
        let size = Self.panelSize
        var x = anchor.x - size.width / 2
        if let screen = screen(containing: anchor) {
            state.opensDownward = state.docked || anchor.y > screen.visibleFrame.midY
            // Keep the panel, and so the open list, on screen; the pill shifts inside it.
            x = min(max(x, screen.frame.minX), screen.frame.maxX - size.width)
        }
        state.shiftX = anchor.x - (x + size.width / 2)
        let half = IslandState.pillHeight / 2
        let pad: CGFloat = 12 // IslandView's vertical padding, room for the shadow
        let y = state.opensDownward ? anchor.y + half + pad - size.height : anchor.y - half - pad
        panel.setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    /// The island's rect in screen coordinates, padded for easier hover.
    private var hitRect: CGRect {
        let f = state.islandFrame
        let rect = CGRect(x: panel.frame.minX + f.minX, y: panel.frame.maxY - f.maxY, width: f.width, height: f.height)
        return rect.insetBy(dx: state.expanded ? -6 : -8, dy: state.expanded ? -6 : -8)
    }

    // MARK: Dragging

    /// Returns nil to swallow the event once it has become a drag.
    private func handleMouse(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel else { return event }
        let mouse = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            stopFlight()
            mouseDownAt = mouse
            return event
        case .leftMouseDragged:
            guard let down = mouseDownAt else { return event }
            if dragStart == nil {
                guard hypot(mouse.x - down.x, mouse.y - down.y) > 4 else { return event }
                dragStart = (down, anchor)
                state.dragging = true
                setExpanded(false)
            }
            dragMoved(to: mouse)
            return nil
        case .leftMouseUp:
            mouseDownAt = nil
            guard dragStart != nil else { return event }
            dragEnded()
            return nil
        default:
            return event
        }
    }

    private func dragMoved(to mouse: CGPoint) {
        guard let start = dragStart else { return }
        anchor = rubberBanded(CGPoint(x: start.anchor.x + mouse.x - start.mouse.x, y: start.anchor.y + mouse.y - start.mouse.y))
        if let screen = screen(containing: anchor) { state.docked = isDockable(anchor, on: screen) }
        let now = ProcessInfo.processInfo.systemUptime
        samples.append((now, anchor))
        samples.removeAll { now - $0.time > 0.1 }
        placePanel()
    }

    /// Follows the mouse 1:1, but resists progressively past the screen edges
    /// instead of stopping dead.
    private func rubberBanded(_ point: CGPoint) -> CGPoint {
        guard let frame = screen(containing: point)?.frame else { return point }
        let half = IslandState.pillHeight / 2
        let halfWidth = state.pillWidth / 2
        func band(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            func resist(_ over: CGFloat) -> CGFloat { over * 200 * 0.55 / (200 + 0.55 * over) }
            if value < low { return low - resist(low - value) }
            if value > high { return high + resist(value - high) }
            return value
        }
        return CGPoint(x: band(point.x, frame.minX + halfWidth + 4, frame.maxX - halfWidth - 4),
                       y: band(point.y, frame.minY + half + 4, frame.maxY - half))
    }

    private func dragEnded() {
        dragStart = nil
        state.dragging = false
        insideSince = nil
        let velocity = releaseVelocity()
        samples = []
        // Land where the throw was heading, not where the mouse let go.
        let projected = CGPoint(x: anchor.x + Self.project(velocity.dx), y: anchor.y + Self.project(velocity.dy))
        let target = resolved(projected)
        UserDefaults.standard.set([target.x, target.y], forKey: Self.anchorKey)
        fly(to: target, velocity: velocity)
    }

    private func releaseVelocity() -> CGVector {
        let now = ProcessInfo.processInfo.systemUptime
        // Held still before letting go: no throw.
        guard let first = samples.first, let last = samples.last, now - last.time < 0.05 else { return .zero }
        let dt = last.time - first.time
        guard dt > 0.008 else { return .zero }
        return CGVector(dx: (last.point.x - first.point.x) / dt, dy: (last.point.y - first.point.y) / dt)
    }

    /// Apple's momentum projection, with a short deceleration so a flick
    /// throws the island a little way rather than across the screen.
    private static func project(_ velocity: CGFloat, deceleration: CGFloat = 0.99) -> CGFloat {
        velocity / 1000 * deceleration / (1 - deceleration)
    }

    private func fly(to target: CGPoint, velocity: CGVector) {
        stopFlight()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            anchor = target
            placePanel()
            return
        }
        // A throw earns a touch of bounce; a plain drop settles without one.
        // Never bounce up into the top edge.
        let thrown = hypot(velocity.dx, velocity.dy) > 400
        springX = Spring(value: anchor.x, velocity: velocity.dx, target: target.x, damping: thrown ? 0.85 : 1)
        springY = Spring(value: anchor.y, velocity: velocity.dy, target: target.y,
                         damping: thrown && !state.docked ? 0.85 : 1)
        let link = panel.displayLink(target: linkTarget, selector: #selector(DisplayLinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func step(_ link: CADisplayLink) {
        let dt = CGFloat(min(max(link.targetTimestamp - link.timestamp, 1.0 / 240), 1.0 / 30))
        let substeps = 4
        for _ in 0..<substeps {
            springX.step(dt / CGFloat(substeps))
            springY.step(dt / CGFloat(substeps))
        }
        if state.docked && springY.value > springY.target {
            springY.value = springY.target
            springY.velocity = 0
        }
        if springX.settled && springY.settled {
            anchor = CGPoint(x: springX.target, y: springY.target)
            stopFlight()
        } else {
            anchor = CGPoint(x: springX.value, y: springY.value)
        }
        placePanel()
    }

    /// Grabbing the island mid-flight takes over from wherever it is now.
    private func stopFlight() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: Mouse

    private func trackMouse() {
        guard !state.dragging, !flying else { return }
        let inside = hitRect.contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !inside
        let now = Date.now
        if inside {
            outsideSince = nil
            autoCollapseAt = nil
            if insideSince == nil { insideSince = now }
            // A held mouse button means a drag may be starting: don't open under it.
            if !state.expanded, NSEvent.pressedMouseButtons == 0, let since = insideSince, now.timeIntervalSince(since) >= 0.25 {
                setExpanded(true)
            }
        } else {
            insideSince = nil
            if outsideSince == nil { outsideSince = now }
            guard state.expanded, !state.keyboardMode else { return }
            if let deadline = autoCollapseAt {
                if now >= deadline { setExpanded(false) }
            } else if let since = outsideSince, now.timeIntervalSince(since) >= 0.3 {
                setExpanded(false)
            }
        }
    }

    // MARK: Expansion

    /// A new question: pop open for a while unless Sami is already in it.
    func questionArrived() {
        if !state.dragging { state.attention += 1 }
        guard !state.expanded, !state.dragging, !flying else { return }
        setExpanded(true)
        autoCollapseAt = Date.now.addingTimeInterval(6)
    }

    func collapse() { setExpanded(false) }

    /// Jarvis heard a command: open and stay open while it works and speaks,
    /// then close a moment after it falls silent.
    private func jarvisPhaseChanged(_ phase: JarvisController.Phase) {
        switch phase {
        case .received, .thinking, .speaking:
            if !state.expanded, !state.dragging, !flying { setExpanded(true) }
            if state.expanded { autoCollapseAt = .distantFuture }
        case .idle, .failed:
            if state.expanded, autoCollapseAt != nil { autoCollapseAt = Date.now.addingTimeInterval(phase == .idle ? 5 : 8) }
        }
        updateEscape()
    }

    /// Esc is a global hotkey only while it means something: closing the
    /// keyboard-opened list, or silencing Jarvis. Not while Jarvis only
    /// thinks, so Esc is not taken from other apps for a whole turn.
    private func updateEscape() {
        let center = HotkeyCenter.shared
        if state.keyboardMode || model.jarvis.isSpeaking {
            center.register(id: 2, keyCode: UInt32(kVK_Escape), modifiers: 0) { [weak self] in self?.escapePressed() }
        } else {
            center.unregister(id: 2)
        }
    }

    private func escapePressed() {
        let jarvis = model.jarvis
        if jarvis.isSpeaking {
            jarvis.stopSpeaking()
        } else {
            collapse()
        }
        updateEscape()
    }

    private func toggleFromKeyboard() {
        if state.expanded && state.keyboardMode {
            setExpanded(false)
        } else {
            setExpanded(true)
            setKeyboardMode(true)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard state.expanded != expanded else { return }
        state.expanded = expanded
        if !expanded {
            autoCollapseAt = nil
            setKeyboardMode(false)
        }
    }

    private func setKeyboardMode(_ on: Bool) {
        guard state.keyboardMode != on else { return }
        state.keyboardMode = on
        let center = HotkeyCenter.shared
        if on {
            for (index, code) in HotkeyDefaults.digitKeyCodes.enumerated() {
                center.register(id: UInt32(10 + index), keyCode: UInt32(code), modifiers: UInt32(cmdKey)) { [weak self] in
                    self?.jump(toRowAt: index)
                }
            }
        } else {
            for index in HotkeyDefaults.digitKeyCodes.indices { center.unregister(id: UInt32(10 + index)) }
        }
        updateEscape()
    }

    // MARK: Actions

    func jump(toRowAt index: Int) {
        guard model.rows.indices.contains(index) else { return }
        model.jump(to: model.rows[index].id)
        collapse()
    }

    func jump(to rowID: String) {
        model.jump(to: rowID)
        collapse()
    }
}
