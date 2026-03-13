import Foundation
import AVFoundation
import Speech

// MARK: - Audio Bridge (P-501, P-502)

/// Manages microphone capture with live transcription and audio output (TTS + buffer playback)
/// for ports. Events stream through the PortBridge event system.
@MainActor
public final class AudioBridge {

    private weak var bridge: PortBridge?

    // Capture state
    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isCapturing = false

    // TTS state
    private var synthesizer: AVSpeechSynthesizer?
    private var speechDelegate: SpeechFinishedDelegate?

    // Playback state
    private var audioPlayer: AVAudioPlayer?

    public init(bridge: PortBridge) {
        self.bridge = bridge
    }

    // MARK: - Capture (P-501)

    /// Start microphone capture with optional speech transcription.
    public func capture(opts: [String: Any]) async -> [String: Any] {
        guard !isCapturing else {
            return ["error": "capture already in progress"]
        }

        let transcribe = opts["transcribe"] as? Bool ?? true
        let language = opts["language"] as? String ?? "en-US"
        let rawAudio = opts["rawAudio"] as? Bool ?? false

        // Request macOS system microphone permission (TCC)
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard micGranted else {
            NSLog("[Port42] audio.capture: system microphone permission denied")
            return ["error": "microphone access denied by system. Check System Settings > Privacy & Security > Microphone"]
        }

        // If transcribing, request speech recognition authorization
        if transcribe {
            let speechStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            guard speechStatus == .authorized else {
                NSLog("[Port42] audio.capture: speech recognition permission denied (status=%d)", speechStatus.rawValue)
                return ["error": "speech recognition permission denied. Check System Settings > Privacy & Security > Speech Recognition"]
            }
        }

        // Set up AVAudioEngine
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
            NSLog("[Port42] audio.capture: no valid audio input format (sampleRate=%.0f, channels=%d)",
                  recordingFormat.sampleRate, recordingFormat.channelCount)
            return ["error": "no audio input device available"]
        }

        // Set up speech recognition if requested
        var recognizer: SFSpeechRecognizer?
        var request: SFSpeechAudioBufferRecognitionRequest?
        var task: SFSpeechRecognitionTask?

        if transcribe {
            let locale = Locale(identifier: language)
            recognizer = SFSpeechRecognizer(locale: locale)

            guard let recognizer, recognizer.isAvailable else {
                NSLog("[Port42] audio.capture: speech recognizer unavailable for locale %@", language)
                return ["error": "speech recognizer not available for language '\(language)'"]
            }

            request = SFSpeechAudioBufferRecognitionRequest()
            request!.shouldReportPartialResults = true
            if #available(macOS 13.0, *) {
                request!.requiresOnDeviceRecognition = false
            }

            let bridgeRef = self.bridge

            task = recognizer.recognitionTask(with: request!) { result, error in
                if let result {
                    let text = result.bestTranscription.formattedString
                    let isFinal = result.isFinal
                    Task { @MainActor in
                        bridgeRef?.pushEvent("audio.transcription", data: [
                            "text": text,
                            "isFinal": isFinal
                        ])
                    }
                }
                if let error {
                    let nsError = error as NSError
                    // Skip normal cancellation (216) and no-speech timeout (1110)
                    if nsError.code != 216 && nsError.code != 1110 {
                        NSLog("[Port42] speech recognition error: %@", error.localizedDescription)
                        Task { @MainActor in
                            bridgeRef?.pushEvent("audio.transcription", data: [
                                "text": "",
                                "isFinal": true,
                                "error": error.localizedDescription
                            ])
                        }
                    }
                }
            }
        }

        // Install audio tap on input node
        let bridgeRef = self.bridge
        let sampleRate = recordingFormat.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request?.append(buffer)

            if rawAudio {
                guard let channelData = buffer.floatChannelData else { return }
                let frameCount = Int(buffer.frameLength)
                let data = Data(bytes: channelData[0], count: frameCount * MemoryLayout<Float>.size)
                let base64 = data.base64EncodedString()

                Task { @MainActor in
                    bridgeRef?.pushEvent("audio.data", data: [
                        "samples": base64,
                        "sampleRate": sampleRate,
                        "frameCount": frameCount,
                        "format": "float32"
                    ])
                }
            }
        }

        // Start the engine
        do {
            engine.prepare()
            try engine.start()
        } catch {
            NSLog("[Port42] audio.capture: engine start failed: %@", error.localizedDescription)
            inputNode.removeTap(onBus: 0)
            task?.cancel()
            return ["error": "failed to start audio capture: \(error.localizedDescription)"]
        }

        self.audioEngine = engine
        self.speechRecognizer = recognizer
        self.recognitionRequest = request
        self.recognitionTask = task
        self.isCapturing = true

        NSLog("[Port42] audio.capture started (transcribe=%d, language=%@, rawAudio=%d, sampleRate=%.0f)",
              transcribe, language, rawAudio, sampleRate)
        return ["ok": true, "sampleRate": sampleRate]
    }

    /// Stop microphone capture and speech recognition.
    public func stopCapture() -> [String: Any] {
        guard isCapturing else {
            return ["error": "no active capture"]
        }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        audioEngine = nil
        speechRecognizer = nil
        recognitionRequest = nil
        recognitionTask = nil
        isCapturing = false

        NSLog("[Port42] audio.capture stopped")
        return ["ok": true]
    }

    // MARK: - Speech Output (P-502)

    /// Speak text using AVSpeechSynthesizer. Resolves when speech finishes.
    public func speak(text: String, opts: [String: Any]?) async -> [String: Any] {
        guard !text.isEmpty else {
            return ["error": "audio.speak requires non-empty text"]
        }

        let utterance = AVSpeechUtterance(string: text)

        let voiceId = opts?["voice"] as? String ?? "en-US"
        if let voice = AVSpeechSynthesisVoice(language: voiceId) {
            utterance.voice = voice
        } else {
            NSLog("[Port42] audio.speak: voice not found for '%@', using default", voiceId)
        }

        if let rate = opts?["rate"] as? Double {
            utterance.rate = Float(max(0.0, min(1.0, rate)))
        } else {
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        }

        if let pitch = opts?["pitch"] as? Double {
            utterance.pitchMultiplier = Float(max(0.5, min(2.0, pitch)))
        }

        if let volume = opts?["volume"] as? Double {
            utterance.volume = Float(max(0.0, min(1.0, volume)))
        }

        if synthesizer == nil {
            synthesizer = AVSpeechSynthesizer()
        }

        let result: [String: Any] = await withCheckedContinuation { continuation in
            let delegate = SpeechFinishedDelegate {
                continuation.resume(returning: ["ok": true])
            }
            self.speechDelegate = delegate
            self.synthesizer!.delegate = delegate
            self.synthesizer!.speak(utterance)
        }

        NSLog("[Port42] audio.speak completed: %d chars", text.count)
        return result
    }

    // MARK: - Audio Playback (P-502)

    /// Play a base64-encoded audio buffer (WAV, MP3, AAC, etc).
    public func play(data: String, opts: [String: Any]?) -> [String: Any] {
        guard let audioData = Data(base64Encoded: data) else {
            return ["error": "invalid base64 audio data"]
        }

        guard !audioData.isEmpty else {
            return ["error": "empty audio data"]
        }

        audioPlayer?.stop()

        do {
            let player = try AVAudioPlayer(data: audioData)

            if let volume = opts?["volume"] as? Double {
                player.volume = Float(max(0.0, min(1.0, volume)))
            }

            player.prepareToPlay()
            player.play()
            self.audioPlayer = player

            NSLog("[Port42] audio.play started: %.1fs duration", player.duration)
            return ["ok": true, "duration": player.duration]
        } catch {
            NSLog("[Port42] audio.play failed: %@", error.localizedDescription)
            return ["error": "failed to play audio: \(error.localizedDescription)"]
        }
    }

    // MARK: - Stop All Output

    /// Stop any active speech synthesis or audio playback.
    public func stop() -> [String: Any] {
        if let synth = synthesizer, synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
        if let player = audioPlayer, player.isPlaying {
            player.stop()
        }
        return ["ok": true]
    }

    // MARK: - Cleanup

    /// Release all audio resources. Called from PortBridge deinit.
    public func cleanup() {
        if isCapturing {
            _ = stopCapture()
        }
        _ = stop()
        synthesizer = nil
        audioPlayer = nil
        speechDelegate = nil
    }

    /// Whether capture is currently active.
    public var capturing: Bool { isCapturing }
}

// MARK: - Speech Delegate

/// Bridges AVSpeechSynthesizerDelegate callbacks to async continuation.
private final class SpeechFinishedDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let onFinished: () -> Void
    private var completed = false

    init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
        super.init()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard !completed else { return }
        completed = true
        onFinished()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard !completed else { return }
        completed = true
        onFinished()
    }
}
