//  ScreenRecordSpike.swift
//
//  Step 0 de-risking spikes for `screen.record` (docs/plan-screen-record.md §"De-risking spikes").
//  THROWAWAY code — delete after Step 0; the findings are the deliverable. Three unknowns carry the
//  risk, each retired by inspecting an output .mov:
//
//    A (gating)     — record the self-window with SYSTEM AUDIO to a file. Proves SCRecordingOutput +
//                     capturesAudio co-operate (video track AND non-silent audio track in one file).
//                     A looping NSSound plays during the take so system audio has signal.
//    B (risk-namer) — record the self-window with the cursor on; during the take the human covers
//                     Port42 with another app and moves the mouse. Confirms occlusion-proofness (no
//                     other app leaks in, no black) and NAMES whether the 2.4 pointer glitch rides
//                     this SCStream path or the window filter sidesteps it.
//    C (gating)     — record the self-window cropped via sourceRect to a distinctive INNER rect
//                     (hypothesis: window-relative, points). Resolves the coordinate space the
//                     union-bbox framing math depends on.
//
//  Each mode writes /tmp/screenrec-<mode>.mov and appends a verdict to /tmp/screenrec-spike.log,
//  auto-checking the output with AVURLAsset (video track? audio track? duration? bytes?). A/C run
//  hands-free via the one-shot PORT42_RECSPIKE_A/C_AUTORUN defaults flags; B needs a human at the
//  machine. Also on the Debug menu.
//
//  Gate: proceed to Step 1 only if A and C pass.

#if DEBUG
import Foundation
import ScreenCaptureKit
import AppKit
import AVFoundation
import CoreMedia

enum RecSpikeLog {
    static func p(_ s: String) {
        NSLog("[Port42][recspike] %@", s)
        let url = URL(fileURLWithPath: "/tmp/screenrec-spike.log")
        let line = "\(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
    }
}

/// Mandatory delegate for SCRecordingOutput. Resumes `onFinish` once the file is finalized (or fails),
/// so the AVAsset check reads a closed file rather than a still-writing one.
@available(macOS 15, *)
final class RecSpikeOutputDelegate: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    var onFinish: ((Error?) -> Void)?
    private var fired = false
    private func fire(_ err: Error?) { if !fired { fired = true; onFinish?(err) } }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        RecSpikeLog.p("delegate: recording started")
    }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        RecSpikeLog.p("delegate: FAILED — \(error.localizedDescription)")
        fire(error)
    }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        RecSpikeLog.p("delegate: finished, size=\(recordingOutput.recordedFileSize) bytes duration=\(CMTimeGetSeconds(recordingOutput.recordedDuration))s")
        fire(nil)
    }
}

@MainActor
public final class ScreenRecordSpikeHarness {
    public static let shared = ScreenRecordSpikeHarness()

    public enum Mode: String { case a, b, c, d, e }

    private let seconds: Double = 5.0

    public func run(_ mode: Mode) {
        if mode == .d { Task { await self.recordPortsLive() }; return }
        if mode == .e { Task { await self.recordTeardownLive() }; return }
        Task { await self.record(mode) }
    }

    // MARK: - Mode E: owner-port teardown finalizes the recording (Step 5 live test)

    /// Start a recording OWNED by a port on the SHARED recorder, then close the port and confirm the
    /// file finalizes (valid, non-zero duration) with no orphaned stream — the 0.5 "nothing leaks" seam.
    private func recordTeardownLive() async {
        RecSpikeLog.p("=== SPIKE E (owner teardown) start ===")
        guard #available(macOS 15, *) else { RecSpikeLog.p("E: requires macOS 15"); return }
        var ready: (AppState, String)?
        for _ in 0..<40 {
            if let shell = ShellState.debugCurrent, let app = shell.debugAppState, let sid = app.currentSpace?.id {
                ready = (app, sid); break
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard let (app, sid) = ready else { RecSpikeLog.p("E: no shell/app/space after 20s"); return }

        let idE = "recspike-port-E"
        _ = app.portWindows.registerTiledPort(id: idE, html: Self.coloredHTML(label: "PORT E", hue: 40),
            spaceId: sid, createdBy: "recspike", title: "E",
            position: CGPoint(x: 300, y: 200), size: CGSize(width: 420, height: 300))
        try? await Task.sleep(nanoseconds: 800_000_000)

        let url = URL(fileURLWithPath: "/tmp/screenrec-e.mov")
        try? FileManager.default.removeItem(at: url)
        // 30s target so the recording is still live when we kill the port mid-take.
        let start = await app.screenDevice.recorder.start(
            target: .selfWindow, opts: ["audio": "none", "scale": 1.0],
            outputURL: url, ownerPortId: idE)
        RecSpikeLog.p("E: start (owner=\(idE)) → \(start)  isRecording=\(app.screenDevice.recorder.isRecording)")
        try? await Task.sleep(nanoseconds: 1_500_000_000)   // record ~1.5s, then kill the owner

        RecSpikeLog.p("E: closing port \(idE) mid-record (triggers releaseAcquisitions → recorder teardown)")
        app.portWindows.close(idE)
        try? await Task.sleep(nanoseconds: 1_500_000_000)   // let the finalize complete

        RecSpikeLog.p("E: after teardown isRecording=\(app.screenDevice.recorder.isRecording)")
        await checkOutput(url: url, label: "E")
        RecSpikeLog.p("E: PASS iff isRecording=false AND E file has a video track with duration>0")
        RecSpikeLog.p("=== SPIKE E done ===")
    }

    // MARK: - Mode D: ports framing (Step 2 live test)

    /// Open two known-position web ports, record their union bbox at 16:9/cover via the REAL
    /// ScreenRecorder, and log the framing + output path. Verifies the desktop→window coordinate
    /// space (portFrame == sourceRect space) and the union-bbox math end to end.
    private func recordPortsLive() async {
        RecSpikeLog.p("=== SPIKE D (ports framing) start ===")
        guard #available(macOS 15, *) else { RecSpikeLog.p("D: requires macOS 15"); return }
        // Wait (up to ~20s) for the shell to restore to a space — the autorun may fire before it lands.
        var ready: (ShellState, AppState, String)?
        for _ in 0..<40 {
            if let shell = ShellState.debugCurrent, let app = shell.debugAppState, let sid = app.currentSpace?.id {
                ready = (shell, app, sid); break
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard let (_, app, sid) = ready else {
            RecSpikeLog.p("D: no shell/app/space after 20s — zoom into a space, then run Spike D from the Debug menu"); return
        }
        let idA = "recspike-port-A", idB = "recspike-port-B"
        _ = app.portWindows.registerTiledPort(id: idA, html: Self.coloredHTML(label: "PORT A", hue: 320),
            spaceId: sid, createdBy: "recspike", title: "A",
            position: CGPoint(x: 200, y: 160), size: CGSize(width: 420, height: 300))
        _ = app.portWindows.registerTiledPort(id: idB, html: Self.coloredHTML(label: "PORT B", hue: 160),
            spaceId: sid, createdBy: "recspike", title: "B",
            position: CGPoint(x: 760, y: 210), size: CGSize(width: 420, height: 300))
        try? await Task.sleep(nanoseconds: 1_800_000_000)   // let both tiles mount + render

        for id in [idA, idB] {
            RecSpikeLog.p("D: \(id) portFrame=\(String(describing: app.portWindows.portFrame(by: id)))")
        }

        let recorder = ScreenRecorder()
        let lookup: (String) -> CGRect? = { app.portWindows.portFrame(by: $0) }
        let start = await recorder.start(
            target: .ports([idA, idB]),
            opts: ["padding": 32, "aspect": "16:9", "fit": "cover", "scale": 1.0, "cursor": false],
            portFrameLookup: lookup)
        RecSpikeLog.p("D: start → \(start)")
        guard let rid = start["recordingId"] as? String else {
            RecSpikeLog.p("D: no recordingId; abort")
            app.portWindows.close(idA); app.portWindows.close(idB); return
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        let res = await recorder.stop(recordingId: rid)
        RecSpikeLog.p("D: stop → \(res)")
        if let path = res["path"] as? String { await checkOutput(url: URL(fileURLWithPath: path), label: "D") }
        app.portWindows.close(idA); app.portWindows.close(idB)
        RecSpikeLog.p("=== SPIKE D done ===")
    }

    private static func coloredHTML(label: String, hue: Int) -> String {
        """
        <html><body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;background:hsl(\(hue),70%,45%);color:#fff;font-family:monospace;font-size:40px;font-weight:bold">\(label)</body></html>
        """
    }

    // MARK: - Self-window resolution

    /// Port42's own frontmost/largest on-screen window (the record `{window:"self"}` target).
    private func resolveSelfWindow() async -> SCWindow? {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            RecSpikeLog.p("resolveSelfWindow: shareable content failed — \(error.localizedDescription)")
            return nil
        }
        let mine = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
                && $0.frame.width > 200 && $0.frame.height > 200
        }
        let win = mine.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        if let win {
            RecSpikeLog.p("resolveSelfWindow: id=\(win.windowID) title='\(win.title ?? "")' frame=\(win.frame) (\(mine.count) candidate windows)")
        } else {
            RecSpikeLog.p("resolveSelfWindow: NO self window found (bundle=\(Bundle.main.bundleIdentifier ?? "nil"))")
        }
        return win
    }

    // MARK: - The take

    @available(macOS 15, *)
    private func performRecording(window: SCWindow, config: SCStreamConfiguration, url: URL, label: String) async {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let recConfig = SCRecordingOutputConfiguration()
        recConfig.outputURL = url
        recConfig.outputFileType = .mov
        let delegate = RecSpikeOutputDelegate()
        let output = SCRecordingOutput(configuration: recConfig, delegate: delegate)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)

        do {
            try stream.addRecordingOutput(output)
            try await stream.startCapture()
        } catch {
            RecSpikeLog.p("\(label): start FAILED — \(error.localizedDescription)")
            return
        }
        RecSpikeLog.p("\(label): capturing \(config.width)x\(config.height) for \(seconds)s → \(url.lastPathComponent)")

        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

        // Stop, then await finalize (delegate) with a 3s watchdog so we never hang the spike.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var resumed = false
            let done: () -> Void = { if !resumed { resumed = true; cont.resume() } }
            delegate.onFinish = { _ in done() }
            Task {
                do { try await stream.stopCapture() }
                catch { RecSpikeLog.p("\(label): stopCapture error — \(error.localizedDescription)") }
            }
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                RecSpikeLog.p("\(label): finalize watchdog fired (3s) — checking file anyway")
                done()
            }
        }

        await checkOutput(url: url, label: label)
    }

    /// AVURLAsset probe: video track present? audio track present? duration + bytes. The RMS/silence
    /// confirmation is left to ffprobe on the human side; this proves the tracks exist.
    private func checkOutput(url: URL, label: String) async {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? Int) ?? 0
        guard bytes > 0 else { RecSpikeLog.p("\(label): VERDICT FAIL — no file / 0 bytes at \(url.path)"); return }

        let asset = AVURLAsset(url: url)
        let vTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let aTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let dur = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0

        RecSpikeLog.p("\(label): file=\(url.path) bytes=\(bytes) videoTracks=\(vTracks.count) audioTracks=\(aTracks.count) duration=\(String(format: "%.2f", dur))s")
    }

    // MARK: - Modes

    private func record(_ mode: Mode) async {
        RecSpikeLog.p("=== SPIKE \(mode.rawValue.uppercased()) start ===")
        guard #available(macOS 15, *) else { RecSpikeLog.p("requires macOS 15"); return }
        guard let window = await resolveSelfWindow() else { return }

        let scale = window.frame.width > 0 ? 2.0 : 1.0
        let url = URL(fileURLWithPath: "/tmp/screenrec-\(mode.rawValue).mov")
        try? FileManager.default.removeItem(at: url)

        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA

        switch mode {
        case .a:
            // Step 1 live smoke-test: drive the REAL ScreenRecorder (not inline capture). scale:1 so
            // the output should land at the window POINT size (1728x1079), proving the scale fix.
            let recorder = ScreenRecorder()
            let start = await recorder.start(target: .selfWindow, opts: ["audio": "system", "scale": 1.0])
            RecSpikeLog.p("A(real recorder): start → \(start)")
            guard let id = start["recordingId"] as? String else { RecSpikeLog.p("A: no recordingId; abort"); break }
            let sound = playLoopingSound()
            RecSpikeLog.p("A: recording \(seconds)s, playing looping sound=\(sound != nil)")
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            let res = await recorder.stop(recordingId: id)
            sound?.stop()
            RecSpikeLog.p("A(real recorder): stop → \(res)")
            if let path = res["path"] as? String { await checkOutput(url: URL(fileURLWithPath: path), label: "A") }

        case .b:
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = true
            RecSpikeLog.p("B: cursor ON — COVER Port42 with another app + move the mouse over it now.")
            await performRecording(window: window, config: config, url: url, label: "B")
            RecSpikeLog.p("B: inspect \(url.path) — expect ONLY Port42 in frame (no leak, no black); note if the pointer glitches.")

        case .c:
            // sourceRect hypothesis: window-relative, POINTS, origin top-left. Crop to a centered
            // inner rect (50% size). If the output shows the MIDDLE of the window, hypothesis holds.
            let w = window.frame.width, h = window.frame.height
            let rect = CGRect(x: w * 0.25, y: h * 0.25, width: w * 0.5, height: h * 0.5)
            config.sourceRect = rect
            config.width = Int(rect.width * scale)
            config.height = Int(rect.height * scale)
            config.showsCursor = false
            RecSpikeLog.p("C: windowFrame=\(window.frame) sourceRect=\(rect) (hypothesis: window-relative points) outputDims=\(config.width)x\(config.height)")
            await performRecording(window: window, config: config, url: url, label: "C")
            RecSpikeLog.p("C: inspect \(url.path) — if it shows the CENTER of the Port42 window, sourceRect is window-relative points.")

        case .d, .e:
            break   // routed to recordPortsLive()/recordTeardownLive() in run(); never reaches here
        }
        RecSpikeLog.p("=== SPIKE \(mode.rawValue.uppercased()) done ===")
    }

    /// A looping system sound so mode A's system-audio capture has real signal to record.
    private func playLoopingSound() -> NSSound? {
        let candidates = ["/System/Library/Sounds/Submarine.aiff", "/System/Library/Sounds/Sosumi.aiff"]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let s = NSSound(contentsOfFile: path, byReference: true) {
                s.loops = true
                s.play()
                return s
            }
        }
        return nil
    }
}
#endif
