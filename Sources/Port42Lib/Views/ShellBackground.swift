import SwiftUI

/// SHELL — the signed-in ambient background (Layer 0): a port of the prototype's `Dreamscape`
/// Canvas — deep-space gradient, breathing nebula glows, drifting starfield, synthwave perspective
/// floor — with cursor parallax. The *video* dreamscape (`DreamscapeVideoLayer`) is the SCREENSAVER,
/// shown only when signed out / locked (via `TransitionRoot` → `LockScreenView`). Signed in, the
/// shell shows this — matching the prototype.
struct ShellBackground: View {
    /// A/B switch for the perf investigation, read ONCE per launch so toggling it cannot itself
    /// perturb a measurement. `defaults write <domain> PORT42_NO_SHELL_BG -bool true`, relaunch,
    /// and Layer 0 becomes flat black. See `summer2026-todo.md`.
    static let isDisabledForMeasurement =
        UserDefaults.standard.bool(forKey: "PORT42_NO_SHELL_BG")

    /// SPIKE (2026-07-29): which SECTION of the Canvas costs what. The A/B proved Layer 0 is ~all of
    /// the idle burn and the scroll jitter, but not which part of it, and the answer decides whether
    /// to attack the gradients or the starfield first. Three full-window gradients could easily
    /// outweigh 160 small fills; guessing that would repeat the display-link mistake.
    ///
    /// Read ONCE per launch. Omit a name to drop that section:
    ///   defaults write com.port42.dev3 PORT42_BG_SECTIONS -string "nebula,stars,floor"
    /// Unset means everything, so a normal launch is untouched.
    static let sections: Set<String> = {
        guard let raw = UserDefaults.standard.string(forKey: "PORT42_BG_SECTIONS") else {
            return ["space", "nebula", "stars", "floor"]
        }
        return Set(raw.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        })
    }()

    /// SPIKE (2026-07-29): the frame CADENCE. The section sweep found an EMPTY Canvas inside
    /// `TimelineView(.animation)` still costs 14.3% of a core, so the per-frame framework overhead
    /// sets a floor that no amount of draw optimisation gets under. Cadence is therefore the
    /// dominant lever and content optimisation is second.
    ///
    /// **24 is the default** (GM 2026-07-29, judged on the look). Measured on Dev3, idle, all
    /// sections on: uncapped 27.4%, 30fps 12.3%, 24fps 9.6%, 12fps 9.8%. **Below film rate buys
    /// nothing** — 12 cost the same as 24 — so a lower cadence would only make the moving floor
    /// steppy for no saving. Override, including `-int 0` for the old uncapped behaviour:
    ///   defaults write com.port42.dev3 PORT42_BG_FPS -int 30      # TV
    ///   defaults write com.port42.dev3 PORT42_BG_FPS -int 0       # uncapped, as it shipped before
    static let fpsCap: Int = {
        // `object(forKey:)` first: `integer(forKey:)` cannot tell "unset" from an explicit 0, and 0
        // means uncapped, so a plain integer read would make the default unreachable.
        guard UserDefaults.standard.object(forKey: "PORT42_BG_FPS") != nil else { return 24 }
        return UserDefaults.standard.integer(forKey: "PORT42_BG_FPS")
    }()

    /// The schedule the cap implies. `.animation` with no interval means "as fast as the display".
    /// Paused whenever none of it can be seen (Phase 2 step 4): measured on Dev3 idle, 2026-09-25,
    /// before the pause, it cost 12.2% of a core visible and 35.5% with the window hidden.
    private var schedule: AnimationTimelineSchedule {
        let paused = ShellState.ambientPaused(windowVisible: shell.windowVisible, wallpaperShown: false)
        return .animation(minimumInterval: Self.fpsCap > 0 ? 1.0 / Double(Self.fpsCap) : nil, paused: paused)
    }

    @ObservedObject var shell: ShellState

    private var accent: Color { shell.accent }           // per-space theme
    private let accent2 = Color(red: 0.62, green: 0.28, blue: 0.98)

    var body: some View {
        TimelineView(schedule) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let px = (shell.mouse.x - 0.5) * 30, py = (shell.mouse.y - 0.5) * 20
            Canvas { ctx, size in
                let on = Self.sections
                // deep space gradient
                if on.contains("space") {
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                    with: .linearGradient(Gradient(colors: [Color(red: 0.03, green: 0.0, blue: 0.08), .black]),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                }

                // nebula glows (breathing + parallax)
                let b = 0.5 + 0.5 * sin(t * 0.4)
                if on.contains("nebula") {
                ctx.fill(Path(ellipseIn: CGRect(x: size.width * 0.2 - 220 + px, y: size.height * 0.15 - 220 + py, width: 440, height: 440)),
                    with: .radialGradient(Gradient(colors: [accent2.opacity(0.22 + 0.12 * b), .clear]),
                        center: CGPoint(x: size.width * 0.2 + px, y: size.height * 0.15 + py), startRadius: 0, endRadius: 260))
                ctx.fill(Path(ellipseIn: CGRect(x: size.width * 0.8 - 220 - px, y: size.height * 0.7 - 220 - py, width: 440, height: 440)),
                    with: .radialGradient(Gradient(colors: [accent.opacity(0.18 + 0.12 * (1 - b)), .clear]),
                        center: CGPoint(x: size.width * 0.8 - px, y: size.height * 0.7 - py), startRadius: 0, endRadius: 260))
                }

                // starfield (deterministic pseudo-random, drifting)
                if on.contains("stars") {
                for i in 0..<160 {
                    let sx = (Double((i * 73 + 17) % 1000) / 1000.0 * size.width + t * 6).truncatingRemainder(dividingBy: size.width)
                    let sy = Double((i * 131 + 53) % 1000) / 1000.0 * size.height
                    let tw = 0.4 + 0.6 * abs(sin(t * 1.5 + Double(i)))
                    let r = (i % 7 == 0) ? 1.6 : 0.8
                    ctx.fill(Path(ellipseIn: CGRect(x: sx + px * 0.3, y: sy + py * 0.3, width: r, height: r)),
                        with: .color(.white.opacity(0.5 * tw)))
                }
                }

                // synthwave perspective floor
                if on.contains("floor") {
                let horizon = size.height * 0.62
                let scroll = t.truncatingRemainder(dividingBy: 1.0)
                for i in 0..<24 {
                    let f = (Double(i) + scroll) / 24.0
                    let y = horizon + (size.height - horizon) * f * f
                    var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(p, with: .color(accent.opacity(0.05 + 0.18 * f)), lineWidth: 1)
                }
                let cx = size.width / 2 + px
                for i in -11...11 {
                    var p = Path(); p.move(to: CGPoint(x: cx + Double(i) * 22, y: horizon)); p.addLine(to: CGPoint(x: cx + Double(i) * size.width / 9, y: size.height))
                    ctx.stroke(p, with: .color(accent.opacity(0.06)), lineWidth: 1)
                }
                }
            }
        }
        .ignoresSafeArea()
    }
}
