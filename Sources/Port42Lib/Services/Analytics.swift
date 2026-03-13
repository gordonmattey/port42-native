import Foundation
import PostHog
import AppKit

/// Typed PostHog analytics for Port42.
/// All event tracking goes through named methods here, never raw strings elsewhere.
@MainActor
public final class Analytics {
    public static let shared = Analytics()

    private static let optInKey = "analyticsOptIn"

    private var configured = false

    /// Throttle window focus/blur to avoid spam on every Cmd-Tab.
    private var lastFocusEvent: Date = .distantPast
    private static let focusThrottle: TimeInterval = 60

    /// Whether the user has opted in to anonymous product analytics.
    public var isOptedIn: Bool {
        UserDefaults.standard.bool(forKey: Self.optInKey)
    }

    /// Set the user's analytics opt-in preference.
    public func setOptIn(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.optInKey)
        if !enabled && configured {
            PostHogSDK.shared.optOut()
        }
    }

    public func configure(userId: String) {
        guard !configured else { return }
        guard isOptedIn else {
            NSLog("[analytics] user has not opted in (analyticsOptIn = false)")
            return
        }

        let apiKey = ProcessInfo.processInfo.environment["POSTHOG_API_KEY"]
            ?? Bundle.main.object(forInfoDictionaryKey: "POSTHOG_API_KEY") as? String
            ?? ""
        guard !apiKey.isEmpty else {
            NSLog("[analytics] no PostHog API key configured")
            return
        }
        NSLog("[analytics] configuring PostHog for user %@", userId)

        let config = PostHogConfig(
            apiKey: apiKey,
            host: "https://ph.port42.ai"
        )
        config.captureScreenViews = false
        config.captureApplicationLifecycleEvents = false
        config.preloadFeatureFlags = false
        PostHogSDK.shared.setup(config)
        PostHogSDK.shared.identify(userId)

        // Attach app version to every event
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        PostHogSDK.shared.register(["app_version": version, "app_build": build])

        configured = true

        // Track window focus/blur (throttled)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.appFocused()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.appBlurred()
        }
    }

    // MARK: - Raw capture (private, use typed methods)

    private func track(_ event: String, properties: [String: Any]? = nil) {
        guard configured else { return }
        PostHogSDK.shared.capture(event, properties: properties)
    }

    // MARK: - App Lifecycle

    /// App launched or user swam in from lock screen. One per session.
    public func appOpened() { track("app_opened") }

    /// App quit or user signed out.
    public func appClosed() { track("app_closed") }

    /// App gained focus (throttled to 1/min to avoid Cmd-Tab spam).
    private func appFocused() {
        let now = Date()
        guard now.timeIntervalSince(lastFocusEvent) > Self.focusThrottle else { return }
        lastFocusEvent = now
        track("app_focused")
    }

    /// App lost focus (throttled).
    private func appBlurred() {
        // Not tracking blur separately, focus is sufficient for session tracking
    }

    // MARK: - Setup (boot sequence steps)

    public func setupCompleted() { track("setup_completed") }

    /// Track each interaction step of the onboarding flow.
    /// Steps: name_entered, analytics_opted_in/out, auth_claude_code/manual_token/api_key
    public func setupStep(_ step: String) {
        track("setup_step", properties: ["step": step])
    }

    // MARK: - Channels

    public func channelCreated() { track("channel_created") }

    public func channelSwitched() { track("channel_switched") }

    // MARK: - Messages

    public func messageSent() { track("message_sent") }

    // MARK: - Companions

    public func companionCreated() { track("companion_created") }

    public func companionAddedToChannel() { track("companion_added_to_channel") }

    // MARK: - Swims

    public func swimStarted() { track("swim_started") }

    // MARK: - Ports (no titles or user content)

    /// Companion generated an inline port in chat.
    public func portCreated() { track("port_created") }

    /// User popped a port out into a floating window.
    public func portPoppedOut() { track("port_popped_out") }

    /// User docked a port to the side panel.
    public func portDocked() { track("port_docked") }

    /// User undocked/floated a port.
    public func portUndocked() { track("port_undocked") }

    /// User closed a port.
    public func portClosed() { track("port_closed") }

    /// Companion updated an existing port.
    public func portUpdated() { track("port_updated") }

    // MARK: - Multiplayer

    /// User created and shared an invite link.
    public func inviteSent() { track("invite_sent") }

    /// User joined via an invite link.
    public func inviteJoined() { track("invite_joined") }

    /// OpenClaw gateway detected and connected.
    public func openClawDetected() { track("openclaw_detected") }

    /// Port42 plugin installed into OpenClaw.
    public func openClawPluginInstalled() { track("openclaw_plugin_installed") }

    /// User connected an OpenClaw agent to a channel.
    public func openClawConnected() { track("openclaw_agent_connected") }

    // MARK: - Tunneling

    /// User completed first time ngrok setup.
    public func ngrokConfigured() { track("ngrok_configured") }

    /// User toggled ngrok on/off from settings.
    public func ngrokToggled(enabled: Bool) {
        track("ngrok_toggled", properties: ["enabled": enabled])
    }

    // MARK: - Legacy (keep for backward compat with existing callsites)

    public func capture(_ event: String, properties: [String: Any]? = nil) {
        track(event, properties: properties)
    }

    public func screen(_ name: String) {
        guard configured else { return }
        PostHogSDK.shared.screen(name)
    }
}
