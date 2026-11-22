import SwiftUI
import MapKit
import UIKit
import Observation

// MARK: - Map picker

/// A displayable MapKit city-search result. The completion is retained for
/// the follow-up local search, while the strings keep the observable state easy
/// to test without manufacturing MapKit-owned completion objects.
struct CitySearchResult: Identifiable {
    let title: String
    let subtitle: String
    let completion: MKLocalSearchCompletion?

    var id: String { "\(title)|\(subtitle)" }

    init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
        self.completion = nil
    }

    init(completion: MKLocalSearchCompletion) {
        self.title = completion.title
        self.subtitle = completion.subtitle
        self.completion = completion
    }
}

/// Live city/address suggestions from MapKit's search completer.
@MainActor
@Observable
final class CitySearchModel {
    private(set) var results: [CitySearchResult] = []
    @ObservationIgnored private let completer: MKLocalSearchCompleter
    @ObservationIgnored private let delegate: CitySearchCompleterDelegate

    init() {
        let completer = MKLocalSearchCompleter()
        let delegate = CitySearchCompleterDelegate()
        self.completer = completer
        self.delegate = delegate
        delegate.owner = self
        completer.delegate = delegate
        completer.resultTypes = [.address]
    }

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            setResults([])
        }
        completer.queryFragment = trimmed
    }

    /// Publishes the latest results as one observable state change. Kept
    /// separate from MapKit's delegate so the result-update path is testable.
    func setResults(_ results: [CitySearchResult]) {
        self.results = results
    }

    fileprivate func receiveResults(from completer: MKLocalSearchCompleter) {
        let results = completer.queryFragment.isEmpty
            ? []
            : completer.results.map(CitySearchResult.init(completion:))
        setResults(results)
    }
}

/// MapKit requires an NSObject delegate. Keeping that adapter separate means
/// the observable model itself doesn't inherit NSObject.
@MainActor
private final class CitySearchCompleterDelegate: NSObject, @MainActor MKLocalSearchCompleterDelegate {
    weak var owner: CitySearchModel?

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        owner?.receiveResults(from: completer)
    }
}

private struct MapPinTail: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

struct MapLocationPickerView: View {
    let store: RadioStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let requiresOnboardingConfirmation: Bool
    private let initialCoordinate: CLLocationCoordinate2D
    @State private var hasSelectedLocation = false
    @State private var position: MapCameraPosition
    @State private var center: CLLocationCoordinate2D
    @State private var searchText = ""
    @State private var searchSelectionRequestID = 0
    @State private var citySearchPresented = false
    @State private var citySearch = CitySearchModel()

    init(store: RadioStore, requiresOnboardingConfirmation: Bool = false) {
        self.store = store
        self.requiresOnboardingConfirmation = requiresOnboardingConfirmation
        let coordinate = store.locationCoordinate
            ?? CLLocationCoordinate2D(latitude: 52.0, longitude: 20.0)
        initialCoordinate = coordinate
        _center = State(initialValue: coordinate)
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.22, longitudeDelta: 0.22)
        )))
    }

    var body: some View {
        Map(position: $position)
        // Publish the camera center once a gesture/animation settles. Updating
        // SwiftUI state for every camera frame causes needless map re-layout
        // while panning and during keyboard transitions.
        .onMapCameraChange(frequency: .onEnd) { context in
            let updatedCenter = context.region.center
            center = updatedCenter

            if requiresOnboardingConfirmation,
               StationProcessor.distanceKm(
                   from: initialCoordinate.latitude,
                   longitude: initialCoordinate.longitude,
                   to: updatedCenter.latitude,
                   longitude: updatedCenter.longitude
               ) > 0.05 {
                hasSelectedLocation = true
            }
        }
        .overlay(alignment: .center) {
            // The pin tip stays at the exact center of the map viewport.
            ZStack(alignment: .top) {
                MapPinTail()
                    .fill(.red)
                    .frame(width: 14, height: 14)
                    .offset(y: 18)
                Circle()
                    .fill(.red)
                    .frame(width: 26, height: 26)
                    .overlay {
                        Circle().stroke(.white, lineWidth: 3)
                    }
            }
            .frame(width: 26, height: 32)
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            .offset(y: -16)
            .allowsHitTesting(false)
        }
        // Keep the map and its center pin at the full screen height while
        // the keyboard is visible. The system search field in the bottom
        // toolbar remains keyboard-aware on its own.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .overlay(alignment: .bottom) {
            if citySearchPresented,
               !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !citySearch.results.isEmpty {
                citySuggestionsPanel
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 16)
                    // Keep the card above the native bottom search/confirm toolbar.
                    .padding(.bottom, 76)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .searchable(
            text: $searchText,
            isPresented: $citySearchPresented,
            prompt: Text("Search city")
        )
        .textInputAutocapitalization(.words)
        .autocorrectionDisabled()
        .toolbar {
            // Native iOS 26 pattern: the system search field sits in the
            // bottom toolbar with the confirm button beside it.
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.fixed, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button {
                    citySearchPresented = false
                    store.setManualLocation(
                        center,
                        completesOnboarding: requiresOnboardingConfirmation
                    )
                    dismiss()
                } label: {
                    Image(systemName: "checkmark")
                }
                .accessibilityLabel("Confirm location")
                .accessibilityIdentifier("confirm-map-location")
                .disabled(requiresOnboardingConfirmation && !hasSelectedLocation)
            }
        }
        .navigationTitle("Pick location")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .navigationBarBackButtonHidden(requiresOnboardingConfirmation)
        .onChange(of: searchText) { _, query in
            searchSelectionRequestID &+= 1
            citySearch.update(query: query)
        }
        // Keep the navigation header in the hierarchy while the keyboard
        // opens; the search UI belongs to the bottom toolbar, not the header.
        .toolbarBackground(.regularMaterial, for: .navigationBar)
        .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        .animation(.snappy(duration: 0.24), value: citySearchPresented)
        .animation(.snappy(duration: 0.22), value: citySearch.results.map(\.id))
    }

    private var citySuggestionsPanel: some View {
        VStack(spacing: 0) {
            ForEach(Array(citySearch.results.prefix(5))) { result in
                Button {
                    Task { await select(result) }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        if !result.subtitle.isEmpty {
                            Text(result.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .fixedSize(horizontal: false, vertical: true)
        .onqaGlass(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityLabel("Location suggestions")
    }

    private func select(_ result: CitySearchResult) async {
        guard let completion = result.completion else { return }
        searchSelectionRequestID &+= 1
        let requestID = searchSelectionRequestID
        let request = MKLocalSearch.Request(completion: completion)
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first,
              searchSelectionRequestID == requestID else { return }
        // `MKMapItem.placemark` is deprecated in iOS 26; `location` replaces it.
        let coordinate = item.location.coordinate
        center = coordinate
        hasSelectedLocation = true
        searchText = ""

        // Retarget smoothly before dismissing the keyboard so the map settles
        // on the selected place without a viewport-driven jump.
        withAnimation(.smooth(duration: 0.45)) {
            recenterMap(on: coordinate)
        }
        citySearchPresented = false
    }

    private func recenterMap(on coordinate: CLLocationCoordinate2D) {
        center = coordinate
        position = .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.22, longitudeDelta: 0.22)
        ))
    }
}
