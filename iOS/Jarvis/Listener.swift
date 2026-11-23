import AVFoundation
import Speech

/// Finnish dictation that stops by itself after a short silence.
@MainActor
final class Listener {
    var onPartial: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "fi-FI"))
    /// A new engine for every listen: the input format changes after speech
    /// playback or when headphones connect, and a stale one crashes installTap.
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var text = ""
    private var continuation: CheckedContinuation<String, Error>?

    /// How long a pause ends the command.
    static let silence: TimeInterval = 1.6

    enum Failure: LocalizedError {
        case denied, unavailable, noMicrophone
        var errorDescription: String? {
            switch self {
            case .denied: "Salli mikrofoni ja puheentunnistus asetuksista."
            case .unavailable: "Suomen puheentunnistus ei ole käytettävissä."
            case .noMicrophone: "Mikrofoni ei ole käytettävissä. Yritä uudelleen."
            }
        }
    }

    static func requestAccess() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech && mic
    }

    /// Listens until a pause, `finish()` or `cancel()`. Returns the text heard.
    func listen() async throws -> String {
        guard await Self.requestAccess() else { throw Failure.denied }
        guard let recognizer, recognizer.isAvailable else { throw Failure.unavailable }
        stopAudio()
        text = ""

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            self.request = nil
            throw Failure.noMicrophone
        }
        Self.installTap(on: engine.inputNode, format: format, request: request)
        self.engine = engine
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stopAudio()
            throw error
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            task = recognizer.recognitionTask(with: request, resultHandler: Self.handler { [weak self] text, isFinal, error in
                self?.received(text: text, isFinal: isFinal, error: error)
            })
            armSilenceTimer(initial: true)
        }
    }

    /// Ends listening now and returns what was heard.
    func finish() { complete(.success(text)) }

    func cancel() { complete(.failure(CancellationError())) }

    // MARK: Private

    private func received(text: String?, isFinal: Bool, error: Error?) {
        if let text, !text.isEmpty {
            self.text = text
            onPartial?(text)
            armSilenceTimer(initial: false)
        }
        if isFinal { complete(.success(self.text)) }
        else if error != nil, continuation != nil { complete(.success(self.text)) }
    }

    private func armSilenceTimer(initial: Bool) {
        silenceTimer?.invalidate()
        // Before the first word, wait longer for the speaker to start.
        let delay = initial ? 6 : Self.silence
        silenceTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }
    }

    private func complete(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        stopAudio()
        continuation.resume(with: result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
    }

    private func stopAudio() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        if let engine {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    /// Audio and recognition callbacks run off the main thread.
    nonisolated private static func installTap(on node: AVAudioInputNode, format: AVAudioFormat, request: SFSpeechAudioBufferRecognitionRequest) {
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    nonisolated private static func handler(_ deliver: @escaping @MainActor (String?, Bool, Error?) -> Void)
        -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in deliver(text, isFinal, error) }
        }
    }
}
