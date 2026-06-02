import SwiftUI

@main
struct FujifyApp: App {
    @State private var showToolSetup = false

    var body: some Scene {
        WindowGroup {
            ContentView(showToolSetup: $showToolSetup)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Set up RAW Converter…") {
                    showToolSetup = true
                }
            }
        }
    }
}
