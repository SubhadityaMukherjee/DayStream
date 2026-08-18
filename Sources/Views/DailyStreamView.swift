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
                // Consume the request so re-requesting the same day (Today
                // clicked twice, search hit clicked again) still fires.
                appModel.scrollToDay = nil
                scrollTo(proxy: proxy, target: target)
            }
            .onAppear {
                if !didInitialScroll {
                    didInitialScroll = true
                    // A scroll request may have been made before this view
                    // existed (onChange misses pre-existing values).
                    if let target = appModel.scrollToDay {
                        appModel.scrollToDay = nil
                        scrollTo(proxy: proxy, target: target)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Scroll attempts at increasing delays: the first runs before newly
    /// loaded sections are realized (LazyVStack builds lazily), so retries
    /// after layout passes are what actually land on days far outside the
    /// visible window (e.g. a search hit 300 days back).
    private func scrollTo(proxy: ScrollViewProxy, target: Date) {
        proxy.scrollTo(target, anchor: .top)
        for delay in [0.05, 0.2, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(target, anchor: .top)
                }
            }
        }
    }
}
