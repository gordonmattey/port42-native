import AVFoundation

/// The microphone for hold-to-talk. Starts on the hold, stops on the release, hands back 16 kHz mono
/// samples.
///
/// This does NOT go through `AudioBridge`. That one is shaped around a port that asks and a port that
/// dies: the grant and the teardown hang off the calling port's life. Voice input is the shell
/// capturing for the person at the keyboard, with no port in the picture, so it must not inherit
/// port-ownership teardown.
///
/// The engine is built in `start` and dropped in `stop`, on every path including the failure paths.
/// An engine left running is a live microphone, which is why `stop` cannot throw and why the tests
/// assert on `isRunning` after an error as well as after a normal release.
/// What the session needs from a microphone. A protocol so the session's contract (that the source is
/// always stopped, including when transcription fails) can be tested without a microphone.
public protocol VoiceAudioSource: AnyObject {
    func start() throws
    /// Stop and return 16 kHz mono samples. Cannot throw: an engine left running is a live mic.
    func stop() -> [Float]
    var isRunning: Bool { get }
}

public final class VoiceCapture: VoiceAudioSource, @unchecked Sendable {

    private var engine: AVAudioEngine?
    private var resampler: VoiceResampler?
    private var samples: [Float] = []
    private let lock = NSLock()

    public init() {}

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return engine?.isRunning ?? false
    }

    public enum Failure: Error, Equatable {
        case noInputFormat          // no microphone, or one that reports nothing usable
        case engineFailed(String)
    }

    public func start() throws {
        stopEngine()                                        // never stack two engines on one mic

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let resampler = VoiceResampler(from: format) else {
            throw Failure.noInputFormat
        }

        lock.lock(); samples = []; self.resampler = resampler; lock.unlock()

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            let converted = self.resampler?.samples(from: buffer) ?? []
            self.samples.append(contentsOf: converted)
            self.lock.unlock()
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw Failure.engineFailed(error.localizedDescription)
        }

        lock.lock(); self.engine = engine; lock.unlock()
    }

    /// Stop and hand back what was heard. Returns an empty array when nothing was captured, which is
    /// the ordinary result of a hold that caught no audio, not an error.
    public func stop() -> [Float] {
        stopEngine()
        lock.lock(); defer { lock.unlock() }
        let heard = samples
        samples = []
        resampler = nil
        return heard
    }

    private func stopEngine() {
        lock.lock()
        let engine = self.engine
        self.engine = nil
        lock.unlock()
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Seconds of audio held, at the model's rate.
    public var duration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / VoiceResampler.targetFormat.sampleRate
    }
}
