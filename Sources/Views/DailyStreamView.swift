import SwiftUI

/// The endless scrolling stream of all daily notes, newest first.
struct DailyStreamView: View {
    @Environment(AppModel.self) private var appModel
    let store: VaultStore
    @State private var didInitialScroll = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(store.days.prefix(appModel.loadedDays).enumerated()),
                            id: \.element.id) { index, day in
                        DaySectionView(day: day, store: store)
                            .id(day.id)
                            .onAppear {
                                if index == appModel.loadedDays - 1 {
                                    appModel.loadMoreDays()
                                }
                            }
                    }
                    if appModel.moreDaysAvailable() {
                        ProgressView("Loading older days…")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .onAppear { appModel.loadMoreDays() }
                    } else if store.days.isEmpty {
                        ContentUnavailableView(
                            "No daily notes found",
                            systemImage: "tray",
                            description: Text("The journals folder contains no dated markdown files.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
            }
            .onChange(of: appModel.scrollToDay) { _, target in
                guard let target else { return }
                DispatchQueue.main.async {
                    withAnimation {
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
            }
            .onAppear {
                if !didInitialScroll {
                    didInitialScroll = true
                    // Newest is at the top already; nothing to do.
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
