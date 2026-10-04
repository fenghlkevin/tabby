import AppKit
import XCTest
@testable import TabbyNative

final class ApplicationIconTests: XCTestCase {
    @MainActor func testValidBundleRendersBrandedIconAtDockSizes() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Axon icon fixture.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(at: project.appendingPathComponent("Branding/AppIcon.icns"), to: resources.appendingPathComponent("AppIcon.icns"))
        let executable = app.appendingPathComponent("Contents/MacOS/Fixture")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        // XCTest's bundle executable is MH_BUNDLE, not an application. Using
        // that file makes IconServices draw a prohibited badge over the icon.
        // The executable target is built beside the test bundle; copy it only,
        // without launching it or touching the installed application.
        let product = Bundle(for: ApplicationIconTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("TabbyNative")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: product.path), "Expected the executable target beside the test bundle")
        let header = try Data(contentsOf: product).prefix(16)
        XCTAssertEqual(Array(header.prefix(4)), [0xCF, 0xFA, 0xED, 0xFE], "Expected a native 64-bit Mach-O executable")
        XCTAssertEqual(Array(header.dropFirst(12)), [2, 0, 0, 0], "An app icon fixture requires MH_EXECUTE, not XCTest's MH_BUNDLE")
        try FileManager.default.copyItem(at: product, to: executable)
        let info: [String: Any] = ["CFBundleName": "Axon icon fixture", "CFBundleIdentifier": "org.tabby.native.icon-fixture." + root.lastPathComponent.lowercased(), "CFBundlePackageType": "APPL", "CFBundleExecutable": "Fixture", "CFBundleIconFile": "AppIcon", "LSMinimumSystemVersion": "15.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let system = NSWorkspace.shared.icon(forFile: app.path)
        for size in [32, 64, 128, 256] {
            let systemImage = try raster(system, size: size)
            let pixels = try XCTUnwrap(NSBitmapImageRep(data: systemImage))
            let hasAxonAccent = (0..<size).contains { x in (0..<size).contains { y in
                guard let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return color.alphaComponent > 0.8 && color.redComponent > 0.8 && color.greenComponent > 0.4 && color.greenComponent < 0.85 && color.blueComponent < 0.4
            } }
            XCTAssertTrue(hasAxonAccent, "Expected the branded icon, not a generic application image")
            try capture(systemImage, named: "icon-system-\(size)")
        }
    }

    @MainActor private func raster(_ image: NSImage, size: Int) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func capture(_ data: Data, named name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] else { return }
        let destination = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try data.write(to: destination.appendingPathComponent(name + ".png"))
    }
}
