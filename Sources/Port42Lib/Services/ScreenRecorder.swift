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

/// What to frame. `.selfWindow`/`.port`/`.ports` land on the self-window filter (occlusion-proof);
/// `.port`/`.ports` add a `sourceRect` = the union of the ports' tile rects + padding. `window:id`,
/// `region`, and `display` targets are Step 4.
public enum RecordTarget: Equatable {
    case selfWindow
    case port(String)
    case ports([String])
    case window(UInt32)      // an OS window by id (occlusion-proof, like window:self)
    case region(CGRect)      // an explicit display rect (screen coords; NOT occlusion-proof)
    case display(UInt32)     // a whole display (NOT occlusion-proof)

    /// A legible refusal from `parse` (an unsupported target shape).
    public struct ParseError: Error, Equatable { public let message: String }

    /// Parse the `target` option shape: `{window:"self"}` / `{window:<id>}`, `{port:<udid>}`,
    /// `{ports:[<udid>...]}`, `{region:{x,y,w,h}}`, `{display:<id>}`, and a missing target (= self).
    public static func parse(_ opts: [String: Any]) -> Result<RecordTarget, ParseError> {
        guard let target = opts["target"] as? [String: Any] else { return .success(.selfWindow) }
        if let win = target["window"] {
            if let s = win as? String, s == "self" { return .success(.selfWindow) }
            if let id = RecordConfig.intOpt(win), id >= 0 { return .success(.window(UInt32(id))) }
            return .failure(ParseError(message: "screen.record: window target must be \"self\" or a numeric window id"))
        }
        if let port = target["port"] as? String { return .success(.port(port)) }
        if let ports = target["ports"] as? [Any] {
            let ids = ports.compactMap { $0 as? String }
            guard !ids.isEmpty else { return .failure(ParseError(message: "screen.record: ports target had no valid port ids")) }
            return .success(.ports(ids))
        }
        if let region = target["region"] as? [String: Any] {
            let x = RecordConfig.numOpt(region["x"]) ?? 0
            let y = RecordConfig.numOpt(region["y"]) ?? 0
            let w = RecordConfig.numOpt(region["w"]) ?? RecordConfig.numOpt(region["width"]) ?? 0
            let h = RecordConfig.numOpt(region["h"]) ?? RecordConfig.numOpt(region["height"]) ?? 0
            guard w > 0, h > 0 else { return .failure(ParseError(message: "screen.record: region needs positive w and h")) }
            return .success(.region(CGRect(x: x, y: y, width: w, height: h)))
        }
        if let disp = target["display"] {
            // screen.displays exposes no display ids yet, so a non-numeric/true value = the main display.
            if let id = RecordConfig.intOpt(disp), id >= 0 { return .success(.display(UInt32(id))) }
            return .success(.display(0))   // resolves to the first/main display in start()
        }
        return .success(.selfWindow)
    }
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
        let startedAt: Date
        /// The port that started this recording (Principal.portId), or nil for a non-port caller
        /// (the gateway). Its death finalizes the recording — the 0.5 "nothing leaks" seam.
        let ownerPortId: String?
    }

    private var active: [String: Active] = [:]

    public init() {}

    public var isRecording: Bool { !active.isEmpty }

    /// Status of a recording (or of the recorder overall when `recordingId` is nil).
    public func status(recordingId: String?) -> [String: Any] {
        if let id = recordingId {
            guard let rec = active[id] else { return ["recording": false, "elapsed": 0.0] }
            return ["recording": true, "elapsed": Date().timeIntervalSince(rec.startedAt), "recordingId": id]
        }
        guard let any = active.values.first else { return ["recording": false, "elapsed": 0.0, "count": 0] }
        return ["recording": true, "elapsed": Date().timeIntervalSince(any.startedAt),
                "recordingId": any.id, "count": active.count]
    }

    /// Start a recording. Returns `{recordingId, width, height, target}` or `{error}`.
    /// `.selfWindow`/`.port`/`.ports` land on the self-window filter; `.port`/`.ports` crop to the
    /// union of their tile rects via `portFrameLookup` (window-relative points, Spike C space).
    /// `destinationDir` defaults to the temp dir (the space-cwd/fallback destination lands with the
    /// bridge methods).
    public func start(target: RecordTarget, opts: [String: Any],
                      destinationDir: URL? = nil,
                      outputURL: URL? = nil,
                      ownerPortId: String? = nil,
                      portFrameLookup: ((String) -> CGRect?)? = nil) async -> [String: Any] {
        guard #available(macOS 15, *) else {
            return ["error": "screen.record requires macOS 15 or later"]
        }
        // Resolve the target → capture filter + base size (points) + label, from ONE content fetch.
        // self/port/ports/window:id use the occlusion-proof window filter; region/display use the
        // display filter (NOT occlusion-proof — a raw display grab that can catch other apps).
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            return ["error": "screen.record: could not read shareable content: \(error.localizedDescription)"]
        }

        let filter: SCContentFilter
        let baseSize: CGSize
        var targetLabel: String
        var isPortTarget = false
        switch target {
        case .selfWindow, .port, .ports:
            guard let win = selfWindow(in: content) else {
                return ["error": "screen.record: could not resolve the Port42 window"]
            }
            filter = SCContentFilter(desktopIndependentWindow: win)
            baseSize = win.frame.size
            targetLabel = "self"
            if case .selfWindow = target {} else { isPortTarget = true }
        case .window(let wid):
            guard let win = content.windows.first(where: { $0.windowID == wid }) else {
                return ["error": "screen.record: window \(wid) not found"]
            }
            filter = SCContentFilter(desktopIndependentWindow: win)
            baseSize = win.frame.size
            targetLabel = "window(\(wid))"
        case .display(let did):
            guard let disp = content.displays.first(where: { $0.displayID == did }) ?? content.displays.first else {
                return ["error": "screen.record: no display available"]
            }
            filter = SCContentFilter(display: disp, excludingApplications: [], exceptingWindows: [])
            baseSize = CGSize(width: disp.width, height: disp.height)
            targetLabel = "display(\(disp.displayID))"
        case .region(let r):
            guard let disp = content.displays.first else {
                return ["error": "screen.record: no display available"]
            }
            filter = SCContentFilter(display: disp, excludingApplications: [], exceptingWindows: [])
            baseSize = r.size
            targetLabel = "region"
        }

        let displayScale = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        let cfg = RecordConfig.from(sourceSize: baseSize, displayScale: displayScale, opts: opts)
        let scConfig = cfg.makeSCStreamConfiguration()
        var outWidth = cfg.width
        var outHeight = cfg.height

        // region: crop the display filter to the requested rect (screen points, top-left origin).
        if case .region(let r) = target { scConfig.sourceRect = r }

        // port/ports: crop the self-window filter to the union bbox + framing.
        if isPortTarget {
            let ids: [String] = { if case .port(let i) = target { return [i] }; if case .ports(let a) = target { return a }; return [] }()
            let rects = ids.compactMap { portFrameLookup?($0) }
            guard let bbox = RecordFraming.unionBBox(rects, padding: paddingOpt(opts)) else {
                return ["error": "screen.record: no resolvable tiles for the given port(s)"]
            }
            let framing: RecordFraming.Result
            do {
                framing = try RecordFraming.resolve(
                    bbox: bbox,
                    aspect: opts["aspect"] as? String,
                    fit: RecordFit(rawValue: (opts["fit"] as? String) ?? "contain") ?? .contain,
                    width: RecordConfig.intOpt(opts["width"]),
                    height: RecordConfig.intOpt(opts["height"]),
                    scale: (RecordConfig.numOpt(opts["scale"]) ?? displayScale))
            } catch RecordFramingError.containNotSupported {
                return ["error": "screen.record: fit:contain (letterbox) is not yet supported; pass fit:cover or fit:exact, or omit aspect"]
            } catch {
                return ["error": "screen.record: framing failed: \(error.localizedDescription)"]
            }
            scConfig.sourceRect = framing.sourceRect
            scConfig.width = framing.width
            scConfig.height = framing.height
            outWidth = framing.width
            outHeight = framing.height
            targetLabel = "ports(\(ids.count))"
        }

        let id = UUID().uuidString
        let dir = destinationDir ?? FileManager.default.temporaryDirectory
        let url = outputURL ?? dir.appendingPathComponent("port42-rec-\(id).\(cfg.fileType.rawValue)")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)

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
                            url: url, width: outWidth, height: outHeight, fps: cfg.fps,
                            startedAt: Date(), ownerPortId: ownerPortId)
        NSLog("[Port42] screen.record: started %@ %dx%d @ %d fps audio=%d target=%@ → %@",
              id, outWidth, outHeight, cfg.fps, cfg.capturesAudio ? 1 : 0, targetLabel, url.lastPathComponent)
        return ["recordingId": id, "width": outWidth, "height": outHeight, "target": targetLabel]
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
        // recordedFileSize can read 0 after finalize for some sources; fall back to the file on disk.
        var bytes = output.recordedFileSize
        if bytes <= 0, let sz = (try? FileManager.default.attributesOfItem(atPath: rec.url.path))?[.size] as? Int {
            bytes = sz
        }
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

    /// Finalize every recording started by the given port (the 0.5 teardown seam, keyed on the stable
    /// port id). A no-op for a port that owns nothing here, so it is safe from both the close path and
    /// the deinit backstop. Fire-and-forget stop: the captured `rec` keeps the stream + delegate alive
    /// until finalize completes, so the file is written and no stream is orphaned.
    public func releaseIfOwned(byPortId id: String) {
        let owned = active.filter { $0.value.ownerPortId == id }
        for (rid, rec) in owned {
            active[rid] = nil
            NSLog("[Port42] screen.record: finalizing %@ on owner %@ teardown", rid, id)
            Task { try? await rec.stream.stopCapture() }
        }
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

    private func paddingOpt(_ opts: [String: Any]) -> CGFloat {
        if let d = RecordConfig.numOpt(opts["padding"]) { return CGFloat(max(0, d)) }
        return 24
    }

    // MARK: - Self-window resolution

    /// Port42's own frontmost/largest on-screen window (the `window:self` target), from shareable content.
    private func selfWindow(in content: SCShareableContent) -> SCWindow? {
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
