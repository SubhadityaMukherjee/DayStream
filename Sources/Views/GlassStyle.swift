import SwiftUI
import AppKit

/// Link blue tuned for legibility on glass surfaces — stock control-accent
/// washes out over frosted backgrounds, especially in light mode.
extension NSColor {
    static var readableLink: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(srgbRed: 0.40, green: 0.64, blue: 1.00, alpha: 1)
                : NSColor(srgbRed: 0.02, green: 0.26, blue: 0.68, alpha: 1)
        }
    }
}

extension Color {
    static var readableLink: Color { Color(nsColor: .readableLink) }
}

/// Compact circular icon button for per-day row actions (add task, edit).
/// A subtle opaque circle so the control stays visible over the day
/// header's glass card, unlike bordered buttons which render square.
struct RoundIconButtonStyle: ButtonStyle {
    var tint: Color = .secondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(configuration.isPressed ? tint.opacity(0.5) : tint)
            .frame(width: 24, height: 24)
            .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .contentShape(.rect)
    }
}

extension ButtonStyle where Self == RoundIconButtonStyle {
    static var roundIcon: RoundIconButtonStyle { RoundIconButtonStyle() }
    static func roundIcon(_ tint: Color) -> RoundIconButtonStyle { RoundIconButtonStyle(tint: tint) }
}

/// Liquid Glass adoption with graceful fallbacks: the app targets macOS 15,
/// so every glass API (new in macOS 26) is availability-gated and older
/// systems keep the nearest material equivalent.
extension View {
    /// Background for floating panels (e.g. the search-results dropdown).
    /// Glass carries its own shadow; the fallback material needs one.
    @ViewBuilder
    func floatingPanelBackground<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        }
    }

    /// Frosted card for inline surfaces (search field, day headers, badges,
    /// editor chrome) — regular glass where available, thin material before.
    @ViewBuilder
    func glassCardBackground<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }

    /// Color-tinted glass (calendar today cell, status badges). The fallback
    /// fills the shape directly, matching the pre-glass look.
    @ViewBuilder
    func tintedGlassBackground<S: Shape>(_ tint: Color, in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.tint(tint), in: shape)
        } else {
            background(shape.fill(tint))
        }
    }

    /// Standard glass button for secondary actions (sidebar, icon buttons).
    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// The app's prominent action style (one per screen at most): adopts the
    /// tinted Liquid Glass button on macOS 26+, plain prominence before that.
    @ViewBuilder
    func prominentActionButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// Groups nearby glass elements so they render (and blend at their
    /// edges) as one family — e.g. a stack of sidebar buttons.
    @ViewBuilder
    func glassContainer(spacing: CGFloat = 8) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                self
            }
        } else {
            self
        }
    }
}
