import SwiftUI

@main
struct DayStreamApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: true))
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
