import Foundation

/// How long the main thread keeps work waiting (the freezes, 2026-10-03). Every second, from a background queue,
/// it sends the same instant two ways: a plain main-queue block, and a main-actor task. A slow main queue means
/// the main thread is busy; a slow main actor with a quick main queue means Swift's scheduling held the task.
/// Logs only what took over a second.
enum MainProbe {
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?

    static func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.port42.mainprobe", qos: .utility))
        t.schedule(deadline: .now() + 5, repeating: 1)
        t.setEventHandler {
            let sent = Date()
            DispatchQueue.main.async {
                let d = Date().timeIntervalSince(sent)
                if d > 1 { p42log("[probe] main queue waited %.1fs", d) }
            }
            Task { @MainActor in
                let d = Date().timeIntervalSince(sent)
                if d > 1 { p42log("[probe] main actor waited %.1fs", d) }
            }
        }
        t.resume()
        timer = t
    }
}
