import SwiftUI
import AppKit

/// Captured from RootView (inside the main Window scene) so the global
/// hotkey can reopen that window from outside the view hierarchy. The
/// action stays valid after capture, including while the window is closed.
enum MainWindowOpener {
    static var openWindow: OpenWindowAction?
}

/// Owns the system-wide quick-add shortcut: opens (or brings forward) the
/// main window and starts a fresh todo in today's note, caret ready —
/// exactly what ⌘N does inside the app.
final class GlobalQuickAddController {
    static let shared = GlobalQuickAddController()

    /// (Re)registers the shortcut from settings.
    func refresh() {
        let settings = AppSettings.shared
        GlobalHotkeyManager.shared.unregister()
        guard settings.globalQuickAddEnabled, let spec = settings.quickAddHotkey else { return }
        GlobalHotkeyManager.shared.register(spec: spec) {
            Self.shared.fire()
        }
    }

    private func fire() {
        NSApp.activate(ignoringOtherApps: true)
        if let openWindow = MainWindowOpener.openWindow {
            openWindow(id: "main")
        }
        AppModel.shared.newTodoToday()
    }
}
