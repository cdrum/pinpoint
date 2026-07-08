import SwiftUI

/// Design tokens for the Pinpoint redesign (see design_handoff_pinpoint_redesign).
///
/// The handoff is a light, Apple-native aesthetic. Colors are pinned to the
/// exact values from the spec; where a value maps cleanly onto a system color we
/// still use the literal so the app reads identically to the reference.
enum Theme {
    // Accent
    static let accent = Color(hex: 0x007AFF)
    static let accentHover = Color(hex: 0x0067D6)
    static let focusRing = Color(hex: 0x007AFF).opacity(0.12)

    // Text
    static let textPrimary = Color(hex: 0x1D1D1F)
    static let textSecondary = Color(hex: 0x86868B)
    static let textTertiary = Color(hex: 0xAEAEB2)
    static let textQuaternary = Color(hex: 0xC4C4C9)

    // Surfaces
    static let sidebarBg = Color(hex: 0xECECEE)
    static let sidebarBorder = Color(hex: 0xDBDBDE)
    static let contentBg = Color(hex: 0xFFFFFF)
    static let toolbarBg = Color(hex: 0xF6F6F7)
    static let toolbarBorder = Color(hex: 0xE0E0E2)
    static let inspectorBg = Color(hex: 0xFAFAFB)

    // Separators
    static let separatorLight = Color(hex: 0xEEEEF0)
    static let separatorMedium = Color(hex: 0xE3E3E6)

    // Controls
    static let segmentTrack = Color(hex: 0xE9E9EB)
    static let confidenceTrack = Color(hex: 0xE4E4E9)
    static let secondaryButtonBg = Color(hex: 0xF2F2F4)
    static let secondaryButtonBorder = Color(hex: 0xE0E0E2)
    static let toggleOff = Color(hex: 0xE4E4E9)

    // Bubbles
    static let userBubble = Color(hex: 0xE4EEFF)
    static let assistantBubble = Color(hex: 0xF1F1F4)
    static let bubbleText = Color(hex: 0x1D1D1F)

    // Status
    static let alert = Color(hex: 0xFF3B30)        // map pin / confidence badge
    static let warning = Color(hex: 0xFF9500)      // no location yet
    static let success = Color(hex: 0x34C759)      // status dot / toggle-on

    // Radii
    enum Radius {
        static let window: CGFloat = 12
        static let card: CGFloat = 12
        static let button: CGFloat = 9
        static let bubble: CGFloat = 16
        static let bubbleTail: CGFloat = 4
        static let thumbnail: CGFloat = 6
        static let reference: CGFloat = 7
        static let map: CGFloat = 10
    }
}

extension Color {
    /// Build a color from a 0xRRGGBB literal.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - Reusable button styles

/// The blue primary action button (Send, Set photo location).
struct PrimaryButtonStyle: ButtonStyle {
    var fill: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(configuration.isPressed ? Theme.accentHover : fill,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.button))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.button))
            .opacity(isEnabled ? 1 : 0.5)
    }
    @Environment(\.isEnabled) private var isEnabled
}

/// The light secondary button (Copy).
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Theme.secondaryButtonBg,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.button))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button)
                .stroke(Theme.secondaryButtonBorder, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var pinpointPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}
extension ButtonStyle where Self == SecondaryButtonStyle {
    static var pinpointSecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}
