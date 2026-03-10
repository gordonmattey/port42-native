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
        config.enableSwizzling = false
        PostHogSDK.shared.setup(config)
        PostHogSDK.shared.identify(userId)

        // Attach app version to every event
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        PostHogSDK.shared.register(["app_version": version, "app_build": build])

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
