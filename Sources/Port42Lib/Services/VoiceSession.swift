import Foundation

/// Hold-to-talk, from the key monitor to the text.
///
/// `VoiceTrigger` decides when a hold starts and ends. This turns those two moments into a microphone
/// and a transcription, and hands back the text. It does NOT insert the text: insertion is Phase 3, so
/// a wrong transcription cannot land in a document yet.
///
/// The model is not in the app bundle (~480 MB), so a hold can arrive before the weights exist. That
/// case does not fail: no engine starts, the state says which of absent / downloading / failed it is,
/// and the space bar keeps working. The trigger must never depend on the model.
@MainActor
public final class VoiceSession {

    private let source: VoiceAudioSource
    private let transcriber: VoiceTranscriber
    private let modelIsReady: @Sendable () async -> Bool

    /// Called with the text of a finished hold. Empty text (silence) is not reported.
    public var onText: ((String) -> Void)?
    /// Called while the hold is still open, with the words so far. Feedback only: nothing is inserted
    /// until the release, so trailing off mid-sentence leaves nothing to un-type.
    public var onPartial: ((String) -> Void)?
    /// Called when the model's state changes, so the indicator can show it.
    public var onModelState: ((VoiceModelState) -> Void)?

    public private(set) var model: VoiceModelState = .absent
    public private(set) var isCapturing = false
    /// The transcription started by the last release. Exposed so a test can await delivery instead of
    /// sleeping: a sleep long enough for a loaded machine is a slow suite, and a short one is a flake.
    public private(set) var transcription: Task<Void, Never>?

    /// How often the words so far are re-read while the hold is open. The whole buffer is transcribed
    /// each time rather than a sliding window: at the measured throughput a 40 second buffer costs about
    /// 200 ms, which is cheaper than a second model and gives the same text the release will give.
    public var partialInterval: TimeInterval = 1.0
    private var partials: Task<Void, Never>?

    /// Whether a 480 MB download may start. Off by default: a hold must not silently pull half a
    /// gigabyte. Phase 4 owns the surface that turns it on.
    public static let downloadAllowedKey = "voiceModelDownloadAllowed"

    public init(source: VoiceAudioSource,
                transcriber: VoiceTranscriber,
                modelIsReady: @escaping @Sendable () async -> Bool,
                model: VoiceModelState = .absent) {
        self.source = source
        self.transcriber = transcriber
        self.modelIsReady = modelIsReady
        self.model = model
    }

    /// The real one: the microphone and Parakeet.
    public static func live() -> VoiceSession {
        let transcriber = FluidVoiceTranscriber()
        return VoiceSession(source: VoiceCapture(),
                            transcriber: transcriber,
                            modelIsReady: { await transcriber.isReady() })
    }

    public func begin() {
        guard !isCapturing else { return }
        guard model == .ready else { prepareModel(); return }
        do {
            try source.start()
            isCapturing = true
            startPartials()
        } catch {
            setModel(.failed("microphone: \(error)"))
        }
    }

    public func end() {
        guard isCapturing else { return }
        isCapturing = false
        partials?.cancel()
        partials = nil
        let samples = source.stop()          // first, always: a running engine is a live microphone
        guard !samples.isEmpty else { return }
        transcription = Task { [transcriber, onText] in
            let text = (try? await transcriber.transcribe(samples)) ?? ""
            guard !text.isEmpty else { return }
            await MainActor.run { onText?(text) }
        }
    }

    /// Re-read the words so far, on a cadence, while the hold is open. One at a time: a partial that is
    /// still running is never stacked on by the next tick, or a long hold would queue transcriptions
    /// faster than it finishes them.
    private func startPartials() {
        partials?.cancel()
        guard partialInterval > 0 else { return }
        partials = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.partialInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self, self.isCapturing else { return }
                await self.runPartialOnce()
            }
        }
    }

    /// One re-read of the words so far. The loop above calls this on its cadence; a test calls it
    /// directly, which is why the partial tests assert on behavior instead of on a sleep.
    public func runPartialOnce() async {
        guard isCapturing else { return }
        let samples = source.snapshot()
        guard samples.count > 8_000 else { return }          // half a second of audio to work with
        let text = (try? await transcriber.transcribe(samples)) ?? ""
        guard isCapturing, !text.isEmpty else { return }
        onPartial?(text)
    }

    /// Load the model, downloading it first if that has been allowed. Safe to call repeatedly.
    public func prepareModel() {
        if case .downloading = model { return }
        if case .loading = model { return }
        if model == .ready { return }
        guard let fluid = transcriber as? FluidVoiceTranscriber else { return }
        let allowed = UserDefaults.standard.bool(forKey: Self.downloadAllowedKey)
        guard allowed || FluidVoiceTranscriber.weightsOnDisk else { setModel(.absent); return }

        setModel(FluidVoiceTranscriber.weightsOnDisk ? .loading(0) : .downloading(0))
        Task { [weak self] in
            do {
                try await fluid.prepare(downloadAllowed: allowed) { state in
                    Task { @MainActor in self?.setModel(state) }
                }
            } catch {
                await MainActor.run { self?.setModel(.failed("\(error)")) }
            }
        }
    }

    /// Reflect a model that some other path loaded (a second window, a restart).
    public func refreshModelState() {
        Task { [weak self, modelIsReady] in
            if await modelIsReady() { await MainActor.run { self?.setModel(.ready) } }
        }
    }

    private func setModel(_ state: VoiceModelState) {
        guard state != model else { return }
        model = state
        onModelState?(state)
    }
}
