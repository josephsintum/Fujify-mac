import SwiftUI

/// Settings window, reachable via ⌘, or Fujify ▸ Settings…
///
/// Three toolbar tabs, the standard macOS shape. There is no theme control:
/// appearance follows System Settings, as it does in every native app.
struct SettingsView: View {
    /// Lets the converter banner and the Inspector's "Set Up Converter…"
    /// open this window on the right tab.
    @SceneStorage("settingsTab") private var selectedTab: Tab = .general

    enum Tab: String {
        case general, cameras, converter
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)

            CamerasSettings()
                .tabItem { Label("Cameras", systemImage: "camera") }
                .tag(Tab.cameras)

            ConverterSettings()
                .tabItem { Label("Converter", systemImage: "arrow.left.arrow.right") }
                .tag(Tab.converter)
        }
        .frame(width: 560, height: 480)
    }
}
