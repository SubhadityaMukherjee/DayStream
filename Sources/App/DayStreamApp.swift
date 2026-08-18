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
        .windowToolbarStyle(.unified(showsTitle: true))

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

    var body: some View {
        Group {
            if appModel.isConfigured {
                MainView()
            } else {
                SetupView()
            }
        }
        .frame(minWidth: 980, minHeight: 640)
    }
}
