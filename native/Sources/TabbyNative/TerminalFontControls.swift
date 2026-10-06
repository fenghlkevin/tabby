import SwiftUI

@MainActor extension AppStore {
    var fontAdjustmentSession: TerminalSession? {
        guard section == "terminal" || section == "scene" && currentScene?.mode == "terminal" else { return nil }
        return sessions.first { $0.id == activeSession }
    }
}

struct TerminalFontControls: View {
    @ObservedObject var session: TerminalSession
    private var store: AppStore { session.store }
    var body: some View {
        HStack(spacing: 0) {
            Button { session.adjustFontSize(-1) } label: { Image(systemName: "minus").frame(width: 26, height: 28) }
                .disabled(session.effectiveFontSize <= 10)
                .help(store.text("Decrease this terminal's font size", "缩小此终端字号"))
                .accessibilityLabel(store.text("Decrease font size", "缩小字号"))
                .accessibilityIdentifier("axon-font-decrease-" + session.id.uuidString)
            Button { session.setFontSize(nil) } label: {
                Text(TerminalFontSizeNativeEditor.display(session.effectiveFontSize)).monospacedDigit().frame(minWidth: 28, minHeight: 28)
            }.help(store.text("Reset to default font size", "恢复默认字号"))
                .accessibilityLabel(store.text("Reset font size", "恢复默认字号"))
                .accessibilityIdentifier("axon-font-reset-" + session.id.uuidString)
            Button { session.adjustFontSize(1) } label: { Image(systemName: "plus").frame(width: 26, height: 28) }
                .disabled(session.effectiveFontSize >= 40)
                .help(store.text("Increase this terminal's font size", "放大此终端字号"))
                .accessibilityLabel(store.text("Increase font size", "放大字号"))
                .accessibilityIdentifier("axon-font-increase-" + session.id.uuidString)
        }.font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.chromeText)
            .buttonStyle(AxonSurfaceButtonStyle())
    }
}
