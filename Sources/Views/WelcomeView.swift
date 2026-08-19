import SwiftUI
import AppKit

/// One-page, Apple-style welcome shown on first launch only.
struct WelcomeView: View {
    @Environment(AppSettings.self) private var settings

    private struct Feature {
        let icon: String
        let title: String
        let detail: String
    }

    private let features: [Feature] = [
        Feature(icon: "scroll", title: "One endless stream",
                detail: "Every daily note in a single scroll, newest first. A new day's note is created for you automatically."),
        Feature(icon: "checkmark.square", title: "Outliner tasks",
                detail: "TODO / DONE markers, cross-note syncing, task timing, and one-click carry-forward of unfinished work."),
        Feature(icon: "repeat", title: "Recurring & deadlines",
                detail: "Daily, weekly or one-off tasks seed themselves on their day; deadlines stay pinned in the sidebar."),
        Feature(icon: "link", title: "[[Wikilinks]] & pages",
                detail: "Click a link to open a page with linked references — or jump straight to a day like [[Aug 18th, 2026]]."),
        Feature(icon: "magnifyingglass", title: "Search everything",
                detail: "One bar across every journal and page; results jump straight to the day or page."),
        Feature(icon: "menubar.rectangle", title: "Menu bar quick add",
                detail: "Capture a task for today — or schedule it to any date — without leaving what you're doing."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 84, height: 84)
                Text("Welcome to DayStream")
                    .font(.system(size: 21, weight: .bold))
                Text("A fast, native daily-notes stream over your plain markdown vault.\nPlain files, no lock-in — Logseq-compatible.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 28)
            .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(features, id: \.title) { feature in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: feature.icon)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(feature.title)
                                .font(.system(size: 12.5, weight: .semibold))
                            Text(feature.detail)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 34)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                settings.hasSeenWelcome = true
            } label: {
                Text("Get Started")
                    .frame(minWidth: 120)
            }
            .prominentActionButtonStyle()
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 22)
            .padding(.bottom, 26)
        }
        .frame(width: 460)
    }
}
