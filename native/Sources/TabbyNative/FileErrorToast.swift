import SwiftUI

struct FilePaneErrorOverlay: ViewModifier {
    @EnvironmentObject var store: AppStore
    @ObservedObject var pane: FilePane
    let width: CGFloat

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if let error = pane.error {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.text("File operation failed", "文件操作失败")).font(.system(size: 12, weight: .semibold))
                        // The hidden text sizes short messages naturally; long
                        // messages scroll within a bounded, clickable toast.
                        errorText(error).hidden().frame(maxWidth: .infinity, alignment: .leading)
                            .frame(maxHeight: 120).fixedSize(horizontal: false, vertical: true)
                            .overlay(alignment: .topLeading) {
                                ScrollView(.vertical) { errorText(error).frame(maxWidth: .infinity, alignment: .leading) }
                            }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button { pane.error = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(Palette.muted)
                        .help(store.text("Dismiss notification", "关闭提示"))
                        .accessibilityLabel(store.text("Dismiss notification", "关闭提示"))
                        .accessibilityIdentifier("file-error-dismiss")
                }.foregroundStyle(Palette.text).padding(12)
                    .frame(width: max(0, min(380, width - 24)))
                    .background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.red.opacity(0.25), lineWidth: 1))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    .padding(.trailing, 12).padding(.bottom, 44)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("file-error-toast")
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: pane.error != nil)
        .task(id: pane.errorID) {
            guard pane.error != nil else { return }
            let notificationID = pane.errorID
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard !Task.isCancelled, pane.errorID == notificationID else { return }
            pane.error = nil
        }
    }

    private func errorText(_ error: String) -> some View {
        Text(message(error)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func message(_ error: String) -> String {
        switch error {
        case "Cannot copy an item onto itself": return store.text(error, "不能将文件或文件夹复制到自身。")
        case "Cannot copy a folder into its own subfolder": return store.text(error, "不能将文件夹复制到它自己的子目录中。")
        default: return error
        }
    }
}
