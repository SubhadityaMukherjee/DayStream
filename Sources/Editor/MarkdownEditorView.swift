import SwiftUI
import AppKit

/// A non-scrolling, content-fitting markdown editor with outliner niceties:
/// - Enter continues the bullet at the same indent (empty bullet exits the list)
/// - Tab / Shift-Tab indent / outdent the current line
/// - `/todo `, `/doing `, `/later `, `/done ` expand to TODO-style markers
/// - Escape ends editing (and flushes the pending save)
/// - ⌘K links the selection (URL on the clipboard -> `[text](url)`, else `[[wikilink]]`)
/// - ⌘⏎ toggles the current line's TODO/DONE marker
/// - Drag & drop images into `assets/`, URLs and files as links
/// - Live highlighting of markers, `[[wikilinks]]`, code spans, headings
struct MarkdownEditorView: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = AppSettings.shared.editorFont()
    /// Importer for dropped images; nil disables image importing.
    var imageImporter: ((Data, String?) -> String?)? = nil
    var onTextChanged: ((String) -> Void)? = nil
    var onCommit: (() -> Void)? = nil

    func makeNSView(context: Context) -> EditorScrollView {
        let tv = EditorTextView()
        tv.font = font
        tv.textColor = .labelColor
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.textContainerInset = NSSize(width: 0, height: 6)
        tv.textContainer?.lineFragmentPadding = 4
        tv.string = text
        tv.delegate = context.coordinator
        tv.onCommit = onCommit
        tv.imageImporter = imageImporter
        tv.highlight()

        let scroll = EditorScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.editor = tv

        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
            tv.selectedRange = NSRange(location: (tv.string as NSString).length, length: 0)
        }
        return scroll
    }

    func updateNSView(_ nsView: EditorScrollView, context: Context) {
        guard let tv = nsView.editor else { return }
        if tv.string != text, !context.coordinator.isEditingLocally {
            tv.string = text
            tv.highlight()
        }
        if tv.font != font {
            tv.font = font
            tv.highlight()
        }
        nsView.invalidateIntrinsicContentSize()
        tv.onCommit = onCommit
        tv.imageImporter = imageImporter
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditorView
        var isEditingLocally = false

        init(_ parent: MarkdownEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            isEditingLocally = true
            parent.text = tv.string
            parent.onTextChanged?(tv.string)
            isEditingLocally = false
        }
    }
}

/// Scroll view that sizes itself to fit the text view, so the outer stream scrolls.
final class EditorScrollView: NSScrollView {
    weak var editor: EditorTextView?

    override var intrinsicContentSize: NSSize {
        guard let tv = editor, let container = tv.textContainer, let layout = container.layoutManager else {
            return super.intrinsicContentSize
        }
        layout.ensureLayout(for: container)
        let height = layout.usedRect(for: container).height + tv.textContainerInset.height * 2 + 8
        return NSSize(width: -1, height: max(height, 96))
    }
}

final class EditorTextView: NSTextView {
    var onCommit: (() -> Void)?
    var imageImporter: ((Data, String?) -> String?)? = nil

    private var slashMarkers: [String: String] {
        ["/todo": "TODO", "/doing": "DOING", "/later": "LATER", "/now": "NOW", "/done": "DONE"]
    }

    // MARK: - Keyboard plumbing

    /// SwiftUUI's ScrollView (an ancestor) loves to claim the unmodified space
    /// key during the key-equivalent phase for page-scrolling, which eats the
    /// space character before keyDown reaches the text view. Claim bare space
    /// (and a few friends) first and insert them ourselves.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isBare = modifiers.isEmpty || modifiers == .function

        if event.keyCode == Keyboard.space, isBare {
            insertText(" ", replacementRange: selectedRange())
            return true
        }
        if event.keyCode == Keyboard.k, modifiers == .command {
            makeLinkFromSelectionOrClipboard()
            return true
        }
        if event.keyCode == Keyboard.returnKey, modifiers == .command {
            toggleTodoOnCurrentLine()
            return true
        }
        if event.keyCode == Keyboard.b, modifiers == .command {
            wrapSelection(prefix: "**", suffix: "**")
            return true
        }
        if event.keyCode == Keyboard.i, modifiers == .command {
            wrapSelection(prefix: "*", suffix: "*")
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private enum Keyboard {
        static let space: UInt16 = 49
        static let k: UInt16 = 40
        static let b: UInt16 = 11
        static let i: UInt16 = 34
        static let returnKey: UInt16 = 36
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // escape
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }

    /// Clicks must always land in the text view, even when SwiftUI overlays
    /// tap gestures, or the first responder drifts and typing breaks.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    // MARK: - ⌘K: link the selection

    private func makeLinkFromSelectionOrClipboard() {
        let s = string as NSString
        let range = selectedRange()
        let selected = range.length > 0 ? s.substring(with: range) : ""

        if let url = clipboardURL(), !selected.isEmpty {
            // Pasting a link onto selected text: [selection](url)
            let link = "[\(selected)](\(url.absoluteString))".replacingOccurrences(of: "\n", with: " ")
            insertText(link, replacementRange: range)
            return
        }
        if selected.isEmpty {
            // Nothing selected and no URL: insert an empty wikilink, caret inside.
            insertText("[[]]", replacementRange: range)
            let caret = range.location
            selectedRange = NSRange(location: caret + 2, length: 0)
            return
        }
        // Selection without URL: make it a [[wikilink]].
        let wiki = selected.replacingOccurrences(of: "\n", with: " ")
        insertText("[[\(wiki)]]", replacementRange: range)
        selectedRange = NSRange(location: range.location, length: wiki.count + 4)
    }

    private func clipboardURL() -> URL? {
        guard let raw = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        guard raw.count < 2000, raw.range(of: #"^\s*(https?://|daystream://|/|assets/)"#, options: .regularExpression) != nil else { return nil }
        return URL(string: raw.contains("://") || raw.hasPrefix("/") || raw.hasPrefix("assets/") ? raw : raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)
    }

    // MARK: - ⌘⏎: toggle TODO/DONE on the current line

    private func toggleTodoOnCurrentLine() {
        let s = string as NSString
        let caret = selectedRange().location
        let lineRange = s.lineRange(for: NSRange(location: min(caret, s.length), length: 0))
        let line = s.substring(with: lineRange)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { return }
        let rest = String(trimmed.dropFirst(2))
        let markers: [(String, String)] = [
            ("TODO", "DONE"), ("LATER", "DONE"), ("NOW", "DONE"), ("DOING", "DONE"),
            ("DONE", "TODO"),
        ]
        for (from, to) in markers where rest.hasPrefix(from) {
            if let r = line.range(of: from) {
                let nsr = NSRange(r, in: line)
                shouldChangeText(in: lineRange, replacementString: line)
                textStorage?.replaceCharacters(
                    in: NSRange(location: lineRange.location + nsr.location, length: nsr.length),
                    with: to
                )
                didChangeText()
            }
            return
        }
        // Plain bullet: promote to TODO.
        let bulletOffset = line.count - (line.drop { $0 == "\t" || $0 == " " }).count
        let insertAt = lineRange.location + bulletOffset + 2
        guard line.count - bulletOffset >= 2 else { return }
        shouldChangeText(in: lineRange, replacementString: line)
        textStorage?.replaceCharacters(
            in: NSRange(location: insertAt, length: 0),
            with: "TODO "
        )
        didChangeText()
    }

    // MARK: - Selection wrapping (bold / italic)

    private func wrapSelection(prefix: String, suffix: String) {
        let range = selectedRange()
        let s = string as NSString
        if range.length == 0 {
            insertText(prefix + suffix, replacementRange: range)
            selectedRange = NSRange(location: range.location + prefix.count, length: 0)
            return
        }
        let selected = s.substring(with: range)
        insertText(prefix + selected + suffix, replacementRange: range)
        selectedRange = NSRange(location: range.location + prefix.count, length: selected.count)
    }

    // MARK: - Outliner behaviors

    override func insertNewline(_ sender: Any?) {
        let s = string as NSString
        let caret = selectedRange().location
        let lineStart = (s.lineRange(for: NSRange(location: min(caret, s.length), length: 0)).location)
        let lineText = s.substring(with: NSRange(location: lineStart, length: caret - lineStart))

        let indentUnits = BlockTree.leadingWhitespaceUnits(lineText)
        let afterIndent = lineText.drop { $0 == "\t" || $0 == " " }
        let isEmptyBullet = afterIndent == "-" || afterIndent == "*"

        if isEmptyBullet {
            // Exit the list: clear the empty bullet and insert a plain newline.
            let clearRange = NSRange(location: lineStart, length: lineText.count)
            replaceCharacters(in: clearRange, with: "")
            super.insertNewline(sender)
            return
        }
        // Continue numbered lists too: "- 1. foo" -> next "2.".
        if let number = trailingListNumber(lineText) {
            let indent = String(repeating: "\t", count: indentUnits)
            insertText("\n" + indent + "- \(number + 1). ", replacementRange: selectedRange())
            return
        }
        let indent = String(repeating: "\t", count: indentUnits)
        insertText("\n" + indent + "- ", replacementRange: selectedRange())
    }

    private func trailingListNumber(_ lineText: String) -> Int? {
        let afterIndent = lineText.drop { $0 == "\t" || $0 == " " }
        guard afterIndent.hasPrefix("- ") else { return nil }
        let rest = afterIndent.dropFirst(2)
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty,
              rest.count > digits.count + 1,
              rest.index(rest.startIndex, offsetBy: digits.count) == rest.firstIndex(of: ".") else { return nil }
        return Int(digits)
    }

    override func insertTab(_ sender: Any?) {
        let s = string as NSString
        let caret = selectedRange().location
        let lineRange = s.lineRange(for: NSRange(location: min(caret, s.length), length: 0))
        let lineText = s.substring(with: lineRange)
        guard let firstChar = lineText.first else {
            insertText("\t", replacementRange: selectedRange())
            return
        }
        guard firstChar == "\t" || firstChar == " " else {
            insertText("\t", replacementRange: selectedRange())
            return
        }
        shouldChangeText(in: lineRange, replacementString: "\t" + lineText)
        replaceCharacters(in: lineRange, with: "\t" + lineText)
        didChangeText()
        selectedRange = NSRange(location: min(caret + 1, (string as NSString).length), length: 0)
    }

    override func insertBacktab(_ sender: Any?) {
        let s = string as NSString
        let caret = selectedRange().location
        let lineRange = s.lineRange(for: NSRange(location: min(caret, s.length), length: 0))
        var lineText = s.substring(with: lineRange)
        guard lineText.hasPrefix("\t") else { return }
        lineText.removeFirst()
        shouldChangeText(in: lineRange, replacementString: lineText)
        replaceCharacters(in: lineRange, with: lineText)
        didChangeText()
        selectedRange = NSRange(location: max(caret - 1, 0), length: 0)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Slash command expansion: "/todo " -> "TODO "
        if let typed = string as? String, typed.hasSuffix(" ") {
            let s = self.string as NSString
            let caret = replacementRange.location
            if caret > 0 {
                let scanStart = max(0, caret - 16)
                let window = s.substring(with: NSRange(location: scanStart, length: caret - scanStart))
                for (slash, marker) in slashMarkers {
                    if window.hasSuffix(slash) {
                        let replaceLen = slash.count
                        let wordStart = caret - replaceLen
                        // Require the slash to be at line start or after whitespace.
                        let before = wordStart > 0
                            ? s.substring(with: NSRange(location: wordStart - 1, length: 1))
                            : "\n"
                        if before == " " || before == "\t" || before == "\n" || wordStart == 0 {
                            let range = NSRange(location: wordStart, length: replaceLen)
                            super.insertText(marker + " ", replacementRange: range)
                            return
                        }
                    }
                }
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    // MARK: - Drag & drop (images -> assets/, URLs & files -> links)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        editorDropProposal(sender) == nil ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        editorDropProposal(sender) == nil ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let (insertion, markdown) = editorDropProposal(sender) {
            selectedRange = insertion
            insertText(markdown, replacementRange: insertion)
            return true
        }
        return super.performDragOperation(sender)
    }

    /// What a drop would insert, and where. Nil means "not ours".
    private func editorDropProposal(_ sender: NSDraggingInfo) -> (NSRange, String)? {
        let pasteboard = sender.draggingPasteboard

        // Drop caret position under the cursor.
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndex(for: point)
        let s = string as NSString
        let insertion = index != NSNotFound
            ? NSRange(location: min(index, s.length), length: 0)
            : NSRange(location: s.length, length: 0)

        // Image file(s) from Finder / Photos.
        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !fileURLs.isEmpty {
            var snippets: [String] = []
            for url in fileURLs {
                let name = url.lastPathComponent
                if let ext = url.pathExtension.lowercased() as String?,
                   ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext) {
                    if let data = try? Data(contentsOf: url),
                       let embed = imageImporter?(data, name) {
                        snippets.append(embed)
                        continue
                    }
                }
                // Non-image file: relative/absolute link with the filename.
                snippets.append("[\(dropTitle(name))](\(url.absoluteString))")
            }
            return (insertion, "\n" + snippets.joined(separator: "\n") + "\n")
        }

        // Inline image data (e.g. dragged out of a browser).
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let embed = imageImporter?(data, nil) {
                return (insertion, "\n\(embed)\n")
            }
        }

        // Web URLs (links, or direct image URLs).
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let url = urls.first, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            let path = url.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "gif", "webp"].contains(path) {
                return (insertion, "\n![](\(url.absoluteString))\n")
            }
            let title = pasteboard.string(forType: .string) ?? url.host ?? url.absoluteString
            return (insertion, "[\(dropTitle(title))](\(url.absoluteString))")
        }
        return nil
    }

    private func dropTitle(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .replacingOccurrences(of: "\n", with: " ")
        return cleaned.isEmpty ? "link" : cleaned
    }

    // MARK: - Syntax highlighting

    private var markerColors: [String: NSColor] {
        [
            "TODO": .systemOrange,
            "DOING": .systemBlue,
            "LATER": .systemPurple,
            "NOW": .systemRed,
            "DONE": .systemGreen,
        ]
    }

    func highlight() {
        guard let storage = textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        let baseFont = font ?? .systemFont(ofSize: 14)
        let baseColor = NSColor.labelColor

        storage.beginEditing()
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: baseColor,
        ], range: full)

        let text = storage.string
        let lines = text.components(separatedBy: "\n")
        var lineStart = 0
        for line in lines {
            defer { lineStart += line.count + 1 }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let indentLen = line.count - (line.drop { $0 == "\t" || $0 == " " }).count

            // Headings.
            if trimmed.hasPrefix("#") {
                let r = NSRange(location: lineStart, length: line.count)
                storage.addAttributes([
                    .font: NSFont.systemFont(ofSize: baseFont.pointSize + 1.5, weight: .semibold),
                ], range: r)
                continue
            }

            // TODO-family markers on bullet lines.
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let afterBullet = trimmed.dropFirst(2)
                for (marker, color) in markerColors {
                    if afterBullet.hasPrefix(marker + " ") || afterBullet == marker {
                        let markerOffset = indentLen + 2
                        let r = NSRange(location: lineStart + markerOffset, length: marker.count)
                        storage.addAttributes([
                            .foregroundColor: color,
                            .font: NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold),
                        ], range: r)
                        break
                    }
                }
            }
        }

        // Wikilinks, code spans, emphasis — regex over the whole text.
        let nsText = text as NSString
        func paint(pattern: String, attributes: [NSAttributedString.Key: Any]) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            regex.enumerateMatches(in: text, range: full) { match, _, _ in
                guard let match else { return }
                storage.addAttributes(attributes, range: match.range)
            }
        }
        paint(pattern: #"\[\[[^\[\]\n]+\]\]"#, attributes: [
            .foregroundColor: NSColor.controlAccentColor,
        ])
        paint(pattern: #"`[^`\n]+`"#, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular),
            .foregroundColor: NSColor.systemBrown,
        ])
        paint(pattern: #"\*\*[^*\n]+\*\*"#, attributes: [
            .font: NSFont.systemFont(ofSize: baseFont.pointSize, weight: .bold),
        ])
        storage.endEditing()
    }
}
