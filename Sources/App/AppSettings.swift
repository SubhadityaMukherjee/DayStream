import SwiftUI
import Observation
import AppKit

/// User-facing preferences, persisted in UserDefaults. Font choices apply to
/// both the stream rendering and the editor.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private enum Keys {
        static let fontDesign = "daystream.fontDesign"
        static let fontSize = "daystream.fontSize"
        static let liveMarkdown = "daystream.liveMarkdownRendering"
        static let syncTodos = "daystream.syncTodosAcrossNotes"
        static let autoCarry = "daystream.autoCarryForward"
    static let carryOnNewDate = "daystream.carryForwardOnNewDate"
        static let welcome = "daystream.hasSeenWelcome"
        static let gitBackupPath = "daystream.gitBackupPath"
        static let gitBackupEnabled = "daystream.gitBackupEnabled"
        static let autoBackupEnabled = "daystream.autoBackupEnabled"
        static let autoBackupInterval = "daystream.autoBackupInterval"
        static let lastAutoBackup = "daystream.lastAutoBackupDate"
        static let globalQuickAddEnabled = "daystream.globalQuickAddEnabled"
        static let globalQuickAddSpec = "daystream.globalQuickAddSpec"
    }

    /// Automatic git backup cadence: daily or weekly (weekly is the default).
    enum AutoBackupInterval: Int, CaseIterable, Identifiable {
        case daily = 1
        case weekly = 2

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .daily: return "Daily"
            case .weekly: return "Weekly"
            }
        }

        var seconds: TimeInterval {
            switch self {
            case .daily: return 24 * 3600
            case .weekly: return 7 * 24 * 3600
            }
        }
    }

    /// A recorded global shortcut: Carbon modifiers + virtual key code plus
    /// the display string captured at record time (translating key codes to
    /// glyphs retroactively needs UCKeyTranslate, not worth it for one label).
    struct HotkeySpec: Equatable {
        var carbonModifiers: UInt32
        var keyCode: UInt32
        var display: String

        /// ⌥T (optionKey = 1 << 11 = 2048; kVK_ANSI_T = 0x11 = 17).
        static let defaultQuickAdd = HotkeySpec(carbonModifiers: 2048, keyCode: 17, display: "⌥T")

        var storage: String {
            "\(carbonModifiers),\(keyCode),\(display)"
        }

        static func parse(_ s: String) -> HotkeySpec? {
            let parts = s.components(separatedBy: ",")
            guard parts.count == 3,
                  let mods = UInt32(parts[0]),
                  let code = UInt32(parts[1]),
                  !parts[2].isEmpty
            else { return nil }
            return HotkeySpec(carbonModifiers: mods, keyCode: code, display: parts[2])
        }
    }

    /// 0 = system sans (SF Pro), 1 = serif (New York), 2 = rounded, 3 = monospace.
    var fontDesign: Int {
        didSet { UserDefaults.standard.set(fontDesign, forKey: Keys.fontDesign) }
    }
    var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Keys.fontSize) }
    }
    /// Editor live preview: markdown syntax hides on lines away from the
    /// caret (glyph-level; the raw text never changes).
    var liveMarkdownRendering: Bool {
        didSet { UserDefaults.standard.set(liveMarkdownRendering, forKey: Keys.liveMarkdown) }
    }
    /// Toggling a task rewrites matching tasks in every other note.
    var syncTodosAcrossNotes: Bool {
        didSet { UserDefaults.standard.set(syncTodosAcrossNotes, forKey: Keys.syncTodos) }
    }
    /// Each new day, unfinished tasks from previous days are copied into the
    /// new day's note automatically (once per day, duplicate-checked).
    var autoCarryForward: Bool {
        didSet { UserDefaults.standard.set(autoCarryForward, forKey: Keys.autoCarry) }
    }
    /// Creating a note for a date that doesn't exist yet carries unfinished
    /// tasks from earlier days into it (calendar, deadline, [[date link]]).
    var carryForwardOnNewDate: Bool {
        didSet { UserDefaults.standard.set(carryForwardOnNewDate, forKey: Keys.carryOnNewDate) }
    }
    /// One-time welcome window has been shown.
    var hasSeenWelcome: Bool {
        didSet { UserDefaults.standard.set(hasSeenWelcome, forKey: Keys.welcome) }
    }
    /// Repository folder used by Settings → Advanced git backup ("" = unset).
    var gitBackupPath: String {
        didSet { UserDefaults.standard.set(gitBackupPath, forKey: Keys.gitBackupPath) }
    }
    /// Git backup is enabled; when on, a Back Up button appears in the sidebar.
    var gitBackupEnabled: Bool {
        didSet { UserDefaults.standard.set(gitBackupEnabled, forKey: Keys.gitBackupEnabled) }
    }
    /// Automatic backup runs in the background at `autoBackupInterval`.
    /// Off by default; the interval defaults to weekly.
    var autoBackupEnabled: Bool {
        didSet { UserDefaults.standard.set(autoBackupEnabled, forKey: Keys.autoBackupEnabled) }
    }
    var autoBackupIntervalRaw: Int {
        didSet { UserDefaults.standard.set(autoBackupIntervalRaw, forKey: Keys.autoBackupInterval) }
    }
    var autoBackupInterval: AutoBackupInterval {
        get { AutoBackupInterval(rawValue: autoBackupIntervalRaw) ?? .weekly }
        set { autoBackupIntervalRaw = newValue.rawValue }
    }
    /// Wall-clock of the last successful backup (manual or automatic); drives
    /// the next-due check. Nil = never backed up.
    var lastAutoBackup: Date? {
        didSet {
            if let lastAutoBackup {
                UserDefaults.standard.set(lastAutoBackup, forKey: Keys.lastAutoBackup)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.lastAutoBackup)
            }
        }
    }
    /// System-wide quick-add shortcut is active.
    var globalQuickAddEnabled: Bool {
        didSet { UserDefaults.standard.set(globalQuickAddEnabled, forKey: Keys.globalQuickAddEnabled) }
    }
    /// "modifiers,keyCode,display" for the global shortcut (see HotkeySpec).
    var globalQuickAddSpec: String {
        didSet { UserDefaults.standard.set(globalQuickAddSpec, forKey: Keys.globalQuickAddSpec) }
    }

    var quickAddHotkey: HotkeySpec? {
        HotkeySpec.parse(globalQuickAddSpec)
    }

    init() {
        let d = UserDefaults.standard
        self.fontDesign = d.object(forKey: Keys.fontDesign) as? Int ?? 0
        self.fontSize = d.object(forKey: Keys.fontSize) as? Double ?? 15
        self.liveMarkdownRendering = d.object(forKey: Keys.liveMarkdown) as? Bool ?? true
        self.syncTodosAcrossNotes = d.object(forKey: Keys.syncTodos) as? Bool ?? true
        self.autoCarryForward = d.object(forKey: Keys.autoCarry) as? Bool ?? true
        self.carryForwardOnNewDate = d.object(forKey: Keys.carryOnNewDate) as? Bool ?? true
        self.hasSeenWelcome = d.bool(forKey: Keys.welcome)
        self.gitBackupPath = d.string(forKey: Keys.gitBackupPath) ?? ""
        self.gitBackupEnabled = d.bool(forKey: Keys.gitBackupEnabled)
        self.autoBackupEnabled = d.bool(forKey: Keys.autoBackupEnabled)
        self.autoBackupIntervalRaw = d.object(forKey: Keys.autoBackupInterval) as? Int ?? AutoBackupInterval.weekly.rawValue
        self.lastAutoBackup = d.object(forKey: Keys.lastAutoBackup) as? Date
        self.globalQuickAddEnabled = d.object(forKey: Keys.globalQuickAddEnabled) as? Bool ?? true
        self.globalQuickAddSpec = d.string(forKey: Keys.globalQuickAddSpec) ?? HotkeySpec.defaultQuickAdd.storage
    }

    var fontDesignValue: NSFontDescriptor.SystemDesign {
        switch fontDesign {
        case 0: return .default
        case 2: return .rounded
        case 3: return .monospaced
        default: return .serif
        }
    }

    func editorFont() -> NSFont {
        font(size: fontSize)
    }

    func font(size: Double) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        if let descriptor = base.fontDescriptor.withDesign(fontDesignValue) {
            return NSFont(descriptor: descriptor, size: size) ?? base
        }
        return base
    }

    /// SwiftUI font for stream content.
    var streamFont: Font {
        switch fontDesignValue {
        case .serif: .system(size: fontSize, weight: .regular, design: .serif)
        case .rounded: .system(size: fontSize, weight: .regular, design: .rounded)
        case .monospaced: .system(size: fontSize, weight: .regular, design: .monospaced)
        default: .system(size: fontSize)
        }
    }

    var streamFontSemibold: Font {
        switch fontDesignValue {
        case .serif: .system(size: fontSize + 0.5, weight: .semibold, design: .serif)
        case .rounded: .system(size: fontSize + 0.5, weight: .semibold, design: .rounded)
        case .monospaced: .system(size: fontSize + 0.5, weight: .semibold, design: .monospaced)
        default: .system(size: fontSize + 0.5, weight: .semibold)
        }
    }

    /// Day (date) headings in the stream — noticeably larger than body text.
    var dayHeadingFont: Font {
        switch fontDesignValue {
        case .serif: .system(size: fontSize + 5, weight: .bold, design: .serif)
        case .rounded: .system(size: fontSize + 5, weight: .bold, design: .rounded)
        case .monospaced: .system(size: fontSize + 4, weight: .bold, design: .monospaced)
        default: .system(size: fontSize + 5, weight: .bold)
        }
    }

    /// Markdown heading (`#`, `##`, …) font, scaled down with depth.
    func headingFont(level: Int) -> Font {
        let bump = max(1.5, Double(5 - min(level, 4)))
        switch fontDesignValue {
        case .serif: return .system(size: fontSize + bump, weight: .semibold, design: .serif)
        case .rounded: return .system(size: fontSize + bump, weight: .semibold, design: .rounded)
        case .monospaced: return .system(size: fontSize + bump - 0.5, weight: .semibold, design: .monospaced)
        default: return .system(size: fontSize + bump, weight: .semibold)
        }
    }
}
