import SwiftUI

@main
struct OnqaApp: App {
    // Owned here so the store (audio player, network monitor) is created once
    // for the app's lifetime rather than whenever a view struct is re-created.
    @State private var store = RadioStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
    }
}
