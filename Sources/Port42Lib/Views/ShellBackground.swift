import SwiftUI

/// SHELL — the signed-in ambient background (Layer 0): a port of the prototype's `Dreamscape`
/// Canvas — deep-space gradient, breathing nebula glows, drifting starfield, synthwave perspective
/// floor — with cursor parallax. The *video* dreamscape (`DreamscapeVideoLayer`) is the SCREENSAVER,
/// shown only when signed out / locked (via `TransitionRoot` → `LockScreenView`). Signed in, the
/// shell shows this — matching the prototype.
struct ShellBackground: View {
    @ObservedObject var shell: ShellState

    private var accent: Color { shell.accent }           // per-space theme
    private let accent2 = Color(red: 0.62, green: 0.28, blue: 0.98)

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let px = (shell.mouse.x - 0.5) * 30, py = (shell.mouse.y - 0.5) * 20
            Canvas { ctx, size in
                // deep space gradient
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                    with: .linearGradient(Gradient(colors: [Color(red: 0.03, green: 0.0, blue: 0.08), .black]),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

                // nebula glows (breathing + parallax)
                let b = 0.5 + 0.5 * sin(t * 0.4)
                ctx.fill(Path(ellipseIn: CGRect(x: size.width * 0.2 - 220 + px, y: size.height * 0.15 - 220 + py, width: 440, height: 440)),
                    with: .radialGradient(Gradient(colors: [accent2.opacity(0.22 + 0.12 * b), .clear]),
                        center: CGPoint(x: size.width * 0.2 + px, y: size.height * 0.15 + py), startRadius: 0, endRadius: 260))
                ctx.fill(Path(ellipseIn: CGRect(x: size.width * 0.8 - 220 - px, y: size.height * 0.7 - 220 - py, width: 440, height: 440)),
                    with: .radialGradient(Gradient(colors: [accent.opacity(0.18 + 0.12 * (1 - b)), .clear]),
                        center: CGPoint(x: size.width * 0.8 - px, y: size.height * 0.7 - py), startRadius: 0, endRadius: 260))

                // starfield (deterministic pseudo-random, drifting)
                for i in 0..<160 {
                    let sx = (Double((i * 73 + 17) % 1000) / 1000.0 * size.width + t * 6).truncatingRemainder(dividingBy: size.width)
                    let sy = Double((i * 131 + 53) % 1000) / 1000.0 * size.height
                    let tw = 0.4 + 0.6 * abs(sin(t * 1.5 + Double(i)))
                    let r = (i % 7 == 0) ? 1.6 : 0.8
                    ctx.fill(Path(ellipseIn: CGRect(x: sx + px * 0.3, y: sy + py * 0.3, width: r, height: r)),
                        with: .color(.white.opacity(0.5 * tw)))
                }

                // synthwave perspective floor
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
        .ignoresSafeArea()
    }
}
