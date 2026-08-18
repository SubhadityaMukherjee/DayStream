import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var appModel = appModel
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 250)
                .background(.bar)

            Divider()

            if let store = appModel.store {
                DailyStreamView(store: store)
                    .id(store.vaultURL)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .environment(
            \.openURL,
            OpenURLAction { url in
                if handleInternalURL(url) {
                    return .handled
                }
                return .systemAction
            }
        )
        .sheet(item: $appModel.openPage) { page in
            PageView(pageName: page.name)
                .frame(minWidth: 560, minHeight: 460)
        }
        .sheet(isPresented: $appModel.showNewNote) {
            NewNoteSheet()
                .frame(minWidth: 420, minHeight: 160)
        }
        .alert(
            "Carry Forward",
            isPresented: Binding(
                get: { appModel.carrySummary != nil },
                set: { if !$0 { appModel.carrySummary = nil } }
            )
        ) {
            Button("OK") { appModel.carrySummary = nil }
        } message: {
            Text(appModel.carrySummary?.summary ?? "")
        }
        .onAppear {
            appModel.goToToday()
        }
    }

    private func handleInternalURL(_ url: URL) -> Bool {
        guard url.scheme == "daystream", url.host == "page" else { return false }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let name = comps?.queryItems?.first(where: { $0.name == "name" })?.value {
            appModel.openPage = AppModel.PageRef(name: name)
            return true
        }
        return false
    }
}

private struct SidebarView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 12) {
            CalendarView()
                .padding(.horizontal, 10)

            Divider()

            VStack(spacing: 8) {
                Button {
                    appModel.goToToday()
                } label: {
                    Label("Today", systemImage: "calendar.badge.clock")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button {
                    appModel.runCarryForward()
                } label: {
                    Label("Carry Forward Unfinished", systemImage: "arrow.down.forward.square")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button {
                    appModel.showNewNote = true
                } label: {
                    Label("New Page…", systemImage: "plus.square.dashed")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.horizontal, 10)

            if let store = appModel.store {
                Spacer()
                HStack {
                    Text("\(store.days.count) daily notes · \(store.pageCount) pages")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        openSettings()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Settings (⌘,)")
                }
                .padding(.bottom, 8)
                .padding(.horizontal, 10)
            }
        }
        .padding(.top, 12)
    }
}
