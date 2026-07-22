import Foundation
import ScreenCaptureKit
import AppKit
import AVFoundation
import CoreMedia

// MARK: - Screen Recorder (screen.record, docs/plan-screen-record.md — Step 1)

/// The `screen.record` session core. Owns an `SCStream` + `SCRecordingOutput` per active recording,
/// keyed by a `recordingId`, and writes a real video file (never base64). Step 1 targets `window:self`
/// with video + optional system audio; richer targets (`window:id`, `port`, `ports`, `region`,
/// `display`) and the framing math land in later steps. Recording requires macOS 15 (SCRecordingOutput);
/// on older systems `start` returns a clear error.
///
/// Teardown seam from day one: `cleanup()` finalizes every active recording. Owner-port tracking +
/// `releaseIfOwned` (so an owning port's death finalizes its recording) is wired in the teardown step,
/// the same seam the 0.5 mic-leak work established.

/// What to frame. Step 1 supports `.selfWindow`; the rest are stubs filled in by later steps.
public enum RecordTarget: Equatable {
    case selfWindow
    // Step 2/4: case window(UInt32), port(String), ports([String]), region(CGRect), display(UInt32)
}

/// The pure options→config derivation (no ScreenCaptureKit in the computation, so it is
/// headless-unit-testable). `makeSCStreamConfiguration()` maps it onto a real SCStreamConfiguration.
public struct RecordConfig: Equatable {
    public enum FileType: String { case mov, mp4 }

    public var width: Int          // output px
    public var height: Int         // output px
    public var fps: Int
    public var showsCursor: Bool
    public var capturesAudio: Bool
    public var captureMicrophone: Bool
    public var fileType: FileType

    /// Derive from a source size (in POINTS) + the options dict. `displayScale` is passed in rather
    /// than read from NSScreen so the derivation stays pure. Rule: an explicit `width`/`height` wins;
    /// otherwise output = source × `scale` (default `displayScale`) — this is what makes a take land at
    /// the requested size instead of always at the backing scale.
    public static func from(sourceSize: CGSize, displayScale: Double, opts: [String: Any]) -> RecordConfig {
        let scale = numOpt(opts["scale"]) ?? displayScale
        let explicitW = intOpt(opts["width"])
        let explicitH = intOpt(opts["height"])
        let width = explicitW ?? max(1, Int((sourceSize.width * scale).rounded()))
        let height = explicitH ?? max(1, Int((sourceSize.height * scale).rounded()))
        let fps = max(1, intOpt(opts["fps"]) ?? 30)
        let cursor = (opts["cursor"] as? Bool) ?? false
        let audio = (opts["audio"] as? String) ?? "none"
        let capturesAudio = (audio == "system" || audio == "both")
        let captureMic = (audio == "mic" || audio == "both")
        let fileType = FileType(rawValue: (opts["format"] as? String) ?? "mov") ?? .mov
        return RecordConfig(width: width, height: height, fps: fps, showsCursor: cursor,
                            capturesAudio: capturesAudio, captureMicrophone: captureMic, fileType: fileType)
    }

    public var avFileType: AVFileType { fileType == .mp4 ? .mp4 : .mov }

    @available(macOS 15, *)
    func makeSCStreamConfiguration() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = width
        c.height = height
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = showsCursor
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        c.capturesAudio = capturesAudio
        c.captureMicrophone = captureMicrophone
        c.backgroundColor = .clear   // window-only capture: transparent outside the window surface
        return c
    }

    // JSON numbers arrive as Int, Double, or NSNumber depending on the surface.
    static func intOpt(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }
    static func numOpt(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }
}

@MainActor
public final class ScreenRecorder {

    /// One active recording. `output`/`delegate` are held as AnyObject because their types
    /// (SCRecordingOutput / the delegate) are macOS 15-only and this class is usable at the app's
    /// macOS 14 deployment floor; they are cast back inside `if #available` blocks.
    struct Active {
        let id: String
        let stream: SCStream
        let output: AnyObject
        let delegate: AnyObject
        let url: URL
        let width: Int
        let height: Int
        let fps: Int
    }

    private var active: [String: Active] = [:]

    public init() {}

    public var isRecording: Bool { !active.isEmpty }

    /// Start a recording. Returns `{recordingId, width, height, target}` or `{error}`.
    /// Step 1: only `.selfWindow`; `destinationDir` defaults to the temp dir (the space-cwd/fallback
    /// destination lands with the bridge methods).
    public func start(target: RecordTarget, opts: [String: Any], destinationDir: URL? = nil) async -> [String: Any] {
        guard #available(macOS 15, *) else {
            return ["error": "screen.record requires macOS 15 or later"]
        }
        guard target == .selfWindow else {
            return ["error": "screen.record: only window:self is supported at this step"]
        }
        guard let window = await resolveSelfWindow() else {
            return ["error": "screen.record: could not resolve the Port42 window"]
        }

        let displayScale = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        let cfg = RecordConfig.from(sourceSize: window.frame.size, displayScale: displayScale, opts: opts)
        let id = UUID().uuidString
        let dir = destinationDir ?? FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("port42-rec-\(id).\(cfg.fileType.rawValue)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scConfig = cfg.makeSCStreamConfiguration()

        let recConfig = SCRecordingOutputConfiguration()
        recConfig.outputURL = url
        recConfig.outputFileType = cfg.avFileType
        let delegate = RecordingOutputDelegate()
        let output = SCRecordingOutput(configuration: recConfig, delegate: delegate)
        let stream = SCStream(filter: filter, configuration: scConfig, delegate: nil)

        do {
            try stream.addRecordingOutput(output)
            try await stream.startCapture()
        } catch {
            NSLog("[Port42] screen.record: start failed: %@", error.localizedDescription)
            return ["error": "screen.record start failed: \(error.localizedDescription)"]
        }

        active[id] = Active(id: id, stream: stream, output: output, delegate: delegate,
                            url: url, width: cfg.width, height: cfg.height, fps: cfg.fps)
        NSLog("[Port42] screen.record: started %@ %dx%d @ %d fps audio=%d → %@",
              id, cfg.width, cfg.height, cfg.fps, cfg.capturesAudio ? 1 : 0, url.lastPathComponent)
        return ["recordingId": id, "width": cfg.width, "height": cfg.height, "target": "self"]
    }

    /// Stop + finalize a recording. Returns `{path, width, height, seconds, fps, bytes}` or `{error}`.
    public func stop(recordingId: String) async -> [String: Any] {
        guard let rec = active[recordingId] else {
            return ["error": "screen.record: no active recording \(recordingId)"]
        }
        active[recordingId] = nil

        guard #available(macOS 15, *),
              let output = rec.output as? SCRecordingOutput,
              let delegate = rec.delegate as? RecordingOutputDelegate else {
            return ["error": "screen.record requires macOS 15 or later"]
        }

        // Stop, then await finalize (delegate) with a 3s watchdog so we never hang.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var resumed = false
            let done: () -> Void = { if !resumed { resumed = true; cont.resume() } }
            delegate.onFinish = { _ in done() }
            Task {
                do { try await rec.stream.stopCapture() }
                catch { NSLog("[Port42] screen.record: stopCapture error: %@", error.localizedDescription) }
            }
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                done()
            }
        }

        let seconds = CMTimeGetSeconds(output.recordedDuration)
        let bytes = output.recordedFileSize
        NSLog("[Port42] screen.record: stopped %@ %.2fs %ld bytes", recordingId, seconds, bytes)
        return [
            "path": rec.url.path,
            "width": rec.width,
            "height": rec.height,
            "seconds": seconds,
            "fps": rec.fps,
            "bytes": bytes
        ]
    }

    /// Teardown seam: finalize every active recording (app quit / owner teardown). Fire-and-forget
    /// stop; state cleared synchronously so a second call is a no-op.
    public func cleanup() {
        let recs = active
        active.removeAll()
        for (_, rec) in recs {
            Task { try? await rec.stream.stopCapture() }
        }
    }

    // MARK: - Self-window resolution

    /// Port42's own frontmost/largest on-screen window (the `window:self` target).
    private func resolveSelfWindow() async -> SCWindow? {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            NSLog("[Port42] screen.record: shareable content failed: %@", error.localizedDescription)
            return nil
        }
        let mine = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
                && $0.frame.width > 200 && $0.frame.height > 200
        }
        return mine.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    }
}

// MARK: - Recording Output Delegate

/// Mandatory SCRecordingOutput delegate. Resumes `onFinish` once the file is finalized (or fails), so
/// a stop() reads a closed file rather than a still-writing one.
@available(macOS 15, *)
final class RecordingOutputDelegate: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    var onFinish: ((Error?) -> Void)?
    private var fired = false
    private func fire(_ err: Error?) { if !fired { fired = true; onFinish?(err) } }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        NSLog("[Port42] screen.record: recording failed: %@", error.localizedDescription)
        fire(error)
    }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        fire(nil)
    }
}
