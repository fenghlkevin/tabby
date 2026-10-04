import AppKit
import SwiftUI

enum MonitoringVisibility {
    static func permitsSampling(applicationActive: Bool, applicationHidden: Bool,
                                windowVisible: Bool, windowMiniaturized: Bool, windowOccluded: Bool) -> Bool {
        applicationActive && !applicationHidden && windowVisible && !windowMiniaturized && !windowOccluded
    }
}

/// The terminal surfaces stay mounted when another vault page is selected.
/// Sampling follows the visible window, independently of those view lifetimes.
struct MonitoringVisibilityProbe: NSViewRepresentable {
    var changed: (Bool) -> Void
    func makeNSView(context: Context) -> MonitoringVisibilityView { MonitoringVisibilityView() }
    func updateNSView(_ view: MonitoringVisibilityView, context: Context) {
        view.changed = changed
        view.updateVisibility()
    }
    static func dismantleNSView(_ view: MonitoringVisibilityView, coordinator: ()) { view.stopObserving() }
}

final class MonitoringVisibilityView: NSView {
    var changed: (Bool) -> Void = { _ in }
    private var observers: [NSObjectProtocol] = []
    private var lastValue: Bool?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { updateVisibility(); return }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in self?.updateVisibility() })
        }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.updateVisibility() })
        }
        updateVisibility()
    }
    func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }
    func updateVisibility() {
        let visible = MonitoringVisibility.permitsSampling(applicationActive: NSApp.isActive,
            applicationHidden: NSApp.isHidden, windowVisible: window?.isVisible == true,
            windowMiniaturized: window?.isMiniaturized ?? false,
            windowOccluded: window?.occlusionState.contains(.visible) != true)
        guard visible != lastValue else { return }
        lastValue = visible
        // NSView attachment can occur during a SwiftUI update.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lastValue == visible else { return }
            self.changed(visible)
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
