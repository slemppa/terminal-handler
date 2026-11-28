import Foundation

/// The phone's screen view: `/jarvis/screen/frame` returns the Mac's main
/// display as a JPEG, `/jarvis/screen/input` clicks, scrolls and types on it.
/// Both are off until `jarvisScreenEnabled` is turned on, and both need the
/// same key as the other phone routes.
///
/// Coordinates are fractions of the display (0…1, origin top left), so the
/// phone never needs to know the Mac's resolution.
public enum ScreenAPI {
    /// Longest side of a frame when the phone does not ask for one.
    public static let defaultMaxSide = 1600
    public static let maxSideRange = 320...3840
    public static let defaultQuality = 0.55
    /// One text event carries at most this much; longer text is refused.
    public static let maxTextLength = 2000

    public struct FrameRequest: Sendable, Equatable {
        public var maxSide: Int
        public var quality: Double

        public init(maxSide: Int = ScreenAPI.defaultMaxSide, quality: Double = ScreenAPI.defaultQuality) {
            self.maxSide = maxSide
            self.quality = quality
        }
    }

    /// An empty or unreadable body gets the defaults; values are clamped.
    public static func frameRequest(_ body: Data) -> FrameRequest {
        let json = JSONValue.parse(body)
        var request = FrameRequest()
        if let side = json?["max_side"]?.double {
            request.maxSide = min(max(Int(side), maxSideRange.lowerBound), maxSideRange.upperBound)
        }
        if let quality = json?["quality"]?.double {
            request.quality = min(max(quality, 0.1), 0.95)
        }
        return request
    }

    /// Pixel size of a frame whose display is `width` × `height` points.
    public static func frameSize(width: Double, height: Double, maxSide: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        let scale = min(1, Double(maxSide) / max(width, height))
        return (max(1, Int((width * scale).rounded())), max(1, Int((height * scale).rounded())))
    }

    /// Headers next to the JPEG, so the phone can map taps back.
    public static func frameHeaders(displayWidth: Double, displayHeight: Double, bytes: Int) -> [(String, String)] {
        [
            ("Content-Type", "image/jpeg"),
            ("Content-Length", String(bytes)),
            ("Cache-Control", "no-store"),
            ("X-Screen-Width", String(Int(displayWidth.rounded()))),
            ("X-Screen-Height", String(Int(displayHeight.rounded()))),
            ("Connection", "close"),
        ]
    }
}

/// A point on the display as fractions of its width and height.
public struct ScreenPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }

    /// `[x, y]` with both in 0…1. Anything else is refused, not clamped:
    /// a click far off the screen is a bug on the phone.
    static func parse(_ value: JSONValue?) -> ScreenPoint? {
        guard let pair = value?.array, pair.count == 2,
              let x = pair[0].double, let y = pair[1].double,
              x.isFinite, y.isFinite,
              (-0.01...1.01).contains(x), (-0.01...1.01).contains(y) else { return nil }
        return ScreenPoint(x: x, y: y)
    }

    /// The point in display coordinates.
    public func on(width: Double, height: Double) -> (x: Double, y: Double) {
        (x * width, y * height)
    }
}

public enum ScreenModifier: String, Sendable, CaseIterable {
    case command, shift, option, control
}

public enum ScreenButton: String, Sendable {
    case left, right
}

/// One thing the phone asks the Mac to do. Body shapes:
/// - `{"tap": [x, y], "clicks": 1|2|3, "button": "left"|"right"}`
/// - `{"move": [x, y]}`
/// - `{"drag": {"from": [x, y], "to": [x, y]}}`
/// - `{"scroll": [x, y], "dx": points, "dy": points}` (the content moves by dx, dy, as if dragged with a finger)
/// - `{"text": "…"}` (typed as Unicode, any keyboard layout)
/// - `{"key": "return", "modifiers": ["command"]}`
public enum ScreenInput: Sendable, Equatable {
    case tap(ScreenPoint, clicks: Int, button: ScreenButton)
    case move(ScreenPoint)
    case drag(from: ScreenPoint, to: ScreenPoint)
    case scroll(ScreenPoint, dx: Double, dy: Double)
    case text(String)
    case key(ScreenKey, modifiers: [ScreenModifier])

    public static func parse(_ body: Data) -> ScreenInput? {
        guard let json = JSONValue.parse(body), json.object != nil else { return nil }
        if json["tap"] != nil {
            guard let point = ScreenPoint.parse(json["tap"]) else { return nil }
            let clicks = Int(json["clicks"]?.double ?? 1)
            guard (1...3).contains(clicks) else { return nil }
            let button = ScreenButton(rawValue: json["button"]?.string ?? "left")
            guard let button else { return nil }
            return .tap(point, clicks: clicks, button: button)
        }
        if json["move"] != nil {
            return ScreenPoint.parse(json["move"]).map { .move($0) }
        }
        if let drag = json["drag"] {
            guard let from = ScreenPoint.parse(drag["from"]), let to = ScreenPoint.parse(drag["to"]) else { return nil }
            return .drag(from: from, to: to)
        }
        if json["scroll"] != nil {
            guard let point = ScreenPoint.parse(json["scroll"]) else { return nil }
            let dx = json["dx"]?.double ?? 0
            let dy = json["dy"]?.double ?? 0
            guard dx.isFinite, dy.isFinite else { return nil }
            // One event never jumps more than a few screens.
            return .scroll(point, dx: min(max(dx, -4000), 4000), dy: min(max(dy, -4000), 4000))
        }
        if let text = json["text"]?.string {
            guard !text.isEmpty, text.count <= ScreenAPI.maxTextLength else { return nil }
            return .text(text)
        }
        if let name = json["key"]?.string {
            guard let key = ScreenKey(name: name) else { return nil }
            var modifiers: [ScreenModifier] = []
            for value in json["modifiers"]?.array ?? [] {
                guard let modifier = value.string.flatMap(ScreenModifier.init(rawValue:)) else { return nil }
                if !modifiers.contains(modifier) { modifiers.append(modifier) }
            }
            return .key(key, modifiers: modifiers)
        }
        return nil
    }

    /// For the request log: never the typed text itself.
    public var logDescription: String {
        switch self {
        case .tap(_, let clicks, let button): "tap \(button.rawValue)×\(clicks)"
        case .move: "move"
        case .drag: "drag"
        case .scroll: "scroll"
        case .text(let text): "text (\(text.count) merkkiä)"
        case .key(let key, let modifiers): "key " + (modifiers.map(\.rawValue) + [key.name]).joined(separator: "+")
        }
    }
}

/// A key by name, with its macOS virtual key code (ANSI layout, the same
/// physical keys as the Finnish layout). Letters and digits are for
/// shortcuts such as ⌘C; plain text goes as `text`.
public struct ScreenKey: Sendable, Equatable {
    public var name: String
    public var code: UInt16

    public init?(name: String) {
        let lower = name.lowercased()
        let canonical = Self.aliases[lower] ?? lower
        guard let code = Self.codes[canonical] else { return nil }
        self.name = canonical
        self.code = code
    }

    static let aliases: [String: String] = [
        "enter": "return", "backspace": "delete", "del": "forwarddelete",
        "esc": "escape", "pgup": "pageup", "pgdown": "pagedown",
        " ": "space", "\t": "tab", "\n": "return",
    ]

    static let codes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        ",": 43, ".": 47,
        "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]
}

extension JSONValue {
    /// Integers and doubles alike.
    var double: Double? {
        switch self {
        case .int(let i): Double(i)
        case .number(let n): n
        default: nil
        }
    }
}
