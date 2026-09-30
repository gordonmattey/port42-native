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
    /// Injected so the permission behavior is testable without touching the real TCC state.
    private let micGranted: @Sendable () -> Bool
    private let askForPermissions: @Sendable () -> Void

    /// Called with the text of a finished hold. Empty text (silence) is not reported.
    public var onText: ((String) -> Void)?
    /// Called while the hold is still open, with the words so far. Feedback only: nothing is inserted
    /// until the release, so trailing off mid-sentence leaves nothing to un-type.
    public var onPartial: ((String) -> Void)?
    /// Called when the model's state changes, so the indicator can show it.
    public var onModelState: ((VoiceModelState) -> Void)?
    /// Called when a hold cannot run because the system has not granted something yet, so the indicator can
    /// say which. Nil means nothing is outstanding.
    public var onPermissionNeeded: ((VoicePermission?) -> Void)?

    /// Where this hold's words are going. Set by whoever starts the hold: the shell for its own surfaces, the
    /// event tap for another app, which cannot be composed into and has to be typed.
    public enum Destination: Equatable, Sendable { case inApp, otherApp }
    public var destination: Destination = .inApp

    public private(set) var model: VoiceModelState = .absent
    public private(set) var isCapturing = false
    /// The transcription started by the last release. Exposed so a test can await delivery instead of
    /// sleeping: a sleep long enough for a loaded machine is a slow suite, and a short one is a flake.
    public private(set) var transcription: Task<Void, Never>?

    /// A hold that landed before the model finished loading. Its audio is kept and read as soon as the model
    /// is ready: the first hold after a launch is the one a person judges the feature by, and dropping it
    /// taught them the feature does not work.
    private var pending: [Float] = []
    private var askedForPermissions = false

    /// How often the words so far are re-read while the hold is open. The whole buffer is transcribed
    /// each time rather than a sliding window, which needs no second model and gives the same text the
    /// release will give. The cost grows with the hold: measured on an M-series Mac, 10 seconds of audio
    /// reads in about 0.6 s, 45 seconds in 1.5 s, two minutes in 4.3 s (`VoiceLongHoldBench`).
    /// Half a second, so dictated words land close behind the voice (GM, 2026-09-29: at a second they
    /// arrived in chunks). This is the floor: see `partialGap` for a long hold.
    public var partialInterval: TimeInterval = 0.5
    private var partials: Task<Void, Never>?
    /// Counts holds, so a re-read that finishes after its hold ended cannot land in the next one.
    private var holdNumber = 0
    /// Whether the last hold ended at `VoiceTrigger.maximumHold` rather than by a release. Its words are
    /// typed but not sent: the person was cut off mid-sentence.
    public private(set) var endedAtLimit = false

    /// The wait before the next re-read, given how long the last one took. The whole buffer is re-read,
    /// so the cost grows with the hold; at a fixed half second a long hold would keep the model busy
    /// without pause, and the release's final read (and the next hold) would wait behind it. Waiting
    /// twice the last read's time keeps the model idle at least two thirds of the time.
    nonisolated public static func partialGap(interval: TimeInterval, lastRead: TimeInterval) -> TimeInterval {
        max(interval, lastRead * 2)
    }

    /// Whether the weights may be fetched. ON by default, because the app does not ship them: holding space
    /// IS the consent, and the indicator shows the download as it runs rather than stalling in silence.
    /// Setting `voiceModelDownloadAllowed` to false turns voice off on a machine that must not fetch it.
    public static let downloadAllowedKey = "voiceModelDownloadAllowed"

    /// The default when nothing has been set, so a shipped app can dictate and a locked-down one can refuse.
    nonisolated public static var downloadAllowedByDefault: Bool { true }

    nonisolated static func downloadAllowed(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: downloadAllowedKey) as? Bool ?? downloadAllowedByDefault
    }

    /// Whether this call may fetch 461 MB. Launch may not: the app loads weights that are already there and
    /// otherwise waits, because nobody has asked for dictation yet. A hold may, and so may the Download button
    /// in Settings: both are the person asking.
    nonisolated static func shouldDownload(askedByPerson: Bool, weightsOnDisk: Bool, allowed: Bool) -> Bool {
        guard !weightsOnDisk else { return false }
        return askedByPerson && allowed
    }

    public init(source: VoiceAudioSource,
                transcriber: VoiceTranscriber,
                modelIsReady: @escaping @Sendable () async -> Bool,
                model: VoiceModelState = .absent,
                micGranted: @escaping @Sendable () -> Bool = { VoicePermissions.microphoneGranted() },
                askForPermissions: @escaping @Sendable () -> Void = VoiceSession.askSystem) {
        self.source = source
        self.transcriber = transcriber
        self.modelIsReady = modelIsReady
        self.model = model
        self.micGranted = micGranted
        self.askForPermissions = askForPermissions
    }

    /// Ask for the microphone and for accessibility at the same moment, so the person answers once instead of
    /// being interrupted twice at two unrelated times.
    @Sendable
    public static func askSystem() {
        Task { @MainActor in
            _ = await VoicePermissions.requestMicrophone()
            if !VoicePermissions.accessibilityGranted() { VoicePermissions.promptAccessibility() }
        }
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

        // The system permissions are asked for HERE, on the first hold, and both at once. Before that
        // nothing has touched the microphone, so nothing has prompted.
        guard micGranted() else {
            if !askedForPermissions {
                askedForPermissions = true
                askForPermissions()
            }
            onPermissionNeeded?(.microphone)
            return
        }
        onPermissionNeeded?(nil)

        // A hold is allowed to run while the model is still loading: the audio is kept and read when the
        // model lands. Only a model that is absent or failed stops it.
        switch model {
        case .ready, .loading, .downloading: break
        case .absent, .failed: prepareModel(askedByPerson: true); return
        }

        do {
            try source.start()
            isCapturing = true
            holdNumber += 1
            endedAtLimit = false
            startPartials()
        } catch {
            setModel(.failed("microphone: \(error)"))
        }
    }

    /// The hold is over: stop the microphone and read what was said. `atLimit` is a hold that ran to
    /// `VoiceTrigger.maximumHold`; its words are kept all the same.
    public func end(atLimit: Bool = false) {
        guard isCapturing else { return }
        isCapturing = false
        endedAtLimit = atLimit
        partials?.cancel()
        partials = nil
        let samples = source.stop()          // first, always: a running engine is a live microphone
        guard !samples.isEmpty else { return }
        guard model == .ready else {
            pending = samples                // the model is still loading; read it the moment it is ready
            return
        }
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
            var lastRead: TimeInterval = 0
            while !Task.isCancelled {
                guard let interval = self?.partialInterval else { return }
                try? await Task.sleep(for: .seconds(Self.partialGap(interval: interval, lastRead: lastRead)))
                guard !Task.isCancelled, let self, self.isCapturing else { return }
                let started = Date()
                await self.runPartialOnce()
                lastRead = Date().timeIntervalSince(started)
            }
        }
    }

    /// One re-read of the words so far. The loop above calls this on its cadence; a test calls it
    /// directly, which is why the partial tests assert on behavior instead of on a sleep.
    public func runPartialOnce() async {
        guard isCapturing else { return }
        let hold = holdNumber
        let samples = source.snapshot()
        guard samples.count > 8_000 else { return }          // half a second of audio to work with
        let text = (try? await transcriber.transcribe(samples)) ?? ""
        // Still this hold: a re-read of a hold that has ended, or been replaced by the next, says nothing.
        guard isCapturing, hold == holdNumber, !text.isEmpty else { return }
        onPartial?(text)
    }

    /// Load the model. At launch this only loads weights that are already on disk; a hold, or the Download
    /// button in Settings, is what may fetch them, because the app does not ship them.
    public func prepareModel(askedByPerson: Bool = false) {
        if case .downloading = model { return }
        if case .loading = model { return }
        if model == .ready { return }
        guard let fluid = transcriber as? FluidVoiceTranscriber else { return }
        let onDisk = FluidVoiceTranscriber.weightsOnDisk
        let allowed = Self.shouldDownload(askedByPerson: askedByPerson, weightsOnDisk: onDisk,
                                          allowed: Self.downloadAllowed())
        guard allowed || onDisk else { setModel(.absent); return }

        setModel(onDisk ? .loading(0) : .downloading(0))
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

    /// Report a model state from outside, for whoever is doing the loading. Reaching `.ready` this way also
    /// reads any audio a hold left behind while the model was still loading.
    public func noteModelState(_ state: VoiceModelState) { setModel(state) }

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
        if state == .ready { readPending() }
    }

    /// Stop capturing and throw the audio away. For a hold that was abandoned rather than released: nothing is
    /// transcribed and nothing is inserted.
    public func abandon() {
        partials?.cancel(); partials = nil
        guard isCapturing else { return }
        isCapturing = false
        _ = source.stop()
        pending = []
    }

    /// Read the audio a hold left behind while the model was loading.
    private func readPending() {
        guard !pending.isEmpty else { return }
        let samples = pending
        pending = []
        transcription = Task { [transcriber, onText] in
            let text = (try? await transcriber.transcribe(samples)) ?? ""
            guard !text.isEmpty else { return }
            await MainActor.run { onText?(text) }
        }
    }
}
