import SwiftUI
import MapKit
import UIKit
import Observation

extension OnqaAccent {
     
     
     
    private static let swiftUIColors: [OnqaAccent: Color] = Dictionary(
        uniqueKeysWithValues: allCases.map { accent -> (OnqaAccent, Color) in
            let value = accent.color
             
            let color = Color(uiColor: UIColor { traits in
                let f: CGFloat = traits.userInterfaceStyle == .dark ? 1 : 0.45
                return UIColor(red: value.red * f, green: value.green * f, blue: value.blue * f, alpha: 1)
            })
            return (accent, color)
        }
    )

    var swiftUIColor: Color { Self.swiftUIColors[self] ?? .accentColor }
}

struct ContentView: View {
    let store: RadioStore

    private var preferredScheme: ColorScheme? {
        switch store.settings.theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.canEnterApp {
                    RadioHomeView(store: store)
                } else {
                    OnboardingView(store: store)
                        .toolbar(.hidden, for: .navigationBar)
                }
            }
        }
        .tint(store.settings.accent.swiftUIColor)
        .preferredColorScheme(preferredScheme)
        .task { await store.bootstrap() }
        .onChange(of: store.settings.onboardingCompleted) { _, completed in
            if completed { store.refreshStations() }
        }
    }
}
