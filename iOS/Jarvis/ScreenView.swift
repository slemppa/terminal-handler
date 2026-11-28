import SwiftUI
import UIKit

/// The Mac's screen on the phone: tap to click, pinch to zoom, type with
/// the phone's own keyboard. Frames come from `/jarvis/screen/frame` one
/// after another; input goes to `/jarvis/screen/input` in order.
struct ScreenView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var stream = ScreenStream()
    @State private var mode: ScreenCanvasView.Mode = .point
    @State private var keyboard = false
    /// Held for the next key or letter, then released (⌘ then C = ⌘C).
    @State private var modifiers: [String] = []

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScreenCanvas(image: stream.image, screenSize: stream.screenSize, mode: mode) { stream.send($0) }
                .ignoresSafeArea(edges: .horizontal)
            if stream.image == nil {
                placeholder
            }
            KeyCapture(active: $keyboard, onText: typed, onDelete: { press("delete") })
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityHidden(true)
        }
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { controls }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            Orientation.allowLandscape(true)
            stream.start()
        }
        .onDisappear {
            stream.stop()
            Orientation.allowLandscape(false)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { stream.start() } else { stream.stop() }
        }
    }

    // MARK: Bars

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .bold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.14)))
            }
            .accessibilityLabel("Sulje")
            if let error = stream.error {
                Text(error).font(.system(size: 13)).foregroundStyle(.red).lineLimit(2)
            } else {
                Text("Macin ruutu").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(MacShortcut.all) { shortcut in
                    Button(shortcut.title) { stream.key(shortcut.key, modifiers: shortcut.modifiers) }
                }
            } label: {
                Image(systemName: "command").font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.14)))
            }
            .accessibilityLabel("Pikanäppäimet")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.85))
    }

    private var controls: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(["command", "shift", "option", "control"], id: \.self) { name in
                        KeyButton(label: Self.symbol(name), held: modifiers.contains(name)) { toggle(name) }
                    }
                    Divider().frame(height: 24)
                    KeyButton(label: "esc") { press("escape") }
                    KeyButton(label: "⇥") { press("tab") }
                    KeyButton(label: "←") { press("left") }
                    KeyButton(label: "↑") { press("up") }
                    KeyButton(label: "↓") { press("down") }
                    KeyButton(label: "→") { press("right") }
                    KeyButton(label: "⌫") { press("delete") }
                    KeyButton(label: "↩") { press("return") }
                }
                .padding(.horizontal, 14)
            }
            HStack(spacing: 10) {
                Picker("Tila", selection: $mode) {
                    Image(systemName: "cursorarrow.click").tag(ScreenCanvasView.Mode.point)
                        .accessibilityLabel("Osoita")
                    Image(systemName: "arrow.up.and.down").tag(ScreenCanvasView.Mode.scroll)
                        .accessibilityLabel("Vieritä")
                    Image(systemName: "hand.draw").tag(ScreenCanvasView.Mode.drag)
                        .accessibilityLabel("Vedä")
                }
                .pickerStyle(.segmented)
                Button { keyboard.toggle() } label: {
                    Image(systemName: keyboard ? "keyboard.chevron.compact.down" : "keyboard")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 52, height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(keyboard ? Color.cyan : Color.white.opacity(0.14)))
                        .foregroundStyle(keyboard ? .black : .white)
                }
                .accessibilityLabel(keyboard ? "Piilota näppäimistö" : "Näppäimistö")
            }
            .padding(.horizontal, 14)
            Text(mode.hint).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Color.black.opacity(0.85))
    }

    @ViewBuilder private var placeholder: some View {
        if stream.error == nil {
            ProgressView("Haetaan ruutua…").tint(.white).foregroundStyle(.secondary)
        } else {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 44)).foregroundStyle(.secondary)
        }
    }

    // MARK: Keys

    private func typed(_ text: String) {
        if !modifiers.isEmpty, text.count == 1 {
            press(text.lowercased())
        } else {
            stream.type(text)
        }
    }

    private func press(_ key: String) {
        stream.key(key, modifiers: modifiers)
        modifiers = []
    }

    private func toggle(_ modifier: String) {
        if let index = modifiers.firstIndex(of: modifier) {
            modifiers.remove(at: index)
        } else {
            modifiers.append(modifier)
        }
    }

    private static func symbol(_ modifier: String) -> String {
        switch modifier {
        case "command": "⌘"
        case "shift": "⇧"
        case "option": "⌥"
        default: "⌃"
        }
    }
}

private struct KeyButton: View {
    let label: String
    var held = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 16, weight: .semibold))
                .frame(minWidth: 40, minHeight: 34)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(held ? Color.cyan : Color.white.opacity(0.14)))
                .foregroundStyle(held ? .black : .white)
        }
        .sensoryFeedback(.selection, trigger: held)
    }
}

struct MacShortcut: Identifiable {
    var title: String
    var key: String
    var modifiers: [String]
    var id: String { title }

    static let all: [MacShortcut] = [
        MacShortcut(title: "Spotlight (⌘ välilyönti)", key: "space", modifiers: ["command"]),
        MacShortcut(title: "Vaihda appia (⌘⇥)", key: "tab", modifiers: ["command"]),
        MacShortcut(title: "Kopioi (⌘C)", key: "c", modifiers: ["command"]),
        MacShortcut(title: "Liitä (⌘V)", key: "v", modifiers: ["command"]),
        MacShortcut(title: "Kumoa (⌘Z)", key: "z", modifiers: ["command"]),
        MacShortcut(title: "Valitse kaikki (⌘A)", key: "a", modifiers: ["command"]),
        MacShortcut(title: "Tallenna (⌘S)", key: "s", modifiers: ["command"]),
        MacShortcut(title: "Uusi välilehti (⌘T)", key: "t", modifiers: ["command"]),
        MacShortcut(title: "Sulje ikkuna (⌘W)", key: "w", modifiers: ["command"]),
        MacShortcut(title: "Lopeta appi (⌘Q)", key: "q", modifiers: ["command"]),
        MacShortcut(title: "Mission Control (⌃↑)", key: "up", modifiers: ["control"]),
    ]
}

extension ScreenCanvasView.Mode {
    var hint: String {
        switch self {
        case .point: "Napauta = klikkaus · kaksi napautusta = tuplaklikkaus · pidä = oikea klikkaus · nipistä = zoomaa"
        case .scroll: "Vedä sormella vierittääksesi Macilla"
        case .drag: "Vedä siirtääksesi ikkunaa tai valitaksesi tekstiä"
        }
    }
}

// MARK: - Stream

/// Fetches frames back to back while the view is open, and sends input in
/// the order it was given. Typed text is batched for a moment, so a fast
/// typist does not cost one request per letter.
@MainActor
@Observable
final class ScreenStream {
    private(set) var image: UIImage?
    private(set) var screenSize: CGSize = .zero
    private(set) var error: String?

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var inputTail: Task<Void, Never>?
    @ObservationIgnored private var pendingText = ""
    @ObservationIgnored private var textFlush: Task<Void, Never>?

    /// Frames are sized for the phone; zooming in shows the JPEG's detail.
    static let maxSide = 1800
    static let quality = 0.5

    func start() {
        guard loop == nil else { return }
        guard let client = Settings.client else {
            error = RemoteError.notConfigured.localizedDescription
            return
        }
        loop = Task { await run(client) }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        flushText()
    }

    private func run(_ client: RemoteClient) async {
        while !Task.isCancelled {
            do {
                let frame = try await client.screenFrame(maxSide: Self.maxSide, quality: Self.quality)
                guard let decoded = await UIImage(data: frame.jpeg)?.byPreparingForDisplay() else { continue }
                if Task.isCancelled { return }
                image = decoded
                screenSize = frame.screenSize
                error = nil
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                self.error = Self.describe(error)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Input

    func send(_ command: ScreenCommand) {
        flushText()
        enqueue(command.json)
    }

    func key(_ name: String, modifiers: [String] = []) {
        flushText()
        enqueue(["key": name, "modifiers": modifiers])
    }

    func type(_ text: String) {
        pendingText += text
        textFlush?.cancel()
        textFlush = Task {
            try? await Task.sleep(for: .milliseconds(60))
            if !Task.isCancelled { flushText() }
        }
    }

    private func flushText() {
        textFlush?.cancel()
        textFlush = nil
        guard !pendingText.isEmpty else { return }
        let text = pendingText
        pendingText = ""
        enqueue(["text": text])
    }

    private func enqueue(_ body: [String: Any]) {
        guard let client = Settings.client,
              let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        let previous = inputTail
        inputTail = Task {
            await previous?.value
            do {
                try await client.screenInput(data)
            } catch {
                self.error = Self.describe(error)
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        if case RemoteError.http(403, let message) = error {
            if message.contains("turned off") {
                return "Ruudun ohjaus on pois päältä. Macilla: saareke → oikea klikkaus → Salli ruudun ohjaus puhelimesta."
            }
            return message
        }
        if let url = error as? URLError {
            switch url.code {
            case .cannotFindHost, .cannotConnectToHost, .notConnectedToInternet, .timedOut:
                return "Mac ei vastaa. Onko Tailscale päällä puhelimessa ja Macilla?"
            default: break
            }
        }
        return error.localizedDescription
    }
}

/// What a gesture on the canvas asks for. Points are fractions of the screen.
enum ScreenCommand {
    case tap(CGPoint, clicks: Int)
    case rightClick(CGPoint)
    case scroll(CGPoint, dx: Double, dy: Double)
    case drag(from: CGPoint, to: CGPoint)

    var json: [String: Any] {
        func pair(_ p: CGPoint) -> [Double] { [Double(p.x), Double(p.y)] }
        switch self {
        case .tap(let p, let clicks): return ["tap": pair(p), "clicks": clicks]
        case .rightClick(let p): return ["tap": pair(p), "button": "right"]
        case .scroll(let p, let dx, let dy): return ["scroll": pair(p), "dx": dx, "dy": dy]
        case .drag(let from, let to): return ["drag": ["from": pair(from), "to": pair(to)]]
        }
    }
}

// MARK: - Canvas

struct ScreenCanvas: UIViewRepresentable {
    var image: UIImage?
    var screenSize: CGSize
    var mode: ScreenCanvasView.Mode
    var onCommand: (ScreenCommand) -> Void

    func makeUIView(context: Context) -> ScreenCanvasView { ScreenCanvasView() }

    func updateUIView(_ view: ScreenCanvasView, context: Context) {
        view.onCommand = onCommand
        view.mode = mode
        view.setImage(image, screenSize: screenSize)
    }
}

/// A zoomable image of the Mac's screen that turns touches into commands.
final class ScreenCanvasView: UIView, UIScrollViewDelegate {
    enum Mode: Hashable { case point, scroll, drag }

    var onCommand: ((ScreenCommand) -> Void)?
    var mode: Mode = .point {
        didSet {
            guard mode != oldValue else { return }
            // One finger pans the zoomed image only when pointing.
            scrollView.panGestureRecognizer.isEnabled = mode == .point
            pan.isEnabled = mode != .point
        }
    }

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let pan = UIPanGestureRecognizer()
    private var screenSize: CGSize = .zero
    private var imageAspect: CGFloat = 0
    private var laidOutFor: CGSize = .zero

    private var lastTap: (time: Date, point: CGPoint)?
    private var dragStart: CGPoint?
    private var scrollAnchor: CGPoint?
    private var lastTranslation: CGPoint = .zero
    private var pendingScroll: CGPoint = .zero
    private var lastScrollSent = Date.distantPast

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.panGestureRecognizer.maximumNumberOfTouches = 2
        addSubview(scrollView)
        imageView.contentMode = .scaleToFill
        scrollView.addSubview(imageView)

        let long = UILongPressGestureRecognizer(target: self, action: #selector(longPressed))
        long.minimumPressDuration = 0.5
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.require(toFail: long)
        pan.addTarget(self, action: #selector(panned))
        pan.maximumNumberOfTouches = 1
        pan.isEnabled = false
        for recognizer in [long, tap, pan] { scrollView.addGestureRecognizer(recognizer) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        if bounds.size != laidOutFor { relayout() }
    }

    func setImage(_ image: UIImage?, screenSize: CGSize) {
        self.screenSize = screenSize
        guard imageView.image !== image else { return }
        imageView.image = image
        guard let image, image.size.height > 0 else { return }
        let aspect = image.size.width / image.size.height
        if abs(aspect - imageAspect) > 0.001 {
            imageAspect = aspect
            relayout()
        }
    }

    /// Fits the image at zoom 1. Runs when the view or the Mac's display
    /// changes shape, e.g. when the phone is turned sideways.
    private func relayout() {
        guard imageAspect > 0, bounds.width > 0, bounds.height > 0 else { return }
        laidOutFor = bounds.size
        scrollView.zoomScale = 1
        let fit = bounds.width / bounds.height > imageAspect
            ? CGSize(width: bounds.height * imageAspect, height: bounds.height)
            : CGSize(width: bounds.width, height: bounds.width / imageAspect)
        imageView.frame = CGRect(origin: .zero, size: fit)
        scrollView.contentSize = fit
        centerImage()
    }

    private func centerImage() {
        let size = imageView.frame.size
        let x = max(0, (scrollView.bounds.width - size.width) / 2)
        let y = max(0, (scrollView.bounds.height - size.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    // MARK: Gestures

    /// The touch as fractions of the screen; nil outside it unless clamped.
    private func point(_ recognizer: UIGestureRecognizer, clamp: Bool = false) -> CGPoint? {
        let size = imageView.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        let location = recognizer.location(in: imageView)
        var p = CGPoint(x: location.x / size.width, y: location.y / size.height)
        if clamp {
            p = CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
        }
        guard (0...1).contains(p.x), (0...1).contains(p.y) else { return nil }
        return p
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let p = point(recognizer) else { return }
        // A second tap close by and soon after is a double click on the
        // same spot. The first one has already gone as a single click.
        if let last = lastTap, Date.now.timeIntervalSince(last.time) < 0.4,
           hypot((p.x - last.point.x) * imageAspect, p.y - last.point.y) < 0.03 {
            lastTap = nil
            onCommand?(.tap(last.point, clicks: 2))
        } else {
            lastTap = (.now, p)
            onCommand?(.tap(p, clicks: 1))
        }
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let p = point(recognizer) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onCommand?(.rightClick(p))
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        switch mode {
        case .point:
            return
        case .scroll:
            scroll(recognizer)
        case .drag:
            switch recognizer.state {
            case .began:
                dragStart = point(recognizer, clamp: true)
            case .ended:
                if let start = dragStart, let end = point(recognizer, clamp: true) {
                    onCommand?(.drag(from: start, to: end))
                }
                dragStart = nil
            case .cancelled, .failed:
                dragStart = nil
            default:
                break
            }
        }
    }

    /// Sends what the finger moved, in the Mac's points, at most ~14 times a second.
    private func scroll(_ recognizer: UIPanGestureRecognizer) {
        let size = imageView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        // In the image's own coordinates, so zooming does not change the speed on the Mac.
        let translation = recognizer.translation(in: imageView)
        switch recognizer.state {
        case .began:
            scrollAnchor = point(recognizer, clamp: true)
            lastTranslation = translation
            pendingScroll = .zero
        case .changed, .ended:
            let delta = CGPoint(x: translation.x - lastTranslation.x, y: translation.y - lastTranslation.y)
            lastTranslation = translation
            pendingScroll.x += delta.x / size.width * screenSize.width
            pendingScroll.y += delta.y / size.height * screenSize.height
            let ended = recognizer.state == .ended
            if ended || Date.now.timeIntervalSince(lastScrollSent) > 0.07, let anchor = scrollAnchor,
               pendingScroll != .zero {
                onCommand?(.scroll(anchor, dx: Double(pendingScroll.x), dy: Double(pendingScroll.y)))
                pendingScroll = .zero
                lastScrollSent = .now
            }
            if ended { scrollAnchor = nil }
        default:
            scrollAnchor = nil
        }
    }
}

// MARK: - Keyboard

/// An invisible view that brings up the phone's keyboard and hands every
/// key on: letters as text (any language, dictation too), ⌫ as delete.
struct KeyCapture: UIViewRepresentable {
    @Binding var active: Bool
    var onText: (String) -> Void
    var onDelete: () -> Void

    func makeUIView(context: Context) -> KeyCaptureView { KeyCaptureView() }

    func updateUIView(_ view: KeyCaptureView, context: Context) {
        view.onText = onText
        view.onDelete = onDelete
        view.onResign = { if active { active = false } }
        DispatchQueue.main.async {
            if active, !view.isFirstResponder {
                view.becomeFirstResponder()
            } else if !active, view.isFirstResponder {
                view.resignFirstResponder()
            }
        }
    }
}

final class KeyCaptureView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onResign: (() -> Void)?

    // UITextInputTraits: the Mac gets exactly what was typed.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default
    var keyboardAppearance: UIKeyboardAppearance = .dark

    override var canBecomeFirstResponder: Bool { true }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResign?() }
        return resigned
    }

    /// Always true, so ⌫ keeps working on an empty field.
    var hasText: Bool { true }
    func insertText(_ text: String) { onText?(text) }
    func deleteBackward() { onDelete?() }
}

// MARK: - Orientation

/// The app is portrait only, except while the screen is shown: the Mac's
/// display is wide, so turning the phone sideways makes it far bigger.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var allowsLandscape = false

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.allowsLandscape ? .allButUpsideDown : .portrait
    }
}

enum Orientation {
    @MainActor static func allowLandscape(_ allowed: Bool) {
        AppDelegate.allowsLandscape = allowed
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                var controller = window.rootViewController
                while let current = controller {
                    current.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = current.presentedViewController
                }
            }
            if !allowed {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
            }
        }
    }
}

// MARK: - Opening by voice

enum ScreenRequest {
    /// "Näytä ruutu", "avaa Macin näyttö", "näytä työpöytä": short commands
    /// only, so a longer one that happens to mention the screen still goes
    /// to Jarvis.
    static func matches(_ text: String) -> Bool {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        guard (2...4).contains(words.count) else { return false }
        let verbs: Set = ["näytä", "avaa", "jaa", "näytäppä"]
        let nouns: Set = ["ruutu", "ruudun", "ruutua", "näyttö", "näytön", "näyttöä", "työpöytä", "työpöydän"]
        return words.contains(where: verbs.contains) && words.contains(where: nouns.contains)
    }
}
