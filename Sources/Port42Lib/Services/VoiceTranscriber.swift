import Foundation
import FluidAudio

/// Speech to text for hold-to-talk.
///
/// A protocol with one method, so the session can be tested without the Neural Engine and without the
/// network. The real one is `FluidVoiceTranscriber`.
public protocol VoiceTranscriber: Sendable {
    /// 16 kHz mono samples in, text out. An empty string is a valid answer: silence transcribes to
    /// nothing, which is not an error.
    func transcribe(_ samples: [Float]) async throws -> String
}

/// Where the model is. Published on `ShellState` so the indicator can say which of these it is,
/// rather than a hold failing silently.
public enum VoiceModelState: Equatable, Sendable {
    case absent                        // not on disk, and no download has been allowed
    case downloading(Double)           // coming over the network, fraction complete
    case loading(Double)               // on disk, being compiled for the Neural Engine
    case ready
    case failed(String)

    /// What the indicator says. On the type rather than in a view, because two views draw it (the shell
    /// when the words go to the shell's own input, the tile when a port is being dictated into) and both
    /// must say the same thing.
    public var label: String {
        switch self {
        case .ready:                 return "listening"
        case .downloading(let done): return "downloading speech model \(Int(done * 100))%"
        case .loading(let done):     return done > 0 ? "loading speech model \(Int(done * 100))%"
                                                     : "loading speech model"
        case .absent:                return "speech model not installed"
        case .failed(let why):       return "voice: \(why)"
        }
    }

    /// FluidAudio reports one progress stream for three different jobs, and they must not all read as a
    /// download: a person who was told "downloading 50%" while nothing was downloading was told
    /// something untrue (GM, Dev7, 2026-09-26).
    static func from(_ progress: DownloadProgress) -> VoiceModelState {
        switch progress.phase {
        case .listing:     return .downloading(0)
        case .downloading: return .downloading(progress.fractionCompleted)
        case .compiling:   return .loading(progress.fractionCompleted)
        }
    }
}

/// Where the weights are going to come from. Resolved before anything is loaded, so the answer can be
/// tested and so a hold can say which it is.
public enum VoiceModelSource: Equatable, Sendable {
    case bundled       // shipped inside the app
    case cache         // already downloaded on this machine, shared by every instance
    case download      // must be fetched, and that has been allowed
    case unavailable   // not on disk and no download allowed

    public static func resolve(bundled: Bool, cached: Bool, downloadAllowed: Bool) -> VoiceModelSource {
        if bundled { return .bundled }
        if cached { return .cache }
        return downloadAllowed ? .download : .unavailable
    }
}

/// Parakeet TDT v3 on the Neural Engine, via FluidAudio.
///
/// Chosen over WhisperKit because Whisper drops words at its 30 second boundary and the utterances
/// here run to 40. The weights are ~480 MB and are NOT in the app bundle: they are fetched on first
/// use into FluidAudio's shared cache, so every dev instance on this machine uses the one copy.
public actor FluidVoiceTranscriber: VoiceTranscriber {

    private var manager: AsrManager?

    public init() {}

    /// `AsrManager` is itself an actor, so readiness is an await, not a property.
    public func isReady() async -> Bool {
        guard let manager else { return false }
        return await manager.isAvailable
    }

    /// Load the weights, from the app bundle if they shipped with it, from this machine's shared cache
    /// if they were fetched before, and over the network only when that has been allowed. Calling this
    /// when the model is already loaded is a no-op, so a hold can call it freely.
    public func prepare(downloadAllowed: Bool,
                        progress: @escaping @Sendable (VoiceModelState) -> Void) async throws {
        if await isReady() { return }
        let source = VoiceModelSource.resolve(bundled: Self.bundledWeights != nil,
                                              cached: Self.weightsInCache,
                                              downloadAllowed: downloadAllowed)
        let handler: ProgressHandler = { p in progress(VoiceModelState.from(p)) }

        let models: AsrModels
        switch source {
        case .bundled:
            progress(.loading(0))
            models = try await AsrModels.load(from: Self.bundledWeights!, progressHandler: handler)
        case .cache:
            progress(.loading(0))
            models = try await AsrModels.loadFromCache(progressHandler: handler)
        case .download:
            progress(.downloading(0))
            models = try await AsrModels.downloadAndLoad(progressHandler: handler)
        case .unavailable:
            progress(.absent)
            return
        }

        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        progress(.ready)
    }

    /// The weights shipped inside the app, if this build has them. `build.sh` copies them next to the
    /// other resources; a build without them falls back to the cache or a download.
    public static var bundledWeights: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let dir = resources.appendingPathComponent("Models/parakeet-tdt-0.6b-v3", isDirectory: true)
        let encoder = dir.appendingPathComponent("Encoder.mlmodelc")
        return FileManager.default.fileExists(atPath: encoder.path) ? dir : nil
    }

    /// Already downloaded on this machine. FluidAudio's cache is per user, not per app, so every
    /// instance shares the one copy.
    public static var weightsInCache: Bool {
        let encoder = AsrModels.defaultCacheDirectory().appendingPathComponent("Encoder.mlmodelc")
        return FileManager.default.fileExists(atPath: encoder.path)
    }

    /// Kept for callers that only need to know whether a hold can work without the network.
    public static var weightsOnDisk: Bool { bundledWeights != nil || weightsInCache }

    public func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager, await manager.isAvailable else { throw Failure.notLoaded }
        guard !samples.isEmpty else { return "" }
        // A fresh decoder state per utterance: each hold is its own sentence, and carrying state
        // across holds would let one utterance condition the next.
        var decoder = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &decoder)
        return result.text
    }

    public enum Failure: Error, Equatable { case notLoaded }

    public func unload() async {
        await manager?.cleanup()
        manager = nil
    }
}
