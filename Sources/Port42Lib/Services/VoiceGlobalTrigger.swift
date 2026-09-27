import AppKit
import CoreGraphics

/// Sees the space bar while another app has the keyboard.
///
/// A local monitor only sees our own events, and a global monitor cannot swallow one, so this is an event
/// tap, which needs Accessibility.
///
/// **The tap reads one key code and the modifier flags, decides, and returns.** It never accumulates,
/// stores, logs or forwards a keystroke, nothing on the port bridge can reach it, and no port can ask for
/// it. That is the whole security position of dictating into other apps, and it is pinned by a test rather
/// than by this comment.
///
/// Hold-versus-tap is decided by the same `VoiceTrigger` the in-app path uses, so the behavior is the code
/// that is already tested.
public final class VoiceGlobalTrigger {

    /// Off unless this is on AND Accessibility is granted. Voice inside Port42 needs neither.
    public static let enabledKey = "voiceInOtherApps"

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var trigger = VoiceTrigger()
    private var thresholdTimer: Timer?
    /// The tap runs on a thread of its own, NOT on the main run loop. A tap that takes too long to answer is
    /// switched off by the system, and on the main thread that would mean every keystroke on the machine
    /// waiting behind whatever the app is drawing. Everything the tap touches (`trigger`, the timer) lives on
    /// this thread; only `onBegin`/`onEnd` hop to main.
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    private let onBegin: () -> Void
    private let onEnd: () -> Void

    public init(onBegin: @escaping () -> Void, onEnd: @escaping () -> Void) {
        self.onBegin = onBegin
        self.onEnd = onEnd
    }

    public var isInstalled: Bool { tap != nil }

    /// Whether the feature is switched on and the system will allow it.
    public static var allowed: Bool {
        UserDefaults.standard.bool(forKey: enabledKey) && VoicePermissions.accessibilityGranted()
    }

    @discardableResult
    public func install() -> Bool {
        guard tap == nil, Self.allowed else { return false }

        guard VoicePermissions.accessibilityGranted() else {
            p42log("[Port42] voice: accessibility not granted, not listening in other apps")
            return false
        }
        let thread = Thread { [weak self] in
            guard let self else { return }
            guard self.createTap() else {
                p42log("[Port42] voice: could not create the key tap (accessibility granted but refused)")
                return
            }
            self.runLoop = CFRunLoopGetCurrent()
            while !Thread.current.isCancelled, self.tap != nil {
                CFRunLoopRunInMode(.defaultMode, 0.5, false)
            }
        }
        thread.name = "port42.voice.tap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        return true
    }

    private func createTap() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                         place: .headInsertEventTap,
                                         options: .defaultTap,
                                         eventsOfInterest: CGEventMask(mask),
                                         callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let trigger = Unmanaged<VoiceGlobalTrigger>.fromOpaque(context).takeUnretainedValue()
            return trigger.handle(type: type, event: event)
        }, userInfo: me) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        self.runLoop = CFRunLoopGetCurrent()
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        p42log("[Port42] voice: listening for the space bar in other apps")
        return true
    }

    public func uninstall() {
        thresholdTimer?.invalidate(); thresholdTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop, let runLoopSource { CFRunLoopRemoveSource(runLoop, runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        thread?.cancel()
        thread = nil
        runLoop = nil
        _ = trigger.cancel()
        p42log("[Port42] voice: stopped listening in other apps")
    }

    /// One event. Everything that is not an unmodified space passes straight back, untouched and unread.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // A tap that takes too long is switched off by the system; switch it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Port42 frontmost means the in-app path owns the hold, and it can compose instead of typing.
        guard !VoiceTyper.port42IsFrontmost else { return Unmanaged.passUnretained(event) }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let hasModifiers = !flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let now = Double(event.timestamp) / 1_000_000_000

        let action: VoiceTrigger.Action
        switch type {
        case .keyDown: action = trigger.keyDown(keyCode: keyCode, hasModifiers: hasModifiers,
                                                isRepeat: isRepeat, now: now)
        case .keyUp:   action = trigger.keyUp(keyCode: keyCode, now: now)
        default:       return Unmanaged.passUnretained(event)
        }

        switch action {
        case .consume:
            return nil
        case .passThrough:
            if trigger.isPending { armThreshold() }
            return Unmanaged.passUnretained(event)
        case .beginCapture:
            return Unmanaged.passUnretained(event)         // the threshold timer raises this, not an event
        case .endCapture:
            cancelThreshold()
            DispatchQueue.main.async { [onEnd] in onEnd() }
            return nil                                      // the release belongs to the hold
        }
    }

    /// On the tap's own thread, where `trigger` lives.
    private func armThreshold() {
        thresholdTimer?.invalidate()
        let timer = Timer(timeInterval: VoiceTrigger.threshold, repeats: false) { [weak self] _ in
            guard let self, self.trigger.thresholdElapsed() == .beginCapture else { return }
            // The space has already been typed into the other app; take it back, the way the in-app path
            // retracts it.
            VoiceTyper.backspace(1)
            DispatchQueue.main.async { [onBegin = self.onBegin] in onBegin() }
        }
        thresholdTimer = timer
        if let runLoop { CFRunLoopAddTimer(runLoop, timer, .defaultMode) }
    }

    private func cancelThreshold() {
        thresholdTimer?.invalidate()
        thresholdTimer = nil
    }
}
