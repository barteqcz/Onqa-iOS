import SwiftUI
import MapKit
import UIKit
import Observation

private struct BottomEdgeFade: View {

    let bottomInset: CGFloat

    let playerDrop: CGFloat

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

            content
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        }
    }
}

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

/// Main listening screen: location context, station discovery, favorites, and the persistent mini-player.
struct RadioHomeView: View {
    @Bindable var store: RadioStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    @Environment(\.locale) private var locale

    @State private var searchIsActive = false
    @FocusState private var searchFocused: Bool
    @Namespace private var searchGlassNamespace
    @State private var showingSettings = false

    @State private var presentedCatalogStatus: CatalogStatus?

    @ScaledMetric(relativeTo: .title) private var headerFlagSize: CGFloat = 32
    @ScaledMetric(relativeTo: .title) private var headerTitleSize: CGFloat = 26
    @ScaledMetric(relativeTo: .title) private var headerRowHeight: CGFloat = 38
    @State private var bottomSafeInset: CGFloat = 0
    @State private var miniPlayerHeight: CGFloat = 88
    @State private var shouldFollowBottomWhenMiniPlayerAppears = false

    private static let miniPlayerDrop: CGFloat = 10

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

    private static let stationSpacing: CGFloat = 14
    private static let stationListBottomID = "station-list-bottom"
    private static let scrollBottomFollowTolerance: CGFloat = 48

    private static let stationListTopMargin: CGFloat = 5

    private static let toolbarControlHeight: CGFloat = 44

    private static let searchAnimation: Animation = .smooth(duration: 0.32)

    private static let favoriteMenuDismissDelay: Duration = .milliseconds(650)

    private static let stationMinimumWidth: CGFloat = 320
    private static let stationContentHorizontalInset: CGFloat = 16

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

                stationList
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if searchIsActive {
                searchRow
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }

        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: {
            bottomSafeInset = $0
        }

        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background {
            if store.settings.showLocationHeader {
                Palette.background.ignoresSafeArea()
            } else {

                Color.clear.ignoresSafeArea()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showsMiniPlayer)

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

            if !isShowing {
                store.revertToAutoIfManualLocationMissing()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            store.setAppIsActive(phase == .active)
        }
    }

    private var stationList: some View {
        GeometryReader { geometry in
            let gridWidth = max(0, geometry.size.width - Self.stationContentHorizontalInset * 2)
            let columns = stationColumns(for: gridWidth)

            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: Self.stationSpacing) {

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

                    .id(Self.stationListBottomID)
                }

                .contentMargins(.top, stationListTopInset, for: .scrollContent)
                .modifier(TopScrollEdgeEffect(hasLocationHeader: store.settings.showLocationHeader))
                .background {
                    if store.settings.showLocationHeader {
                        Palette.background
                    } else {

                        Color.clear
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ZStack(alignment: .bottom) {

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
                            VStack(spacing: 0) {

                                Color.clear
                                    .frame(height: Self.stationSpacing)

                                MiniPlayerView(store: store, player: player)
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                        miniPlayerHeight = $0
                                    }
                                    .padding(.horizontal, Self.miniPlayerHorizontalInset)

                                    .padding(.bottom, -Self.miniPlayerDrop)

                            }

                            .transition(
                                .asymmetric(
                                    insertion: .offset(x: 0, y: 140).combined(with: .opacity),
                                    removal: .move(edge: .bottom).combined(with: .opacity)
                                )
                            )
                        }
                    }
                }
                .animation(.spring(response: 0.52, dampingFraction: 0.86), value: showsMiniPlayer)
                .scrollDismissesKeyboard(.interactively)
                .animation(.snappy(duration: 0.24), value: store.isNetworkAvailable)
                .animation(.snappy(duration: 0.24), value: store.errorMessage)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    max(0, geometry.contentSize.height - geometry.visibleRect.maxY)
                        <= Self.scrollBottomFollowTolerance
                } action: { _, isAtBottom in

                    if !showsMiniPlayer {
                        shouldFollowBottomWhenMiniPlayerAppears = isAtBottom
                    }
                }
                .onChange(of: showsMiniPlayer) { wasShowing, isShowing in

                    guard
                        !wasShowing,
                        isShowing,
                        shouldFollowBottomWhenMiniPlayerAppears
                    else { return }

                    shouldFollowBottomWhenMiniPlayerAppears = false
                    Task { @MainActor in

                        try? await Task.sleep(for: .milliseconds(140))
                        guard showsMiniPlayer else { return }
                        withAnimation(.spring(response: 0.52, dampingFraction: 0.86)) {
                            scrollProxy.scrollTo(Self.stationListBottomID, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

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

    private var headerSection: some View {
        VStack(spacing: 0) {
            if showsLocationHeader {
                locationHeader
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }

        .padding(.bottom, Self.stationSpacing)
        .background {
            if store.settings.showLocationHeader {
                (colorScheme == .light ? Palette.background : Color.black).ignoresSafeArea(edges: .top)
            }
        }
    }

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

        guard !searchIsActive else { return }

        withAnimation(Self.searchAnimation) {
            searchIsActive = true
        }

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
        HStack(alignment: .center, spacing: 8) {
            if !store.isLocationPending {
                Text(store.locationFlag)
                    .font(.system(size: headerFlagSize))
                    .frame(height: headerRowHeight, alignment: .center)
            }
            if store.isLocationPending {

                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(accent)
                    .frame(height: headerRowHeight)
            } else {

                let label = store.locationLabel
                let retrievedAt = store.displayedLocationRetrievedAt
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(label)
                            .font(.system(size: headerTitleSize, weight: .bold))
                            .foregroundStyle(colorScheme == .light ? Color.black : Color.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                        let age = LocationAgePolicy.text(since: retrievedAt, now: context.date)
                        if let age {

                            Text(age)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .transition(.opacity.combined(with: .offset(y: 3)))
                        }
                    }
                    .animation(.easeInOut(duration: 0.22), value: LocationAgePolicy.text(
                        since: retrievedAt,
                        now: context.date
                    ) != nil)
                }
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

            CatalogStatusView(status: status, onRetry: { store.refreshStations() })
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        } else if store.settings.locationSource == .gps && store.locationCoordinate == nil {

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
