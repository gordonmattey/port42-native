import Foundation
import PostHog

/// Lightweight PostHog wrapper for Port42 telemetry.
@MainActor
public final class Analytics {
    public static let shared = Analytics()

    private static let optInKey = "analyticsOptIn"

    private var configured = false

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
        guard !configured, isOptedIn else { return }

        let apiKey = Bundle.main.object(forInfoDictionaryKey: "POSTHOG_API_KEY") as? String
            ?? ProcessInfo.processInfo.environment["POSTHOG_API_KEY"]
            ?? ""
        guard !apiKey.isEmpty else {
            print("[analytics] no PostHog API key configured")
            return
        }

        let config = PostHogConfig(
            apiKey: apiKey,
            host: "https://us.i.posthog.com"
        )
        config.captureScreenViews = false
        config.captureApplicationLifecycleEvents = false
        config.preloadFeatureFlags = false
        config.enableSwizzling = false
        PostHogSDK.shared.setup(config)
        PostHogSDK.shared.identify(userId)

        configured = true
    }

    public func capture(_ event: String, properties: [String: Any]? = nil) {
        guard configured else { return }
        PostHogSDK.shared.capture(event, properties: properties)
    }

    public func screen(_ name: String) {
        guard configured else { return }
        PostHogSDK.shared.screen(name)
    }
}
