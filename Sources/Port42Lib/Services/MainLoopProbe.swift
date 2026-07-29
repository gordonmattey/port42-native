//  MainLoopProbe — is a main-thread stall ONE unbounded pass, or a NON-TERMINATING LOOP?
//
//  `sample` cannot answer this. It merges by symbol, so one enormous `GraphHost.runTransaction` and
//  ten thousand repeated ones produce an identical stack. The answer decides the fix for the
//  chat-input beachball (`summer2026-todo.md`): if the layout pass repeats forever, making each pass
//  cheaper only shortens an iteration and the app still hangs.
//
//  The measurement is a HEARTBEAT, not an observer log. A runloop observer on the main thread bumps a
//  counter; a BACKGROUND queue reads the delta every 250ms and writes it out. The background half is
//  the point — it keeps reporting while the main thread is wedged, which is exactly when an observer
//  that logs on the main thread would tell us nothing.
//
//  Reading the result, during a beachball:
//    delta climbing  -> the runloop keeps completing spins -> LIVELOCK (re-dirty source is the bug)
//    delta == 0      -> the main thread never returns to the loop -> ONE unbounded pass
//
//  Usage:
//    defaults write com.port42.dev3 PORT42_MAINLOOP_PROBE -bool true   (then relaunch)
//    tail -f /tmp/port42-mainloop.log
//
//  DEBUG only, and inert unless the default is set.

#if DEBUG
import Foundation

public enum MainLoopProbe {

    /// Off makes install() a no-op. Read from `PORT42_MAINLOOP_PROBE` at launch.
    public static var enabled = false

    public static let logPath = "/tmp/port42-mainloop.log"

    /// A gap this long between heartbeats counts as a stall worth naming in the log.
    private static let stallThreshold: TimeInterval = 0.5

    // MARK: - Shared state
    //
    // Written by the main thread's runloop observer, read by the background sampler. `os_unfair_lock`
    // rather than a serial queue: the observer runs on EVERY runloop activity, so it has to be
    // effectively free, and a queue hop here would perturb the thing being measured.

    private static var lock = os_unfair_lock()
    private static var spins: UInt64 = 0
    private static var observer: CFRunLoopObserver?
    private static var sampler: DispatchSourceTimer?

    // MARK: - Install

    public static func install() {
        guard enabled, observer == nil else { return }

        write("=== MainLoopProbe start \(stamp()) pid \(ProcessInfo.processInfo.processIdentifier) ===")
        write("delta = main-thread runloop activities per 250ms window.")
        write("During a beachball: climbing = LIVELOCK, zero = ONE UNBOUNDED PASS.")

        // Every activity, not just beforeWaiting. SwiftUI's own observer runs at beforeWaiting, and
        // if IT is the thing that never returns, an observer registered only there could be starved
        // by ordering and report a false zero. Counting every activity removes that ambiguity.
        let activities: CFOptionFlags = CFRunLoopActivity.allActivities.rawValue
        let obs = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, activities, true, Int.min
        ) { _, _ in
            os_unfair_lock_lock(&lock)
            spins &+= 1
            os_unfair_lock_unlock(&lock)
        }
        observer = obs

        // BOTH modes. A click into a text field hands control to AppKit's field-editor tracking loop,
        // which runs in NSEventTrackingRunLoopMode — that is the mode the hang lives in, and it is
        // NOT part of commonModes for this purpose.
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, CFRunLoopMode.defaultMode)
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs,
                             CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs,
                             CFRunLoopMode(RunLoop.Mode.modalPanel.rawValue as CFString))

        // The background half. A plain DispatchSourceTimer on a dedicated queue, so nothing about
        // this depends on the main thread being alive.
        let q = DispatchQueue(label: "com.port42.mainloopprobe", qos: .userInitiated)
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(10))

        var last: UInt64 = 0
        var lastTick = Date()
        var stallStart: Date?
        var quietWindows = 0

        t.setEventHandler {
            os_unfair_lock_lock(&lock)
            let now = spins
            os_unfair_lock_unlock(&lock)

            let delta = now &- last
            last = now
            let tick = Date()
            let gap = tick.timeIntervalSince(lastTick)
            lastTick = tick

            if delta == 0 {
                quietWindows += 1
                if stallStart == nil { stallStart = tick }
                // An idle app also produces zero, so only shout once it has gone on long enough to
                // be the thing we are hunting. An idle Mac app parks in mach_msg with no activity.
                if quietWindows == Int(stallThreshold / 0.25) {
                    write("[\(stamp())] STALL BEGINS — main runloop has completed NO activity for "
                          + String(format: "%.2fs", stallThreshold)
                          + ". If the UI is beachballing NOW, this is ONE UNBOUNDED PASS.")
                }
            } else {
                if let s = stallStart, quietWindows >= Int(stallThreshold / 0.25) {
                    write("[\(stamp())] stall ended after "
                          + String(format: "%.2fs", tick.timeIntervalSince(s))
                          + ", loop resumed with \(delta) activities")
                }
                stallStart = nil
                quietWindows = 0
                // Log EVERY window rather than only above a threshold. Calibration killed the
                // threshold idea: a HEALTHY Dev3 already runs 400-900 activities per 250ms, because
                // ShellBackground's TimelineView(.animation) never lets the loop rest. So the rate
                // alone says nothing, and the discriminator is the SHAPE of the trace across the
                // moment the UI freezes. A continuous trace needs no calibration.
                write("[\(stamp())] delta=\(delta) gap=" + String(format: "%.2fs", gap))
            }
        }
        t.resume()
        sampler = t
    }

    // MARK: - Output

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    /// Appends, and flushes on every line. A probe whose output is sitting in a buffer when the
    /// process is force-quit has measured nothing.
    private static func write(_ line: String) {
        let data = (line + "\n").data(using: .utf8)!
        if let h = FileHandle(forWritingAtPath: logPath) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.synchronize()
            try? h.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: logPath))
        }
    }
}
#endif
