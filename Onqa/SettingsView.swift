import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Presents playback, appearance, location, and catalog preferences, plus saved-favorites tools.
struct SettingsView: View {
    @Bindable var store: RadioStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var exportDocument: FavoritesExportDocument?
    @State private var feedbackMessage: String?

    private var accent: Color { store.settings.accent.swiftUIColor }

    var body: some View {
        Form {
            locationSection
            interfaceSection
            audioSection
            databaseSection
            dataSection
            appearanceSection
        }
         
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
         
        .toolbar(.visible, for: .navigationBar)
        .alert("Location", isPresented: $store.shouldShowLocationSettingsPrompt) {
            Button("Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            Button("Cancel", role: .cancel) {
                store.cancelPendingLocationSourceSelection()
            }
        } message: {
            Text("Without location access, you can use Manual mode only. Choose your location in Settings.")
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument ?? FavoritesExportDocument(data: Data()),
            contentType: .json,
            defaultFilename: "onqa-favorites"
        ) { result in
            if case .failure(let error) = result {
                feedbackMessage = String(localized: "Export failed: \(error.localizedDescription)")
            } else {
                feedbackMessage = String(localized: "Favorites exported.")
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                try store.importFavorites(from: Data(contentsOf: url))
                feedbackMessage = String(localized: "Favorites imported.")
            } catch {
                feedbackMessage = String(localized: "Import failed: \(error.localizedDescription)")
            }
        }
    }

     

    private var locationSection: some View {
        Section {
            Picker("Location source", selection: Binding(
                get: { store.settings.locationSource },
                set: { store.selectLocationSource($0) }
            )) {
                ForEach(LocationSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.segmented)

            if store.settings.locationSource == .manual {
                NavigationLink {
                    MapLocationPickerView(store: store)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Pick location on map")
                         
                         
                        if store.settings.manualLatitude != nil {
                            Text(store.locationLabel)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("Location")
        } footer: {
            if store.hasLocationAccess {
                Text("Choose how the app gets your position")
            } else {
                Text("Auto mode requires location access. Choose a location manually to use the app without it.")
            }
        }
    }

    private var interfaceSection: some View {
        Section {
            Toggle("Show current location", isOn: settingBinding(\.showLocationHeader))
        } header: {
            Text("UI elements")
        } footer: {
            Text("Display location info in the top bar")
        }
    }

    private var audioSection: some View {
        Section {
            Toggle("HQ streams", isOn: settingBinding(\.useHQStream))
        } header: {
            Text("Audio")
        } footer: {
            Text("Prefer HQ streams when available\n(≥192kbps)")
        }
    }

    private var databaseSection: some View {
        Section {
            Picker("Catalog update frequency", selection: settingBinding(\.catalogUpdateFrequency)) {
                ForEach(CatalogUpdateFrequency.allCases) { frequency in
                    Text(frequency.title).tag(frequency)
                }
            }
            .pickerStyle(.segmented)
            .tint(accent)

            Button {
                store.updateCatalogNow()
            } label: {
                HStack {
                    Text("Update database now")
                    Spacer()
                    if store.isDownloadingCatalog {
                        ProgressView()
                    }
                }
            }
            .disabled(store.isDownloadingCatalog)
        } header: {
            Text("Database")
        } footer: {
            if let lastUpdatedText {
                Text(lastUpdatedText)
            } else {
                Text("Choose how often the station database is updated")
            }
        }
    }

    private var dataSection: some View {
        Section {
            Button {
                exportDocument = FavoritesExportDocument(data: store.favoritesBackupData())
                showingExporter = true
            } label: {
                Label("Export favorite stations", systemImage: "square.and.arrow.up")
            }

            Button {
                showingImporter = true
            } label: {
                Label("Import favorite stations", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("Data & Backup")
        } footer: {
            if let feedbackMessage {
                Text(feedbackMessage)
            } else {
                Text("Save your favorite stations to a JSON file")
            }
        }
    }

    private var appearanceSection: some View {
        Section {
            Picker("Theme", selection: settingBinding(\.theme)) {
                ForEach(OnqaTheme.allCases) { theme in
                    Text(theme.title).tag(theme)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Accent color")
                Spacer()
                HStack(spacing: 14) {
                    ForEach(OnqaAccent.allCases) { option in
                        Button {
                            store.setAccent(option)
                        } label: {
                            Circle()
                                .fill(option.swiftUIColor)
                                .frame(width: 28, height: 28)
                                .overlay {
                                    if store.settings.accent == option {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 12, weight: .black))
                                            .foregroundStyle(colorScheme == .light ? Color.white : Color.black.opacity(0.75))
                                    }
                                }
                                .padding(3)
                                .overlay {
                                    if store.settings.accent == option {
                                        Circle().stroke(Color.primary.opacity(0.7), lineWidth: 2)
                                    }
                                }
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(option.title)
                    }
                }
            }
        } header: {
            Text("Appearance")
        }
    }

     

    private var lastUpdatedText: String? {
        guard let date = store.settings.lastCatalogUpdate else { return nil }
        let formatted = date.formatted(date: .numeric, time: .shortened)
        return String(localized: "Last updated: \(formatted)")
    }

    private func settingBinding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { newValue in
                var settings = store.settings
                settings[keyPath: keyPath] = newValue
                store.settings = settings
            }
        )
    }
}

struct FavoritesExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
