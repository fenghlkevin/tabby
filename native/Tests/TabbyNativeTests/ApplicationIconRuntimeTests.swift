import AppKit
import CryptoKit
import XCTest
@testable import TabbyNative

@MainActor final class ApplicationIconRuntimeTests: XCTestCase {
    func testBothIconChoicesUseTheSameSystemRenderingAndKeepBundleContentsUnchanged() throws {
        _ = NSApplication.shared
        let fixture = try makeFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let originalContents = try contentsFingerprint(fixture.app)
        let store = AppStore(fileURL: fixture.workspace)
        var updates: [NSImage] = []
        store.applicationIconController = ApplicationIconController(bundleURL: fixture.app) { updates.append($0) }
        XCTAssertFalse(ApplicationIconController.hasCustomIcon(at: fixture.app))

        var draft = store.workspace.preferences; draft.applicationIcon = "white"
        try store.commitPreferences(draft)
        XCTAssertEqual(store.workspace.preferences.applicationIcon, "white")
        XCTAssertEqual(try savedPreferences(fixture.workspace).applicationIcon, "white")
        XCTAssertTrue(ApplicationIconController.hasCustomIcon(at: fixture.app))
        XCTAssertEqual(updates.count, 1)
        try assertMatchesSystemIcon(try XCTUnwrap(updates.last), app: fixture.app)
        try assertIconStyle(try XCTUnwrap(updates.last), white: true)
        XCTAssertEqual(try contentsFingerprint(fixture.app), originalContents)

        // An upgrade can replace the bundle and remove Finder's custom icon.
        // Startup must restore the user's saved choice without rewriting config.
        XCTAssertTrue(NSWorkspace.shared.setIcon(nil, forFile: fixture.app.path, options: []))
        XCTAssertFalse(ApplicationIconController.hasCustomIcon(at: fixture.app))
        let savedBytes = try Data(contentsOf: fixture.workspace)
        let restarted = AppStore(fileURL: fixture.workspace)
        var restartUpdates: [NSImage] = []
        restarted.applicationIconController = ApplicationIconController(bundleURL: fixture.app) { restartUpdates.append($0) }
        XCTAssertEqual(restarted.workspace.preferences.applicationIcon, "white")
        restarted.applyApplicationIconAtLaunch()
        XCTAssertNil(restarted.error)
        XCTAssertTrue(ApplicationIconController.hasCustomIcon(at: fixture.app))
        XCTAssertEqual(restartUpdates.count, 1)
        try assertMatchesSystemIcon(try XCTUnwrap(restartUpdates.last), app: fixture.app)
        XCTAssertEqual(try Data(contentsOf: fixture.workspace), savedBytes, "Startup restores icon metadata without saving the workspace")

        draft = restarted.workspace.preferences; draft.applicationIcon = "black"
        try restarted.commitPreferences(draft)
        XCTAssertTrue(ApplicationIconController.hasCustomIcon(at: fixture.app), "Both choices use custom icons to avoid different system scaling")
        XCTAssertEqual(try savedPreferences(fixture.workspace).applicationIcon, "black")
        XCTAssertEqual(restartUpdates.count, 2)
        try assertMatchesSystemIcon(try XCTUnwrap(restartUpdates.last), app: fixture.app)
        try assertIconStyle(try XCTUnwrap(restartUpdates.last), white: false)
        XCTAssertEqual(try contentsFingerprint(fixture.app), originalContents, "Icon choice must never rewrite signed Contents files")
    }

    func testFailedWorkspaceSaveRollsBackFileIconAndDoesNotUpdateRunningIcon() throws {
        _ = NSApplication.shared
        let fixture = try makeFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let originalContents = try contentsFingerprint(fixture.app)
        let blocker = fixture.directory.appendingPathComponent("not-a-directory")
        let blockerBytes = Data("workspace-write-blocker".utf8); try blockerBytes.write(to: blocker)
        let store = AppStore(fileURL: blocker.appendingPathComponent("workspace.json"))
        let original = store.workspace.preferences
        var updates = 0
        store.applicationIconController = ApplicationIconController(bundleURL: fixture.app) { _ in updates += 1 }
        var draft = original; draft.applicationIcon = "white"
        XCTAssertThrowsError(try store.commitPreferences(draft))
        XCTAssertEqual(store.workspace.preferences, original)
        XCTAssertEqual(updates, 0, "A failed save must not change the running Dock icon")
        XCTAssertFalse(ApplicationIconController.hasCustomIcon(at: fixture.app), "File icon must roll back to its original packaged black icon")
        XCTAssertEqual(try Data(contentsOf: blocker), blockerBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(try contentsFingerprint(fixture.app), originalContents)
    }

    func testMissingWhiteResourceRejectsIconChoiceBeforeSavingAnySettings() throws {
        _ = NSApplication.shared
        let fixture = try makeFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.removeItem(at: fixture.app.appendingPathComponent("Contents/Resources/AppIconWhite.icns"))
        let originalContents = try contentsFingerprint(fixture.app)
        let store = AppStore(fileURL: fixture.workspace)
        let original = store.workspace.preferences
        var updates = 0
        store.applicationIconController = ApplicationIconController(bundleURL: fixture.app) { _ in updates += 1 }
        var draft = original; draft.applicationIcon = "white"; draft.fontSize = 22
        XCTAssertThrowsError(try store.commitPreferences(draft)) { error in
            XCTAssertTrue(error.localizedDescription.contains("icon resources") || error.localizedDescription.contains("图标资源"))
        }
        XCTAssertEqual(store.workspace.preferences, original, "Other draft settings must remain unsaved when applying the icon fails")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspace.path))
        XCTAssertEqual(updates, 0)
        XCTAssertFalse(ApplicationIconController.hasCustomIcon(at: fixture.app))
        XCTAssertEqual(try contentsFingerprint(fixture.app), originalContents)
    }

    func testFailedBlackSaveRestoresPreviouslySavedWhiteFileAndRunningIcon() throws {
        _ = NSApplication.shared
        let fixture = try makeFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let originalContents = try contentsFingerprint(fixture.app)
        let stateDirectory = fixture.directory.appendingPathComponent("state")
        let workspaceURL = stateDirectory.appendingPathComponent("workspace.json")
        let store = AppStore(fileURL: workspaceURL)
        var updates: [NSImage] = []
        store.applicationIconController = ApplicationIconController(bundleURL: fixture.app) { updates.append($0) }
        var draft = store.workspace.preferences; draft.applicationIcon = "white"
        try store.commitPreferences(draft)
        XCTAssertEqual(updates.count, 1)
        XCTAssertTrue(ApplicationIconController.hasCustomIcon(at: fixture.app))
        let savedWhitePreferences = store.workspace.preferences
        let savedBytes = try Data(contentsOf: workspaceURL)
        let whitePixels = try raster(NSWorkspace.shared.icon(forFile: fixture.app.path), size: 128)

        // Keep the persisted white workspace recoverable, but replace its
        // parent directory with a file so the next atomic save must fail.
        let backupDirectory = fixture.directory.appendingPathComponent("state-backup")
        try FileManager.default.moveItem(at: stateDirectory, to: backupDirectory)
        let blocker = Data("block-preference-save".utf8); try blocker.write(to: stateDirectory)
        draft = savedWhitePreferences; draft.applicationIcon = "black"
        XCTAssertThrowsError(try store.commitPreferences(draft))
        XCTAssertEqual(store.workspace.preferences, savedWhitePreferences)
        XCTAssertEqual(updates.count, 1, "Failed black save must keep the running white icon without another callback")
        XCTAssertTrue(ApplicationIconController.hasCustomIcon(at: fixture.app), "Rolling back black must reinstate the prior white Finder icon")
        XCTAssertEqual(try raster(NSWorkspace.shared.icon(forFile: fixture.app.path), size: 128), whitePixels)
        try assertMatchesSystemIcon(try XCTUnwrap(updates.last), app: fixture.app)
        XCTAssertEqual(try Data(contentsOf: backupDirectory.appendingPathComponent("workspace.json")), savedBytes)
        XCTAssertEqual(try savedPreferences(backupDirectory.appendingPathComponent("workspace.json")).applicationIcon, "white")
        XCTAssertEqual(try Data(contentsOf: stateDirectory), blocker)
        XCTAssertEqual(try contentsFingerprint(fixture.app), originalContents)
    }

    func testInstallerRestoresSavedWhiteIconWithoutLaunchingTheApplication() throws {
        _ = NSApplication.shared
        let fixture = try makeFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let fingerprint = try contentsFingerprint(fixture.app)
        var workspace = Workspace(); workspace.preferences.applicationIcon = "white"
        try JSONEncoder().encode(workspace).write(to: fixture.workspace)
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        task.arguments = [project.appendingPathComponent("scripts/installed-icon.swift").path, fixture.app.path, fixture.workspace.path]
        try task.run(); task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
        XCTAssertTrue(ApplicationIconController.hasCustomIcon(at: fixture.app))
        XCTAssertEqual(try contentsFingerprint(fixture.app), fingerprint)
        let image = NSWorkspace.shared.icon(forFile: fixture.app.path)
        try assertIconStyle(image, white: true)
        if let path = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] {
            let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try raster(image, size: 128).write(to: directory.appendingPathComponent("icon-white-before-launch.png"))
        }
    }

    private struct Fixture { let directory: URL; let app: URL; let workspace: URL }
    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axon-icon-runtime-" + UUID().uuidString)
        let app = directory.appendingPathComponent("Axon Icon Runtime.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        let executable = app.appendingPathComponent("Contents/MacOS/AxonFixture")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(at: project.appendingPathComponent("Branding/AppIcon.icns"), to: resources.appendingPathComponent("AppIconBlack.icns"))
        try FileManager.default.copyItem(at: project.appendingPathComponent("Branding/AppIconWhite.icns"), to: resources.appendingPathComponent("AppIconWhite.icns"))
        let product = Bundle(for: ApplicationIconRuntimeTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("TabbyNative")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: product.path))
        try FileManager.default.copyItem(at: product, to: executable)
        let info: [String: Any] = ["CFBundleName": "Axon Icon Runtime", "CFBundleIdentifier": "org.tabby.native.icon-runtime." + UUID().uuidString.lowercased(), "CFBundlePackageType": "APPL", "CFBundleExecutable": "AxonFixture", "CFBundleIconFile": "AppIconBlack", "LSMinimumSystemVersion": "15.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return Fixture(directory: directory, app: app, workspace: directory.appendingPathComponent("workspace.json"))
    }
    private func savedPreferences(_ url: URL) throws -> Preferences {
        try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: url)).preferences
    }
    private func contentsFingerprint(_ app: URL) throws -> [String: String] {
        let contents = app.appendingPathComponent("Contents")
        var fingerprints: [String: String] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: contents.path) {
            let url = contents.appendingPathComponent(path)
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue {
                fingerprints[path] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            }
        }
        return fingerprints
    }
    private func assertMatchesSystemIcon(_ image: NSImage, app: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        // IconServices can return transparent images inside a restricted test
        // process. Compare both delivery paths here; root audits real pixels in
        // the installed bundle with normal IconServices access.
        let system = NSWorkspace.shared.icon(forFile: app.path)
        for size in [32, 64, 128] {
            XCTAssertEqual(try raster(image, size: size), try raster(system, size: size), "Running and stopped app icon paths must match", file: file, line: line)
        }
    }
    private func raster(_ image: NSImage, size: Int) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func assertIconStyle(_ image: NSImage, white: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: raster(image, size: 128)))
        let color = try XCTUnwrap(bitmap.colorAt(x: 64, y: 18)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.alphaComponent, 0.9, file: file, line: line)
        if white { XCTAssertGreaterThan(color.redComponent, 0.9, file: file, line: line) }
        else { XCTAssertLessThan(color.redComponent, 0.3, file: file, line: line) }
    }
}
