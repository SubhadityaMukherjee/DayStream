import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single window, no tabs: never auto-tab our windows, and there is
        // no document model that would justify more than one.
        NSWindow.allowsAutomaticWindowTabbing = false
        GlobalQuickAddController.shared.refresh()
    }
}

@main
struct DayStreamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appModel = AppModel.shared
    @State private var settings = AppSettings.shared

    var body: some Scene {
        // `Window` (not WindowGroup): a single main window. Re-opening
        // (dock click, global quick-add shortcut, openWindow) reactivates
        // the existing window instead of spawning another.
        Window("DayStream", id: "main") {
            RootView()
                .environment(appModel)
                .environment(settings)
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Todo Today") {
                    appModel.newTodoToday()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Find in Vault…") {
                    appModel.triggerSearch()
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(appModel)
                .environment(settings)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    /// Captured at launch. Once the welcome has run (or was seen in a past
    /// launch) it never re-presents mid-session; Settings → Advanced only
    /// flags it for the *next* launch.
    @State private var welcomeDoneThisSession: Bool

    init() {
        _welcomeDoneThisSession = State(initialValue: AppSettings.shared.hasSeenWelcome)
    }

    var body: some View {
        Group {
            if appModel.isConfigured {
                MainView()
            } else {
                SetupView()
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .onAppear {
            MainWindowOpener.openWindow = openWindow
        }
        .sheet(isPresented: Binding(
            get: { !settings.hasSeenWelcome && !welcomeDoneThisSession },
            set: { shown in
                if !shown {
                    welcomeDoneThisSession = true
                    settings.hasSeenWelcome = true
                }
            }
        )) {
            WelcomeView()
        }
    }
}
