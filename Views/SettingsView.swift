import SwiftUI

/// Settings window, reachable via ⌘, or Fujify ▸ Settings…
///
/// Three toolbar tabs, the standard macOS shape. There is no theme control:
/// appearance follows System Settings, as it does in every native app.
struct SettingsView: View {
    /// Lets the converter banner and the Inspector's "Set Up Converter…"
    /// open this window on the right tab.
    ///
    /// @AppStorage rather than @SceneStorage: scene storage is private to
    /// the window that declares it, so nothing outside this view could ever
    /// write it and the promise above was not kept — "Set Up Converter…"
    /// landed on General, which has no converter controls.
    @AppStorage(SettingsTab.storageKey) private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            CamerasSettings()
                .tabItem { Label("Cameras", systemImage: "camera") }
                .tag(SettingsTab.cameras)

            ConverterSettings()
                .tabItem { Label("Converter", systemImage: "arrow.left.arrow.right") }
                .tag(SettingsTab.converter)
        }
        .frame(width: 560, height: 480)
    }
}
