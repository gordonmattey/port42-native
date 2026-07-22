import Foundation
import ScreenCaptureKit
import AppKit
import AVFoundation
import CoreMedia

// MARK: - Screen Recorder (screen.record, docs/plan-screen-record.md — Step 1)

/// The `screen.record` session core. Owns an `SCStream` + a manual `RecordingWriter` (AVAssetWriter)
/// per active recording, keyed by a `recordingId`, and writes a real video file with a real audio track
/// (never base64). Targets: `window:self`, `window:id`, `port`, `ports`, `region`, `display`, with
/// video + optional system/mic audio. Recording requires macOS 15; on older systems `start` returns a
/// clear error. (The writer replaced `SCRecordingOutput`, which did not land an audio track.)
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

    /// Whether the cursor can be captured for this target. The cursor is a display-compositor overlay
    /// ScreenCaptureKit renders ONLY on display/region captures — `showsCursor` has no effect under the
    /// window filter (`desktopIndependentWindow`). So `cursor:true` on a window/self/port target is an
    /// invalid parameter combination, rejected at the boundary rather than silently ignored.
    public var supportsCursor: Bool {
        switch self {
        case .display, .region: return true
        case .selfWindow, .window, .port, .ports: return false
        }
    }

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
        // Audio source format: tell the SCStream to actually capture audio at a concrete sample rate /
        // channel count, and keep the app's own audio in (excludesCurrentProcessAudio = false) so a
        // `system` take records the demo's synth output. The RecordingWriter then writes these buffers
        // into a real AAC track.
        if capturesAudio || captureMicrophone {
            c.sampleRate = 48_000
            c.channelCount = 2
            c.excludesCurrentProcessAudio = false
        }
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

    /// One active recording. `writer` is held as AnyObject because `RecordingWriter` is macOS 15-only
    /// and this class is usable at the app's macOS 14 deployment floor; it is cast back inside
    /// `if #available` blocks.
    struct Active {
        let id: String
        let stream: SCStream
        let writer: AnyObject     // RecordingWriter (macOS 15)
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
        // Invalid parameter combo, rejected before any capture: the cursor is a display-compositor
        // overlay ScreenCaptureKit renders only on display/region captures — a window/self/port target
        // cannot include it. Point the caller at the targets that can.
        if (opts["cursor"] as? Bool) == true, !target.supportsCursor {
            return ["error": "screen.record: cursor is only supported on a display or region target — a window/port capture cannot include the cursor. Use target:{display:…} or target:{region:{x,y,w,h}}."]
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

        // Content bbox in the FILTER's coordinate space (window points for self/window/port; display
        // points for region/display). aspect/fit framing crops within it.
        let isRegion: Bool = { if case .region = target { return true }; return false }()
        let contentBBox: CGRect
        if isPortTarget {
            let ids: [String] = { if case .port(let i) = target { return [i] }; if case .ports(let a) = target { return a }; return [] }()
            let rects = ids.compactMap { portFrameLookup?($0) }
            guard let bbox = RecordFraming.unionBBox(rects, padding: paddingOpt(opts)) else {
                return ["error": "screen.record: no resolvable tiles for the given port(s)"]
            }
            contentBBox = bbox
            targetLabel = "ports(\(ids.count))"
        } else if case .region(let r) = target {
            contentBBox = r
        } else {
            contentBBox = CGRect(origin: .zero, size: baseSize)   // full window / display
        }

        // Apply framing when there is cropping to do: an aspect or explicit dims, a port target, or a
        // region (always cropped to its rect). A plain window/display take skips it (full source).
        let hasAspect = (opts["aspect"] as? String) != nil
        let hasExplicitDims = RecordConfig.intOpt(opts["width"]) != nil && RecordConfig.intOpt(opts["height"]) != nil
        if hasAspect || hasExplicitDims || isPortTarget || isRegion {
            let framing: RecordFraming.Result
            do {
                framing = try RecordFraming.resolve(
                    bbox: contentBBox,
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
        }

        let id = UUID().uuidString
        let dir = destinationDir ?? FileManager.default.temporaryDirectory
        let url = outputURL ?? dir.appendingPathComponent("port42-rec-\(id).\(cfg.fileType.rawValue)")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)

        // Manual AVAssetWriter path (not SCRecordingOutput): SCRecordingOutput did not land an audio
        // track, so we feed the stream's own sample buffers into the writer ourselves — video from the
        // `.screen` output, system audio from `.audio`, mic from `.microphone`. This is what actually
        // writes an audio track for `audio:system|mic|both`.
        guard let writer = RecordingWriter(url: url, fileType: cfg.avFileType,
                                           width: outWidth, height: outHeight,
                                           captureAudio: cfg.capturesAudio,
                                           captureMic: cfg.captureMicrophone) else {
            return ["error": "screen.record: could not create the writer at \(url.path)"]
        }
        let stream = SCStream(filter: filter, configuration: scConfig, delegate: nil)
        let sampleQueue = DispatchQueue(label: "port42.screen.record.\(id)")

        do {
            try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: sampleQueue)
            if cfg.capturesAudio {
                try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: sampleQueue)
            }
            if cfg.captureMicrophone {
                try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: sampleQueue)
            }
            guard writer.beginWriting() else {
                return ["error": "screen.record: writer failed to start (\(writer.failureReason))"]
            }
            try await stream.startCapture()
        } catch {
            NSLog("[Port42] screen.record: start failed: %@", error.localizedDescription)
            return ["error": "screen.record start failed: \(error.localizedDescription)"]
        }

        active[id] = Active(id: id, stream: stream, writer: writer,
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

        guard #available(macOS 15, *), let writer = rec.writer as? RecordingWriter else {
            return ["error": "screen.record requires macOS 15 or later"]
        }

        // Stop capture, THEN finalize the writer (mark inputs finished + finishWriting), with a 3s
        // watchdog so we never hang on a stuck finalize.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var resumed = false
            let done: () -> Void = { if !resumed { resumed = true; cont.resume() } }
            Task {
                do { try await rec.stream.stopCapture() }
                catch { NSLog("[Port42] screen.record: stopCapture error: %@", error.localizedDescription) }
                writer.finish { done() }
            }
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                done()
            }
        }

        let seconds = writer.recordedSeconds
        // Bytes from the file on disk (the writer wrote it directly).
        var bytes = 0
        if let sz = (try? FileManager.default.attributesOfItem(atPath: rec.url.path))?[.size] as? Int {
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
            Task {
                try? await rec.stream.stopCapture()
                if #available(macOS 15, *) { (rec.writer as? RecordingWriter)?.finish {} }
            }
        }
    }

    /// Teardown seam: finalize every active recording (app quit / owner teardown). Fire-and-forget
    /// stop; state cleared synchronously so a second call is a no-op.
    public func cleanup() {
        let recs = active
        active.removeAll()
        for (_, rec) in recs {
            Task {
                try? await rec.stream.stopCapture()
                if #available(macOS 15, *) { (rec.writer as? RecordingWriter)?.finish {} }
            }
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

// MARK: - Recording Writer (manual AVAssetWriter)

/// Writes an `SCStream`'s sample buffers to a file with a real audio track. `SCRecordingOutput` did not
/// land an audio track for `audio:system|mic|both`, so we own the writer: video from the `.screen`
/// output, system audio from `.audio`, mic from `.microphone`. One `SCStreamOutput` handles all three
/// (dispatched to `queue`); the session starts on the first COMPLETE video frame so audio that arrives
/// before video can't set the timeline origin wrong. `finish` is idempotent (stop + teardown both call).
@available(macOS 15, *)
final class RecordingWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?     // system audio
    private let micInput: AVAssetWriterInput?       // microphone
    private let queue = DispatchQueue(label: "port42.screen.record.writer")
    private var sessionStarted = false
    private var finished = false
    private var firstPTS: CMTime = .invalid
    private var lastPTS: CMTime = .invalid

    init?(url: URL, fileType: AVFileType, width: Int, height: Int, captureAudio: Bool, captureMic: Bool) {
        guard let w = try? AVAssetWriter(outputURL: url, fileType: fileType) else { return nil }
        writer = w
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        if writer.canAdd(videoInput) { writer.add(videoInput) }

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        if captureAudio {
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            ai.expectsMediaDataInRealTime = true
            if writer.canAdd(ai) { writer.add(ai); audioInput = ai } else { audioInput = nil }
        } else { audioInput = nil }
        if captureMic {
            let mi = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            mi.expectsMediaDataInRealTime = true
            if writer.canAdd(mi) { writer.add(mi); micInput = mi } else { micInput = nil }
        } else { micInput = nil }
        super.init()
    }

    /// Prepare the writer for samples. Must succeed before capture starts.
    func beginWriting() -> Bool { writer.startWriting() }

    var failureReason: String { writer.error?.localizedDescription ?? "status \(writer.status.rawValue)" }

    /// Seconds captured (first → last appended PTS), read after finish.
    var recordedSeconds: Double {
        queue.sync {
            guard firstPTS.isValid, lastPTS.isValid else { return 0 }
            return max(0, CMTimeGetSeconds(CMTimeSubtract(lastPTS, firstPTS)))
        }
    }

    // SCStreamOutput — samples arrive on `queue` (we set it as the handler queue), so hop to it.
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        queue.async { [weak self] in self?.handle(sampleBuffer, type: type) }
    }

    private func handle(_ sb: CMSampleBuffer, type: SCStreamOutputType) {
        guard !finished, CMSampleBufferDataIsReady(sb) else { return }
        // Skip incomplete screen frames (idle/blank) — only .complete frames carry pixels.
        if type == .screen, !Self.isCompleteFrame(sb) { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if !sessionStarted {
            guard type == .screen else { return }   // anchor the timeline to the first video frame
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
            firstPTS = pts
        }
        lastPTS = pts

        switch type {
        case .screen:
            if videoInput.isReadyForMoreMediaData { videoInput.append(sb) }
        case .audio:
            if let ai = audioInput, ai.isReadyForMoreMediaData { ai.append(sb) }
        case .microphone:
            if let mi = micInput, mi.isReadyForMoreMediaData { mi.append(sb) }
        @unknown default:
            break
        }
    }

    /// Finalize: mark inputs finished + finishWriting. Idempotent — a second call just fires completion.
    func finish(_ completion: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self, !self.finished else { completion(); return }
            self.finished = true
            self.videoInput.markAsFinished()
            self.audioInput?.markAsFinished()
            self.micInput?.markAsFinished()
            if self.writer.status == .writing {
                self.writer.finishWriting { completion() }
            } else {
                completion()
            }
        }
    }

    /// A `.screen` sample is a complete (pixel-bearing) frame when its attachment status is `.complete`.
    private static func isCompleteFrame(_ sb: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let first = arr.first,
              let raw = first[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }
}
