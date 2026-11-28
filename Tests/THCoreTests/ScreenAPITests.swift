import Foundation
import Testing
@testable import THCore

private func input(_ json: String) -> ScreenInput? { ScreenInput.parse(Data(json.utf8)) }

@Suite struct ScreenRouteTests {
    private let tailnet = ["host": "oma-mac.tail1234.ts.net", "content-type": "application/json", "authorization": "Bearer k1"]

    private func post(_ path: String, _ headers: [String: String]) -> HTTPRequest {
        HTTPRequest(method: "POST", path: path, headers: headers)
    }

    @Test func routes() {
        #expect(JarvisAPI.route(post("/jarvis/screen/frame", [:])) == .screenFrame)
        #expect(JarvisAPI.route(post("/v1/jarvis/screen/input/", [:])) == .screenInput)
        #expect(JarvisAPI.Route.screenFrame.isRemote)
        #expect(JarvisAPI.Route.screenInput.isScreen)
        #expect(!JarvisAPI.Route.remoteCommand.isScreen)
    }

    @Test func offUnlessEnabled() {
        let frame = post("/jarvis/screen/frame", tailnet)
        #expect(JarvisAPI.check(frame, route: .screenFrame, apiKey: "k1") == .screenOff)
        #expect(JarvisAPI.check(frame, route: .screenFrame, apiKey: "k1", screenEnabled: true) == nil)
        // The commands do not depend on it.
        #expect(JarvisAPI.check(post("/jarvis/command", tailnet), route: .remoteCommand, apiKey: "k1") == nil)
    }

    @Test func keyIsCheckedBeforeTheSwitch() {
        var wrong = tailnet
        wrong["authorization"] = "Bearer nope"
        #expect(JarvisAPI.check(post("/jarvis/screen/input", wrong), route: .screenInput, apiKey: "k1") == .unauthorized)
        #expect(JarvisAPI.check(post("/jarvis/screen/input", tailnet), route: .screenInput, apiKey: nil, screenEnabled: true) == .unauthorized)
    }

    @Test func browsersAndOtherHostsStayOut() {
        var browser = tailnet
        browser["origin"] = "https://evil.example"
        #expect(JarvisAPI.check(post("/jarvis/screen/frame", browser), route: .screenFrame, apiKey: "k1", screenEnabled: true) == .browserOrigin)
        var evil = tailnet
        evil["host"] = "evil.example"
        #expect(JarvisAPI.check(post("/jarvis/screen/frame", evil), route: .screenFrame, apiKey: "k1", screenEnabled: true) == .badHost)
    }
}

@Suite struct ScreenFrameTests {
    @Test func defaultsAndClamping() {
        #expect(ScreenAPI.frameRequest(Data()) == ScreenAPI.FrameRequest())
        #expect(ScreenAPI.frameRequest(Data(#"{"max_side":1200,"quality":0.4}"#.utf8)) == .init(maxSide: 1200, quality: 0.4))
        #expect(ScreenAPI.frameRequest(Data(#"{"max_side":99999,"quality":3}"#.utf8)) == .init(maxSide: 3840, quality: 0.95))
        #expect(ScreenAPI.frameRequest(Data(#"{"max_side":10,"quality":0}"#.utf8)) == .init(maxSide: 320, quality: 0.1))
    }

    @Test func sizeKeepsAspectAndNeverUpscales() {
        func size(_ w: Double, _ h: Double, _ max: Int) -> [Int] {
            let s = ScreenAPI.frameSize(width: w, height: h, maxSide: max)
            return [s.width, s.height]
        }
        #expect(size(1512, 982, 1600) == [1512, 982])
        #expect(size(3024, 1964, 1600) == [1600, 1039])
        #expect(size(1080, 1920, 960) == [540, 960])
        #expect(size(0, 900, 960) == [0, 0])
    }
}

@Suite struct ScreenInputTests {
    @Test func taps() {
        #expect(input(#"{"tap":[0.5,0.25]}"#) == .tap(ScreenPoint(x: 0.5, y: 0.25), clicks: 1, button: .left))
        #expect(input(#"{"tap":[1,0],"clicks":2}"#) == .tap(ScreenPoint(x: 1, y: 0), clicks: 2, button: .left))
        #expect(input(#"{"tap":[0.1,0.9],"button":"right"}"#) == .tap(ScreenPoint(x: 0.1, y: 0.9), clicks: 1, button: .right))
        // Rounding on the phone may land a hair outside; that is clamped.
        #expect(input(#"{"tap":[1.005,-0.004]}"#) == .tap(ScreenPoint(x: 1, y: 0), clicks: 1, button: .left))
    }

    @Test func badTapsAreRefused() {
        #expect(input(#"{"tap":[2,0.5]}"#) == nil)
        #expect(input(#"{"tap":[0.5]}"#) == nil)
        #expect(input(#"{"tap":["a","b"]}"#) == nil)
        #expect(input(#"{"tap":[0.5,0.5],"clicks":9}"#) == nil)
        #expect(input(#"{"tap":[0.5,0.5],"button":"middle"}"#) == nil)
    }

    @Test func dragScrollMove() {
        #expect(input(#"{"drag":{"from":[0.1,0.1],"to":[0.6,0.7]}}"#) == .drag(from: ScreenPoint(x: 0.1, y: 0.1), to: ScreenPoint(x: 0.6, y: 0.7)))
        #expect(input(#"{"drag":{"from":[0.1,0.1]}}"#) == nil)
        #expect(input(#"{"scroll":[0.5,0.5],"dy":120}"#) == .scroll(ScreenPoint(x: 0.5, y: 0.5), dx: 0, dy: 120))
        #expect(input(#"{"scroll":[0.5,0.5],"dx":-99999,"dy":1e9}"#) == .scroll(ScreenPoint(x: 0.5, y: 0.5), dx: -4000, dy: 4000))
        #expect(input(#"{"move":[0.3,0.3]}"#) == .move(ScreenPoint(x: 0.3, y: 0.3)))
    }

    @Test func text() {
        #expect(input(#"{"text":"Hyvää päivää 👋"}"#) == .text("Hyvää päivää 👋"))
        #expect(input(#"{"text":""}"#) == nil)
        let long = String(repeating: "a", count: ScreenAPI.maxTextLength + 1)
        #expect(input(#"{"text":"\#(long)"}"#) == nil)
    }

    @Test func keys() throws {
        let copy = try #require(input(#"{"key":"C","modifiers":["command","command"]}"#))
        let c = try #require(ScreenKey(name: "c"))
        #expect(copy == .key(c, modifiers: [.command]))
        #expect(ScreenKey(name: "enter")?.code == 36)
        #expect(ScreenKey(name: "Escape")?.code == 53)
        #expect(ScreenKey(name: "backspace")?.name == "delete")
        #expect(ScreenKey(name: "left")?.code == 123)
        #expect(ScreenKey(name: "f13") == nil)
        #expect(input(#"{"key":"return","modifiers":["hyper"]}"#) == nil)
        #expect(input(#"{"key":"nosuchkey"}"#) == nil)
    }

    @Test func nothingKnown() {
        #expect(input(#"{}"#) == nil)
        #expect(input(#"[1,2]"#) == nil)
        #expect(input("not json") == nil)
    }

    @Test func logNeverShowsTypedText() {
        let line = ScreenInput.text("salasana123").logDescription
        #expect(!line.contains("salasana"))
        #expect(line.contains("11"))
    }
}
