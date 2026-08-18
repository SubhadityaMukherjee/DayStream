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
        static let syncTodos = "daystream.syncTodosAcrossNotes"
    }

    /// 0 = system sans (SF Pro), 1 = serif (New York), 2 = rounded, 3 = monospace.
    var fontDesign: Int {
        didSet { UserDefaults.standard.set(fontDesign, forKey: Keys.fontDesign) }
    }
    var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Keys.fontSize) }
    }
    /// Toggling a task rewrites matching tasks in every other note.
    var syncTodosAcrossNotes: Bool {
        didSet { UserDefaults.standard.set(syncTodosAcrossNotes, forKey: Keys.syncTodos) }
    }

    init() {
        let d = UserDefaults.standard
        self.fontDesign = d.object(forKey: Keys.fontDesign) as? Int ?? 1
        self.fontSize = d.object(forKey: Keys.fontSize) as? Double ?? 15
        self.syncTodosAcrossNotes = d.object(forKey: Keys.syncTodos) as? Bool ?? true
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
}
