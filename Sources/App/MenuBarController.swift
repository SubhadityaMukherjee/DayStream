import SwiftUI
import AppKit

/// Focus plumbing between the popover host and the SwiftUI panel: bumping
/// `quickAddToken` moves focus into the quick-add field (panel also focuses
/// it on first appear).
@Observable
final class MenuBarFocusModel {
    var quickAddToken = 0
}

/// Owns the menu bar applet: an NSStatusItem whose button toggles an
/// NSPopover hosting MenuBarPanel. Replaces SwiftUI's MenuBarExtra because
/// the system-wide quick-add shortcut needs to open the panel
/// programmatically, which MenuBarExtra has no API for.
final class MenuBarController: NSObject, NSPopoverDelegate {
    static let shared = MenuBarController()

    let focus = MenuBarFocusModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    var isShown: Bool { popover.isShown }

    func setup() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "DayStream")
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.action = #selector(togglePopover)
        item.button?.target = self
        statusItem = item

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: MenuBarPanel()
            .environment(AppModel.shared)
            .environment(AppSettings.shared)
            .environment(focus))
        // Popovers size to their contentViewController's preferred size;
        // the SwiftUI panel sets its own fixed width and content-driven height.
        popover.contentViewController = host

        refreshHotkey()
    }

    /// (Re)registers the system-wide quick-add shortcut from settings.
    func refreshHotkey() {
        let settings = AppSettings.shared
        GlobalHotkeyManager.shared.unregister()
        guard settings.globalQuickAddEnabled, let spec = settings.quickAddHotkey else { return }
        GlobalHotkeyManager.shared.register(spec: spec) { [weak self] in
            self?.present(focusQuickAdd: true)
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            present(focusQuickAdd: false)
        }
    }

    /// Shows the applet anchored to the status item. Activates the app first
    /// so the popover's text field can become the key responder even when
    /// another application was frontmost (the hotkey case).
    func present(focusQuickAdd: Bool) {
        guard let button = statusItem?.button else { return }
        if focusQuickAdd {
            focus.quickAddToken += 1
        }
        NSApp.activate(ignoringOtherApps: true)
        guard !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    // MARK: - NSPopoverDelegate

    /// The hosting controller must allow key view cycling so the quick-add
    /// field can take focus inside a popover.
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        true
    }
}
