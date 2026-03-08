import SwiftUI

public enum Port42Theme {
    // Backgrounds
    public static let bgPrimary = Color(hex: 0x000000)
    public static let bgSecondary = Color(hex: 0x111111)
    public static let bgSidebar = Color(hex: 0x0A0A0A)
    public static let bgInput = Color(hex: 0x1A1A1A)
    public static let bgHover = Color(hex: 0x1A1A1A)

    // Accent
    public static let accent = Color(hex: 0x00FF41)
    public static let accentDim = Color(hex: 0x00FF41).opacity(0.3)

    // Text
    public static let textPrimary = Color(hex: 0xE0E0E0)
    public static let textSecondary = Color(hex: 0x888888)
    public static let textAgent = Color(hex: 0x00D4AA)

    // Agent color palette for per-agent variation
    public static let agentColors: [Color] = [
        Color(hex: 0x00D4AA),  // teal (default)
        Color(hex: 0xFF6B9D),  // pink
        Color(hex: 0x7B68EE),  // purple
        Color(hex: 0xFFB347),  // orange
        Color(hex: 0x87CEEB),  // sky blue
        Color(hex: 0xDDA0DD),  // plum
        Color(hex: 0x98FB98),  // pale green
        Color(hex: 0xF0E68C),  // khaki
    ]

    /// Deterministic color for an agent based on its name and optional owner
    public static func agentColor(for name: String, owner: String? = nil) -> Color {
        let key = owner.map { "\(name)·\($0)" } ?? name
        let hash = key.utf8.reduce(0) { ($0 &+ Int($1)) &* 31 }
        return agentColors[abs(hash) % agentColors.count]
    }

    // Borders
    public static let border = Color(hex: 0x333333)
    public static let borderActive = Color(hex: 0x00FF41)

    // Status
    public static let error = Color(hex: 0xFF4444)
    public static let warning = Color(hex: 0xFFAA00)

    // Font
    public static let monoFont = Font.system(.body, design: .monospaced)
    public static let monoFontSmall = Font.system(.caption, design: .monospaced)
    public static let monoFontLarge = Font.system(.title3, design: .monospaced).bold()

    public static func mono(_ size: CGFloat) -> Font {
        .system(size: size, design: .monospaced)
    }

    public static func monoBold(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .monospaced)
    }
}

extension Color {
    public init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}
