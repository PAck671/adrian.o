import AVFoundation
import Speech

@MainActor
final class VoiceInput: ObservableObject {
    @Published var text = ""
    @Published var isListening = false
    @Published var problem: String?

    private let recognizer = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start() async {
        guard !isListening else { return }
        text = ""
        problem = nil
        guard await Self.speechAllowed(), await AVAudioApplication.requestRecordPermission() else {
            problem = "Allow Microphone and Speech Recognition for TV Control in Settings."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            problem = "Voice recognition isn't available right now."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let newRequest = SFSpeechAudioBufferRecognitionRequest()
            newRequest.shouldReportPartialResults = true
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0), block: Self.tap(newRequest))
            engine.prepare()
            try engine.start()
            request = newRequest
            task = recognizer.recognitionTask(with: newRequest, resultHandler: Self.results(for: self))
            isListening = true
        } catch {
            problem = "Couldn't start the microphone."
            stop()
        }
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task?.finish()
        task = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // These callbacks arrive off the main thread, so they are built outside main-actor isolation.
    private nonisolated static func tap(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    private nonisolated static func results(for owner: VoiceInput) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak owner] result, error in
            let heard = result?.bestTranscription.formattedString
            let ended = error != nil || result?.isFinal == true
            Task { @MainActor in
                if let heard { owner?.text = heard }
                if ended, owner?.isListening == true { owner?.stop() }
            }
        }
    }

    private nonisolated static func speechAllowed() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }
}
