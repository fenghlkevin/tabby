import AppKit
import Darwin
import CoreServices

@MainActor enum ApplicationIconAppearance {
    nonisolated static let styles = ["black", "white"]
    private static var images: [String: NSImage] = [:]

    static func image(for style: String) -> NSImage? {
        let style = style == "white" ? "white" : "black"
        if let image = images[style] { return image }
        let name = style == "white" ? "AppIconWhite" : "AppIconBlack"
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Branding")
        let url = Bundle.main.url(forResource: name, withExtension: "icns") ?? source.appendingPathComponent(style == "white" ? "AppIconWhite.icns" : "AppIcon.icns")
        guard let image = NSImage(contentsOf: url) else { return nil }
        images[style] = image
        return image
    }
}

/// Finder custom icons live outside the signed Contents directory. Using the
/// file's system-rendered image for the running Dock keeps both states aligned.
/// Both choices use this path, avoiding macOS's smaller bundled-icon inset.
/// The packaged default remains black; installation restores the saved choice.
@MainActor final class ApplicationIconController {
    let bundleURL: URL
    private let updateRunningIcon: (NSImage) -> Void

    init(bundleURL: URL, updateRunningIcon: @escaping (NSImage) -> Void) {
        self.bundleURL = bundleURL
        self.updateRunningIcon = updateRunningIcon
    }

    static func production() -> ApplicationIconController? {
        guard Bundle.main.bundleIdentifier == "org.tabby.native", Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return ApplicationIconController(bundleURL: Bundle.main.bundleURL) { NSApp.applicationIconImage = $0 }
    }

    static func hasCustomIcon(at url: URL) -> Bool {
        var info = [UInt8](repeating: 0, count: 32)
        let count = info.withUnsafeMutableBytes { getxattr(url.path, "com.apple.FinderInfo", $0.baseAddress, $0.count, 0, 0) }
        // Finder's big-endian kHasCustomIcon flag is 0x0400 at offset eight.
        return count == 32 && info[8] & 0x04 != 0
    }

    private static func customIconImage(at url: URL) -> NSImage? {
        // Keep the original ICNS representations for rollback. Rasterizing
        // the effective system icon a second time changes small-size pixels.
        let path = url.appendingPathComponent("Icon\r").path
        let size = getxattr(path, "com.apple.ResourceFork", nil, 0, 0, 0)
        guard (8...16_777_216).contains(size) else { return nil }
        var data = Data(count: size)
        let count = data.withUnsafeMutableBytes { getxattr(path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0) }
        guard count == size, let header = data.range(of: Data("icns".utf8)), header.lowerBound + 8 <= count else { return nil }
        let start = header.lowerBound
        let length = data[(start + 4)..<(start + 8)].reduce(0) { ($0 << 8) | Int($1) }
        guard length >= 8, length <= count - start else { return nil }
        return NSImage(data: data[start..<(start + length)])
    }

    func prepare(_ style: String, chinese: Bool) throws -> Change {
        guard ApplicationIconAppearance.styles.contains(style),
              let image = NSImage(contentsOf: bundleURL.appendingPathComponent("Contents/Resources/" + (style == "white" ? "AppIconWhite.icns" : "AppIconBlack.icns"))) else {
            throw AppFailure.message(chinese ? "找不到应用图标资源，请重新安装 Axon。" : "App icon resources are missing. Reinstall Axon.")
        }
        let previous = Self.hasCustomIcon(at: bundleURL)
            ? Self.customIconImage(at: bundleURL) ?? NSWorkspace.shared.icon(forFile: bundleURL.path) : nil
        if !NSWorkspace.shared.setIcon(image, forFile: bundleURL.path, options: []) {
            throw AppFailure.message(chinese ? "无法更新程序图标，请将 Axon 放在可写的应用程序目录后重试。" : "Could not update the app icon. Move Axon to a writable Applications folder and retry.")
        }
        return Change(controller: self, previous: previous)
    }

    @MainActor struct Change {
        fileprivate let controller: ApplicationIconController
        fileprivate let previous: NSImage?

        func commit() {
            LSRegisterURL(controller.bundleURL as CFURL, true)
            NSWorkspace.shared.noteFileSystemChanged(controller.bundleURL.path)
            controller.updateRunningIcon(NSWorkspace.shared.icon(forFile: controller.bundleURL.path))
        }

        @discardableResult func rollback() -> Bool {
            NSWorkspace.shared.setIcon(previous, forFile: controller.bundleURL.path, options: [])
        }
    }
}
