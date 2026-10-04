import Foundation

/// How often Port42 runs JavaScript in each port's page, by kind (#257). Every call wakes the shared web
/// content process if macOS has put it to sleep, and WebKit takes that wake on the main thread; Dev6 did it 3 to
/// 6 times a second around the clock. Counted here and logged once a minute, busiest first, so the fix can go
/// where the calls come from.
@MainActor
enum PageCalls {
    private static var counts: [String: Int] = [:]
    private static var timer: Timer?

    static func note(_ port: String, _ kind: String) {
        counts["\(port) · \(kind)", default: 0] += 1
        if timer == nil, !AppState.isTestProcess {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                Task { @MainActor in PageCalls.report() }
            }
        }
    }

    static func report() {
        guard !counts.isEmpty else { return }
        let total = counts.values.reduce(0, +)
        let top = counts.sorted { $0.value > $1.value }.prefix(10).map { "\($0.value) \($0.key)" }
        p42log("[pagecalls] %d in the last minute: %@", total, top.joined(separator: "; "))
        counts = [:]
    }
}
