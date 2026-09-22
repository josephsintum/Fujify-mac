import SwiftUI

/// Which Settings tab is showing.
///
/// Lives outside `SettingsView` so the views that send people to Settings
/// can choose the tab before the window opens.
enum SettingsTab: String {
    case general, cameras, converter

    static let storageKey = "settingsTab"
}

/// Opens Settings on a particular tab.
///
/// `SettingsLink` takes no action, so it cannot set the tab first; this
/// pairs the write with `openSettings`. Without it "Set Up Converter…"
/// opened on General, which has no converter controls on it.
struct SettingsButton: View {
    let title: String
    let tab: SettingsTab

    @AppStorage(SettingsTab.storageKey) private var selectedTab: SettingsTab = .general
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(title) {
            selectedTab = tab
            openSettings()
        }
    }
}
