import AVFoundation

/// Converts whatever the microphone gives us to what the model wants: 16 kHz mono Float32.
///
/// This is a type of its own, and not a closure inside the tap, so the conversion can be tested with a
/// synthetic buffer instead of a microphone. Every failure returns no samples rather than throwing,
/// because a dropped tap buffer must never tear down a capture that is still running.
struct VoiceResampler {

    /// What Parakeet takes: 16 kHz, mono, Float32.
    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 16_000, channels: 1, interleaved: false)!

    /// `AVAudioConverter` writes at most a few thousand frames per `convert` call and DROPS whatever is
    /// left of an input buffer it was handed once, so the input is fed in slices this size and the
    /// output is drained in a loop. Measured: one 16 kHz second handed over whole came back as 4096
    /// samples of 8000.
    private static let sliceFrames: AVAudioFrameCount = 1024

    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let ratio: Double

    init?(from inputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else { return nil }
        self.converter = converter
        self.inputFormat = inputFormat
        self.ratio = Self.targetFormat.sampleRate / inputFormat.sampleRate
    }

    /// One tap buffer in, 16 kHz mono samples out.
    func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0, buffer.format.sampleRate == inputFormat.sampleRate else { return [] }

        var collected: [Float] = []
        collected.reserveCapacity(Int((Double(buffer.frameLength) * ratio).rounded(.up)) + 1)
        var offset: AVAudioFrameCount = 0

        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat,
                                             frameCapacity: Self.sliceFrames * 2) else { break }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, outStatus in
                guard let slice = Self.slice(of: buffer, from: &offset) else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                return slice
            }
            if let channel = out.floatChannelData?[0], out.frameLength > 0 {
                collected.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
            }
            if status == .error || status == .inputRanDry || status == .endOfStream { break }
            if out.frameLength == 0 { break }
        }
        return collected
    }

    /// The next `sliceFrames` of `buffer`, advancing `offset`. Returns nil when the buffer is spent.
    private static func slice(of buffer: AVAudioPCMBuffer,
                             from offset: inout AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard offset < buffer.frameLength, let source = buffer.floatChannelData else { return nil }
        let frames = min(sliceFrames, buffer.frameLength - offset)
        guard let slice = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: frames),
              let destination = slice.floatChannelData else { return nil }

        let channels = Int(buffer.format.channelCount)
        if buffer.format.isInterleaved {
            // One pointer, samples interleaved across channels.
            let stride = channels
            memcpy(destination[0], source[0] + Int(offset) * stride, Int(frames) * stride * 4)
        } else {
            for channel in 0..<channels {
                memcpy(destination[channel], source[channel] + Int(offset), Int(frames) * 4)
            }
        }
        slice.frameLength = frames
        offset += frames
        return slice
    }
}
