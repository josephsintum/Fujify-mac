import SwiftUI

@main
struct FujifyApp: App {
    @State private var toolLocator: ToolLocator
    @State private var pipeline: Pipeline
    @State private var showToolSetup = false

    init() {
        let locator = ToolLocator()
        _toolLocator = State(initialValue: locator)
        _pipeline = State(initialValue: Pipeline(toolLocator: locator))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(showToolSetup: $showToolSetup)
                .environment(toolLocator)
                .environment(pipeline)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Set up RAW Converter…") {
                    showToolSetup = true
                }
            }
        }

        Settings {
            SettingsView()
                .environment(toolLocator)
                .environment(pipeline)
        }
    }
}
