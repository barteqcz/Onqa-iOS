import SwiftUI
import UIKit

/// Colors modelled on the Android app's dark Material look, with light-mode counterparts.
enum Palette {
    static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }

    static let background = dynamic(dark: 0x000000, light: 0xF4F3F8)
    static let stationCardSurface = dynamic(dark: 0x1C1C1E, light: 0xFFFFFF)
    static let outline = dynamic(dark: 0x2D2D36, light: 0xDAD9E0)
    static let favoriteAccent = Color(uiColor: UIColor { traits in
        let f: CGFloat = traits.userInterfaceStyle == .dark ? 1 : 0.45
        return UIColor(red: 1.0 * f, green: 0.48 * f, blue: 0.52 * f, alpha: 1)
    })
}

private func makeGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}

extension View {
    /// Liquid Glass is the native surface style on the app's iOS 26 minimum.
    func onqaGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        self.glassEffect(makeGlass(tint: tint, interactive: interactive), in: shape)
    }
}

extension View {
    /// Primary call-to-action capsule using the native iOS 26 Liquid Glass surface.
    func onqaAccentCapsule(_ accent: Color) -> some View {
        self.onqaGlass(Capsule(), tint: accent, interactive: true)
    }
}
