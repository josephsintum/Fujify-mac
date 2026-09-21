import SwiftUI

@main
struct FujifyApp: App {
    @State private var toolLocator: ToolLocator
    @State private var cameraStore: CameraStore
    @State private var pipeline: Pipeline

    init() {
        let locator = ToolLocator()
        _toolLocator = State(initialValue: locator)
        _cameraStore = State(initialValue: CameraStore())
        _pipeline = State(initialValue: Pipeline(toolLocator: locator))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(toolLocator)
                .environment(cameraStore)
                .environment(pipeline)
                .task {
                    // Probing runs each tool to read its version, so it is
                    // async and happens once the window is up rather than
                    // blocking launch.
                    await toolLocator.probe()
                    pipeline.refreshConverterAvailability()
                }
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(toolLocator)
                .environment(cameraStore)
                .environment(pipeline)
        }
    }
}
