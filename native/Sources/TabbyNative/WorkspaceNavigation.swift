import AppKit
import SwiftUI

/// The main workspace and settings use the same native row control. Settings
/// replaces the content of this sidebar, rather than adding another column.
struct WorkspaceNavigation: View {
    @EnvironmentObject var store: AppStore
    @Binding var settingsPage: PreferencesPage
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.section == "settings" {
                PreferencesNavigationButton(title: store.text("Back to workspace", "返回工作区"), symbol: "chevron.left", selected: false, identifier: "axon-settings-back") { store.section = "hosts" }.frame(height: 44)
                Text(store.text("Settings", "设置")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted).padding(.horizontal, 12).padding(.vertical, 6)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(PreferencesPage.allCases) { item in
                            PreferencesNavigationButton(title: item.title(chinese: store.chinese), symbol: item.icon, selected: settingsPage == item, identifier: "axon-preferences-page-" + item.rawValue) { settingsPage = item }.frame(height: 44)
                        }
                    }
                }
            } else {
                HStack(spacing: 8) { Image(systemName: "lock.shield"); Text(store.text("Local workspace", "本地工作区")); Spacer(minLength: 0) }.font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted).padding(.horizontal, 12).frame(height: 44)
                ScrollView {
                    VStack(spacing: 4) {
                        item("hosts", symbol: "server.rack", title: store.text("Hosts", "主机"))
                        item("monitoring", symbol: "waveform.path.ecg", title: store.text("Monitoring", "监控"))
                        item("credentials", symbol: "key.fill", title: store.text("Keychain", "凭据库"))
                        item("forwards", symbol: "arrow.left.arrow.right", title: store.text("Port forwarding", "端口转发"))
                        item("snippets", symbol: "curlybraces", title: store.text("Snippets", "代码片段"))
                        item("known", symbol: "checkmark.shield", title: store.text("Known hosts", "已知主机"))
                        item("logs", symbol: "clock.arrow.circlepath", title: store.text("Logs", "日志"))
                    }
                }
                item("settings", symbol: "gearshape", title: store.text("Settings", "设置"))
            }
        }.accessibilityElement(children: .contain).accessibilityLabel(store.text("Workspace navigation", "工作区导航"))
    }
    private func item(_ id: String, symbol: String, title: String) -> some View {
        PreferencesNavigationButton(title: title, symbol: symbol, selected: store.section == id, identifier: "axon-navigation-" + id) { store.section = id }.frame(height: 44)
    }
}

@MainActor extension AppStore {
    func openPreferences(_ page: PreferencesPage? = nil) {
        if let page { settingsPage = page }
        section = "settings"
    }
}
