import SwiftUI

@main
struct DayStreamApp: App {
    @State private var appModel = AppModel()
    @State private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(appModel)
                .environment(settings)
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: false))

        MenuBarExtra("DayStream", systemImage: "note.text") {
            MenuBarPanel()
                .environment(appModel)
                .environment(settings)
        }
        .menuBarExtraStyle(.window)

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
