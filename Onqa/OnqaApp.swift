import SwiftUI

@main
struct OnqaApp: App {

    @State private var store = RadioStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
    }
}
