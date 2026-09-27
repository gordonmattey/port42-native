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
    case downloading(Double)           // fraction complete
    case ready
    case failed(String)
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

    /// Fetch the weights if they are not on disk, then load them. Reports progress while downloading.
    /// Calling this when the model is already loaded is a no-op, so a hold can call it freely.
    public func prepare(progress: @escaping @Sendable (VoiceModelState) -> Void) async throws {
        if await isReady() { return }
        let models = try await AsrModels.downloadAndLoad(progressHandler: { p in
            progress(.downloading(p.fractionCompleted))
        })
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        progress(.ready)
    }

    /// True when the weights are already on disk, so a first hold can tell "not downloaded yet" from
    /// "downloaded, not loaded".
    public static var weightsOnDisk: Bool {
        FileManager.default.fileExists(atPath: AsrModels.defaultCacheDirectory().path)
    }

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
