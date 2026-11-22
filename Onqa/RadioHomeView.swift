import SwiftUI
import MapKit
import UIKit
import Observation

// MARK: - Home

/// Fade that lifts the mini player off the station list. It is drawn as a
/// layer *behind* the player (as the player's background), so the player's
/// glass simply sits on top of it. Nothing is cut out around the player, so
/// the glass can grow, press and animate freely as a single element.
private struct BottomEdgeFade: View {
    /// Bottom safe-area height, supplied by the screen's own layout.
    let bottomInset: CGFloat
    /// How far the mini player is pushed below the safe-area edge.
    let playerDrop: CGFloat
    /// Measured height of the mini player; the fade starts at its top edge.
    let playerHeight: CGFloat

    var body: some View {
        let belowSafeArea = bottomInset + playerDrop
        LinearGradient(
            stops: [
                .init(color: Palette.background.opacity(0.80), location: 0),
                .init(color: Palette.background.opacity(0.74), location: 0.18),
                .init(color: Palette.background.opacity(0.62), location: 0.40),
                .init(color: Palette.background.opacity(0.43), location: 0.63),
                .init(color: Palette.background.opacity(0.20), location: 0.84),
                .init(color: Palette.background.opacity(0), location: 1)
            ],
            startPoint: .bottom,
            endPoint: .top
        )
        // Spans from the player's top edge down to the physical screen bottom.
        .frame(height: playerHeight + belowSafeArea)
        .offset(y: belowSafeArea)
        .allowsHitTesting(false)
    }
}

private struct HomeToolbarBackground: ViewModifier {
    let showLocationHeader: Bool
    let colorScheme: ColorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if showLocationHeader {
            content
                .toolbarBackground(colorScheme == .light ? Palette.background : Color.black, for: .navigationBar)
                .toolbarBackgroundVisibility(.visible, for: .navigationBar)
                .toolbarColorScheme(colorScheme, for: .navigationBar)
        } else {
            // Remove the navigation bar's default opaque background. The
            // ScrollView's soft top-edge effect remains visible underneath.
            content
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        }
    }
}

/// Scroll-edge effect for the top of the station list.
/// With the location header, the solid header gets a hard edge. Without it,
/// the system's native soft edge effect is used: the standard iOS blur behind
/// the status bar, with no opaque backdrop of our own.
private struct TopScrollEdgeEffect: ViewModifier {
    let hasLocationHeader: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if hasLocationHeader {
            content.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        }
    }
}

struct RadioHomeView: View {
    @Bindable var store: RadioStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    // The environment locale follows the system's Measurement System, so cards
    // update if it is changed in Settings while the app is running.
    @Environment(\.locale) private var locale
    /// Search is a row pinned to the top of the screen, just under the native
    /// navigation bar. It is shown only while searching and holds the field
    /// and a Cancel button in one glass container.
    @State private var searchIsActive = false
    @FocusState private var searchFocused: Bool
    @Namespace private var searchGlassNamespace
    @State private var showingSettings = false
    /// The catalog card currently on screen. It trails the store's status so a
    /// fast download never flashes it (see `syncCatalogStatus`).
    @State private var presentedCatalogStatus: CatalogStatus?
    // Header metrics follow the user's Dynamic Type setting.
    @ScaledMetric(relativeTo: .title) private var headerFlagSize: CGFloat = 32
    @ScaledMetric(relativeTo: .title) private var headerTitleSize: CGFloat = 26
    @ScaledMetric(relativeTo: .title) private var headerRowHeight: CGFloat = 38
    @State private var bottomSafeInset: CGFloat = 0
    @State private var miniPlayerHeight: CGFloat = 88

    /// How far the mini player sits below the bottom safe-area edge. Shared by
    /// the player's padding and the fade behind it so they cannot drift apart.
    private static let miniPlayerDrop: CGFloat = 10
    // Station cards use a 16-point inset. The mini-player is deliberately wider.
    private static let miniPlayerHorizontalInset: CGFloat = 16

    private var player: RadioAudioPlayer { store.player }

    private var showsMiniPlayer: Bool {
        player.currentStation != nil
    }

    private var showsLocationHeader: Bool {
        store.settings.showLocationHeader && !searchIsActive
    }

    private var accent: Color { store.settings.accent.swiftUIColor }

    private var distanceUnit: DistanceUnit {
        DistanceUnit(measurementSystem: locale.measurementSystem)
    }

    /// Shared 14-point spacing between station cards and the bottom of every header.
    private static let stationSpacing: CGFloat = 14

    /// Small scroll-content inset keeps the first station's outline fully visible.
    private static let stationListTopMargin: CGFloat = 5

    /// Height of the native Liquid Glass toolbar buttons (search, settings).
    /// The search field and its close button use the same height.
    private static let toolbarControlHeight: CGFloat = 44

    private static let searchAnimation: Animation = .smooth(duration: 0.32)

    /// How long the context menu takes to dismiss. The favorite re-sort waits
    /// this long so the pressed card is free to slide (see `onFavorite`).
    private static let favoriteMenuDismissDelay: Duration = .milliseconds(400)

    private static let stationMinimumWidth: CGFloat = 320
    private static let stationContentHorizontalInset: CGFloat = 16

    /// Calculate columns from the station list's current container width.
    /// Compact-width phones in portrait are always kept to a single column;
    /// other layouts use the available width to decide whether two fit.
    private func stationColumns(for availableWidth: CGFloat) -> [GridItem] {
        let spacing = Self.stationSpacing
        let count = max(
            1,
            Int((availableWidth + spacing) / (Self.stationMinimumWidth + spacing))
        )
        return Array(
            repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
            count: count
        )
    }

    /// Keep the 14pt toolbar gap and 5pt first-card inset consistent in both
    /// search states when the location label is hidden.
    private var stationListTopInset: CGFloat {
        Self.stationListTopMargin
            + (!store.settings.showLocationHeader ? Self.stationSpacing : 0)
    }

    var body: some View {
        Group {
            if store.settings.showLocationHeader {
                VStack(spacing: 0) {
                    headerSection
                    stationList
                }
            } else {
                // Keep the ScrollView as the root in no-location mode. This
                // lets its content pass beneath the transparent navigation bar
                // and keeps the top inset inside the clear, scrolling surface.
                stationList
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if searchIsActive {
                searchRow
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // Measured inside the keyboard-ignoring modifier below, so the keyboard
        // never inflates the inset.
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: {
            bottomSafeInset = $0
        }
        // Ignore keyboard-driven safe-area changes at the home layout level,
        // so the mini-player stays at the bottom edge when search opens the keyboard.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background {
            if store.settings.showLocationHeader {
                Palette.background.ignoresSafeArea()
            } else {
                // In no-location mode, leave the area behind the native
                // navigation-bar blur transparent in both search states.
                Color.clear.ignoresSafeArea()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showsMiniPlayer)
        // Keep a stable navigation title for the native back-button menu.
        // The invisible title toolbar item below keeps it off the home screen.
        .navigationTitle("Station List")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar(removing: .title)
        .modifier(HomeToolbarBackground(showLocationHeader: store.settings.showLocationHeader, colorScheme: colorScheme))
        .task(id: store.catalogStatus) {
            await syncCatalogStatus()
        }
        .toolbar {
            if !searchIsActive {
                leadingToolbarItem
            }
            trailingToolbarItem
        }
        .navigationDestination(isPresented: $showingSettings) {
            SettingsView(store: store)
        }
        .onChange(of: showingSettings) { _, isShowing in
            // Leaving Settings in Manual mode with no location picked would
            // leave the app without a position, so fall back to Auto.
            if !isShowing {
                store.revertToAutoIfManualLocationMissing()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            store.setAppIsActive(phase == .active)
        }
    }

    /// The station list owns the top edge in no-location mode so its
    /// transparent top inset scrolls underneath the native navigation bar.
    private var stationList: some View {
        GeometryReader { geometry in
            let gridWidth = max(0, geometry.size.width - Self.stationContentHorizontalInset * 2)
            let columns = stationColumns(for: gridWidth)

            ScrollView {
                VStack(spacing: 14) {
                    // The offline card already explains the state, so avoid
                    // showing a duplicate banner above it.
                    if !store.isNetworkAvailable && presentedCatalogStatus != .offline {
                        StatusBanner(
                            message: String(localized: "No internet connection"),
                            systemImage: "wifi.slash",
                            tint: .orange
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if let error = store.errorMessage {
                        StatusBanner(
                            message: error,
                            systemImage: "exclamationmark.triangle",
                            tint: .orange,
                            actionTitle: String(localized: "Retry"),
                            action: { store.refreshStations() }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    stationContent(columns: columns)
                }
                .padding(.horizontal, Self.stationContentHorizontalInset)

                // Keep a little breathing room below the final station box.
                Color.clear
                    .frame(height: 14)
            }
            // Keep a small inset so the first station's outline is not clipped.
            .contentMargins(.top, stationListTopInset, for: .scrollContent)
            .modifier(TopScrollEdgeEffect(hasLocationHeader: store.settings.showLocationHeader))
            .background {
                if store.settings.showLocationHeader {
                    Palette.background
                } else {
                    // Let the native soft scroll-edge blur show through in no-location mode.
                    Color.clear
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                    ZStack(alignment: .bottom) {
                    // The fade lives outside the player's slide/opacity
                    // transition: it is always present and only its opacity
                    // changes, with a short animation of its own, so it shows
                    // up together with the player's glass instead of trailing
                    // the transition's slower spring.
                    Color.clear
                        .frame(height: 0)
                        .background(alignment: .bottom) {
                            BottomEdgeFade(
                                bottomInset: bottomSafeInset,
                                playerDrop: Self.miniPlayerDrop,
                                playerHeight: miniPlayerHeight
                            )
                                .opacity(showsMiniPlayer ? 1 : 0)
                                .animation(.easeOut(duration: 0.18), value: showsMiniPlayer)
                        }
                    if showsMiniPlayer {
                        MiniPlayerView(store: store, player: player)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                miniPlayerHeight = $0
                            }
                            .padding(.horizontal, Self.miniPlayerHorizontalInset)
                            // Sits slightly below the safe-area edge, nearer
                            // the home indicator.
                            .padding(.bottom, -Self.miniPlayerDrop)
                            .transition(
                                .asymmetric(
                                    insertion: .offset(x: 0, y: 140).combined(with: .opacity),
                                    removal: .move(edge: .bottom).combined(with: .opacity)
                                )
                            )
                            // Its container ignores the keyboard safe area,
                            // keeping the player anchored to its normal position.
                    }
                    }
                }
                .animation(.spring(response: 0.52, dampingFraction: 0.86), value: showsMiniPlayer)
                .scrollDismissesKeyboard(.interactively)
                .animation(.snappy(duration: 0.24), value: store.isNetworkAvailable)
                .animation(.snappy(duration: 0.24), value: store.errorMessage)
        }
    }

    /// Shows or hides the catalog card to match the store. A download only
    /// gets the card if it is still running after a short moment, so on a fast
    /// connection the list simply appears without a flash of the card.
    @MainActor
    private func syncCatalogStatus() async {
        guard let status = store.catalogStatus else {
            withAnimation(.easeOut(duration: 0.2)) { presentedCatalogStatus = nil }
            return
        }
        if status == .downloading && presentedCatalogStatus == nil {
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
        }
        withAnimation(.easeOut(duration: 0.2)) { presentedCatalogStatus = status }
    }

    /// Shows the location label when location display is enabled.
    private var headerSection: some View {
        VStack(spacing: 0) {
            if showsLocationHeader {
                locationHeader
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // Native toolbar states (including the location-mode search field) and
        // the city label share one bottom gap. Floating search adds its own.
        .padding(.bottom, Self.stationSpacing)
        .background {
            if store.settings.showLocationHeader {
                (colorScheme == .light ? Palette.background : Color.black).ignoresSafeArea(edges: .top)
            }
        }
    }

    // Native toolbar Button at the original top-left position. It swaps the
    // location header for the search field at the top.
    private var searchToolbarButton: some View {
        Button {
            openSearch()
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(colorScheme == .light ? Color.black : Color.white)
        }
        .accessibilityLabel("Search stations…")
    }

    private func openSearch() {
        // Ignore repeated taps during activation. The toolbar stays mounted,
        // so reopening the same state must not restart its animation.
        guard !searchIsActive else { return }

        withAnimation(Self.searchAnimation) {
            searchIsActive = true
        }
        // Focus immediately; the toolbar hierarchy and Close hit target do
        // not change when the keyboard is presented.
        searchFocused = true
    }

    private func closeSearch() {
        guard searchIsActive else { return }
        searchFocused = false
        withAnimation(Self.searchAnimation) {
            searchIsActive = false
        }
        store.searchText = ""
    }

    /// Search capsule shared by the toolbar's Liquid Glass container.
    private var stationSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search stations…", text: $store.searchText)
                .focused($searchFocused)
                .onAppear { searchFocused = true }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !store.searchText.isEmpty {
                Button { store.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: Self.toolbarControlHeight)
        .contentShape(Capsule())
        .onqaGlass(Capsule(), interactive: true)
        .glassEffectID("station-search-field", in: searchGlassNamespace)
    }

    /// Field and Cancel share one glass container, so their surfaces blend
    /// when pressed or dragged close together. The field takes all the width
    /// left of Cancel.
    private var searchRow: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                stationSearchField
                closeSearchButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .frame(height: Self.toolbarControlHeight + 12)
        .background {
            if store.settings.showLocationHeader {
                (colorScheme == .light ? Palette.background : Color.black)
            }
        }
    }

    private var closeSearchButton: some View {
        Button(action: closeSearch) {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(colorScheme == .light ? Color.black : Color.white)
                .frame(width: Self.toolbarControlHeight, height: Self.toolbarControlHeight)
        }
        // Keep a full, stable 44pt hit target on the button itself rather
        // than relying on the changing outline of its animated glass surface.
        .frame(width: Self.toolbarControlHeight, height: Self.toolbarControlHeight)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .onqaGlass(Capsule(), interactive: true)
        .glassEffectID("station-search-close", in: searchGlassNamespace)
        .zIndex(1)
        .accessibilityLabel("Close search")
    }

    @ToolbarContentBuilder
    private var leadingToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            searchToolbarButton
        }
    }

    private var settingsToolbarButton: some View {
        Button {
            showingSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(colorScheme == .light ? Color.black : Color.white)
        }
        .accessibilityLabel("Settings")
    }

    @ToolbarContentBuilder
    private var trailingToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            settingsToolbarButton
        }
    }

    private var locationHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            if !store.isLocationPending {
                Text(store.locationFlag)
                    .font(.system(size: headerFlagSize))
                    .frame(height: headerRowHeight, alignment: .center)
            }
            if store.isLocationPending {
                // Native spinner while the location or city name is still
                // being retrieved; "Unknown location" appears only if the
                // lookup finished without a result.
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(accent)
                    .frame(height: headerRowHeight)
            } else {
                Text(store.locationLabel)
                    .font(.system(size: headerTitleSize, weight: .bold))
                    .foregroundStyle(colorScheme == .light ? Color.black : Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 16)
        .padding(.top, 2)
    }

    @ViewBuilder
    private func stationContent(columns: [GridItem]) -> some View {
        let visibleStations = store.displayedStations
        if let status = presentedCatalogStatus {
            // Takes the place of the loading spinner and the "No stations
            // found" card while the catalog is downloaded (or cannot be).
            CatalogStatusView(status: status, onRetry: { store.refreshStations() })
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        } else if store.settings.locationSource == .gps && store.locationCoordinate == nil {
            // The catalog is already cached on later launches, so there is no
            // download card to show. Keep the content area useful while GPS
            // resolves instead of leaving a black, empty screen.
            LocationLoadingView()
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        } else if store.isLoading && store.stations.isEmpty {
            ProgressView("Loading local radio stations…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 54)
                .transition(.opacity)
        } else if visibleStations.isEmpty {
            EmptyStationsView()
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        } else {
            LazyVGrid(columns: columns, spacing: Self.stationSpacing) {
                ForEach(visibleStations) { station in
                    StationCardView(
                        station: station,
                        isActive: player.currentStation?.id == station.id,
                        isPlaying: player.currentStation?.id == station.id && player.isPlaying,
                        distanceUnit: distanceUnit,
                        accent: accent,
                        onPlay: { store.play(station) },
                        onFavorite: {
                            // The context menu keeps the pressed card pinned
                            // at its old slot until its dismiss animation
                            // ends. Re-sorting during that window made the
                            // card jump instead of slide, so wait for the
                            // menu to finish first.
                            Task { @MainActor in
                                try? await Task.sleep(for: Self.favoriteMenuDismissDelay)
                                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                                    store.toggleFavorite(station)
                                }
                            }
                        }
                    )
                    .equatable()
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .animation(.snappy(duration: 0.28), value: visibleStations.map(\.id))
        }
    }
}
