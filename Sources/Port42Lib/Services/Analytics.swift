import Foundation
import PostHog

/// Lightweight PostHog wrapper for Port42 telemetry.
@MainActor
public final class Analytics {
    public static let shared = Analytics()

    private var configured = false

    public func configure(userId: String) {
        guard !configured else { return }

        let config = PostHogConfig(
            apiKey: "phc_DDR13ZN1UqQXXsChPsSkjaFWO6HM4VUwYITgrX3SghI",
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
