import SwiftUI
import MapKit
import UIKit
import Observation

// MARK: - Onboarding

struct OnboardingView: View {
    let store: RadioStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingRequiredManualMap = false
    @ScaledMetric(relativeTo: .largeTitle) private var welcomeTitleSize: CGFloat = 32
    @ScaledMetric(relativeTo: .body) private var locationMessageSize: CGFloat = 16

    private var accent: Color { store.settings.accent.swiftUIColor }

    var body: some View {
        let hasLocationAccess = store.hasLocationAccess

        GeometryReader { geometry in
            let isCompact = geometry.size.height < 760
            let isTight = geometry.size.height < 680
            let artworkSize = min(172, max(124, geometry.size.height * 0.22))

            VStack(spacing: 0) {
                // Keep the app identity anchored at the top of the screen.
                VStack(spacing: 0) {
                    Image("OnboardingAppIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: artworkSize * 0.82, height: artworkSize * 0.82)
                        .clipShape(RoundedRectangle(cornerRadius: artworkSize * 0.18, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                        .frame(maxWidth: .infinity)
                        .frame(height: artworkSize)
                        .padding(.bottom, isTight ? 8 : 12)

                    Text("Welcome to Onqa")
                        .font(.system(size: isTight ? welcomeTitleSize * 0.8125 : (isCompact ? welcomeTitleSize * 0.875 : welcomeTitleSize), weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, isTight ? 2 : 8)

                // Equal flexible space above and below keeps this action in the
                // visual centre between the header and the bottom action area.
                Spacer(minLength: isTight ? 12 : 24)

                Button {
                    if store.needsLocationSettings {
                        // iOS only presents the permission alert once. After a
                        // denial, the app's Settings page is the supported path.
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    } else {
                        store.requestLocationAccess()
                    }
                } label: {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: "location.fill")
                            .font(.system(size: isTight ? 19 : 21, weight: .semibold))
                            .foregroundStyle(accent)
                            .frame(width: 28)
                        Text("Onqa needs access to your location.")
                            .font(.system(size: isTight ? locationMessageSize * 0.875 : (isCompact ? locationMessageSize * 0.9375 : locationMessageSize), weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 8)

                        if hasLocationAccess {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 21, weight: .semibold))
                                .foregroundStyle(accent)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(isTight ? 16 : 20)
                    .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .onqaGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)

                Spacer(minLength: isTight ? 12 : 24)

                // Keep the single relevant completion action at the bottom.
                if hasLocationAccess {
                    Button {
                        store.completeOnboarding()
                    } label: {
                        Text("Alright")
                            .font(.headline)
                            .foregroundStyle(colorScheme == .dark ? Color.black.opacity(0.85) : Color.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, isTight ? 13 : (isCompact ? 15 : 18))
                            .onqaAccentCapsule(accent)
                            // Make the full visible capsule tappable.
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("onboarding-alright-button")
                    .padding(.horizontal, 24)
                } else {
                    VStack(spacing: isTight ? 4 : 8) {
                        Text("Without location access, you can use Manual mode only. Choose your location in Settings.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16)

                        Button {
                            store.prepareManualOnboarding()
                            showingRequiredManualMap = true
                        } label: {
                            Text("Continue in Manual mode")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("onboarding-manual-mode-button")
                        .padding(.horizontal, 24)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, isTight ? 8 : (isCompact ? 14 : 20))
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.background.ignoresSafeArea())
        .fullScreenCover(isPresented: $showingRequiredManualMap) {
            NavigationStack {
                MapLocationPickerView(store: store, requiresOnboardingConfirmation: true)
            }
            .interactiveDismissDisabled(true)
        }
        .onAppear {
            store.refreshLocationAuthorizationStatus()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.refreshLocationAuthorizationStatus()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: hasLocationAccess)
    }
}
