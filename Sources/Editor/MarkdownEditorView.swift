import SwiftUI
import AppKit

/// A non-scrolling, content-fitting markdown editor with outliner niceties:
/// - Enter continues the bullet at the same indent (empty bullet exits the list)
/// - Tab / Shift-Tab indent / outdent the current line
/// - `/todo `, `/doing `, `/later `, `/done ` expand to TODO-style markers
/// - Escape ends editing (and flushes the pending save)
/// - ⌘S saves-and-quits via `onSaveCommit` (callers normalize text first)
/// - ⌘K links the selection (URL on the clipboard -> `[text](url)`, else `[[wikilink]]`)
/// - ⌘⏎ toggles the current line's TODO/DONE marker
/// - Typing `[[` suggests existing page names; ↑/↓ pick, ⏎/⇥ complete
/// - Drag & drop images into `assets/`, URLs and files as links
/// - Live highlighting of markers, `[[wikilinks]]`, code spans, headings
struct MarkdownEditorView: NSViewRepresentable {
    @Binding var text: String
    /// nil = resolve from settings at view-update time. A concrete default
    /// here would run AppSettings lookups on every struct re-creation.
    var font: NSFont? = nil
    /// Importer for dropped images; nil disables image importing.
    var imageImporter: ((Data, String?) -> String?)? = nil
    /// Existing `[[page]]` names for autocomplete; nil disables suggestions.
    var pageNamesProvider: (() -> [String])? = nil
    var onTextChanged: ((String) -> Void)? = nil
    var onCommit: (() -> Void)? = nil
    var onSaveCommit: (() -> Void)? = nil
    /// Increment to move the caret to the end on the next update (used after
    /// appending a task template, where preserving the old caret is wrong).
    var caretAtEndRequest: Int = 0

    func makeNSView(context: Context) -> EditorScrollView {
        let tv = EditorTextView()
        tv.font = font ?? AppSettings.shared.editorFont()
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
        tv.onSaveCommit = onSaveCommit
        tv.imageImporter = imageImporter
        tv.pageNamesProvider = pageNamesProvider
        tv.highlight()
        context.coordinator.installSpaceMonitor(for: tv)

        let scroll = EditorScrollView()
        scroll.documentView = tv
        // Overlay scroller: visible while scrolling, gone otherwise. Without
        // a scroller, long notes had no way to see position/length.
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.editor = tv

        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
            let end = NSRange(location: (tv.string as NSString).length, length: 0)
            tv.selectedRange = end
            // Journal content grows at the bottom: land the view there too,
            // not just the caret (the caret alone doesn't scroll the editor).
            tv.scrollRangeToVisible(end)
        }
        return scroll
    }

    static func dismantleNSView(_ nsView: EditorScrollView, coordinator: Coordinator) {
        coordinator.removeSpaceMonitor()
        nsView.editor?.closeSuggestions()
    }

    func updateNSView(_ nsView: EditorScrollView, context: Context) {
        guard let tv = nsView.editor else { return }
        let resolvedFont = font ?? AppSettings.shared.editorFont()
        if tv.string != text, !context.coordinator.isEditingLocally {
            // External change (watcher, carry-forward, add-task). Replacing
            // the whole string moves the caret to the end — restore it
            // (clamped) so the cursor never jumps while reading or typing.
            let sel = tv.selectedRange
            tv.string = text
            tv.highlight()
            tv.selectedRange = NSRange(location: min(sel.location, (text as NSString).length), length: 0)
        }
        if context.coordinator.lastCaretAtEndRequest != caretAtEndRequest {
            context.coordinator.lastCaretAtEndRequest = caretAtEndRequest
            let end = NSRange(location: (text as NSString).length, length: 0)
            tv.selectedRange = end
            tv.scrollRangeToVisible(end)
        }
        if tv.font != resolvedFont {
            tv.font = resolvedFont
            tv.highlight()
        }
        nsView.invalidateIntrinsicContentSize()
        tv.onCommit = onCommit
        tv.onSaveCommit = onSaveCommit
        tv.imageImporter = imageImporter
        tv.pageNamesProvider = pageNamesProvider
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditorView
        var isEditingLocally = false
        var lastCaretAtEndRequest = 0
        private var spaceMonitor: Any?
        private weak var textView: EditorTextView?

        init(_ parent: MarkdownEditorView) {
            self.parent = parent
        }

        deinit {
            removeSpaceMonitor()
        }

        /// SwiftUI's ScrollView (an ancestor of this editor) loves to claim the
        /// unmodified space key for page-scrolling before keyDown reaches the
        /// text view — even performKeyEquivalent doesn't reliably win. A local
        /// keyDown monitor runs before the responder chain, so when this text
        /// view is the active first responder we insert the space ourselves and
        /// swallow the event.
        func installSpaceMonitor(for tv: EditorTextView) {
            textView = tv
            guard spaceMonitor == nil else { return }
            spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let tv = self.textView, event.window === tv.window else { return event }
                guard tv.window?.firstResponder === tv,
                      event.keyCode == 49,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
                else { return event }
                tv.insertText(" ", replacementRange: tv.selectedRange())
                return nil
            }
        }

        func removeSpaceMonitor() {
            if let spaceMonitor {
                NSEvent.removeMonitor(spaceMonitor)
                self.spaceMonitor = nil
            }
            textView = nil
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            isEditingLocally = true
            parent.text = tv.string
            parent.onTextChanged?(tv.string)
            isEditingLocally = false
            (tv as? EditorTextView)?.updateSuggestions()
        }
    }
}

/// Scroll view that sizes itself to fit the text view, so the outer stream scrolls.
/// Tall notes cap at 560pt and scroll inside with the overlay scroller.
final class EditorScrollView: NSScrollView {
    weak var editor: EditorTextView?

    override var intrinsicContentSize: NSSize {
        guard let tv = editor, let container = tv.textContainer, let layout = container.layoutManager else {
            return super.intrinsicContentSize
        }
        layout.ensureLayout(for: container)
        let height = layout.usedRect(for: container).height + tv.textContainerInset.height * 2 + 8
        return NSSize(width: -1, height: min(max(height, 96), 560))
    }
}

final class EditorTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onSaveCommit: (() -> Void)?
    var imageImporter: ((Data, String?) -> String?)? = nil
    var pageNamesProvider: (() -> [String])? = nil
    private var suggest: WikiSuggestController?

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
        if event.keyCode == Keyboard.s, modifiers == .command {
            closeSuggestions()
            onSaveCommit?()
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
        static let s: UInt16 = 1
        static let b: UInt16 = 11
        static let i: UInt16 = 34
        static let returnKey: UInt16 = 36
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // escape
            if suggestionsShown {
                closeSuggestions()
            } else {
                onCommit?()
            }
            return
        }
        super.keyDown(with: event)
    }

    /// Clicks must always land in the text view, even when SwiftUI overlays
    /// tap gestures, or the first responder drifts and typing breaks.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// The suggestion panel is non-activating, so it can't dismiss itself
    /// when focus moves elsewhere; close it here instead.
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { closeSuggestions() }
        return ok
    }

    override func mouseDown(with event: NSEvent) {
        closeSuggestions()
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
        // UTF-16: selection content may contain astral chars (emoji).
        selectedRange = NSRange(location: range.location + prefix.count, length: (selected as NSString).length)
    }

    // MARK: - `[[wikilink]]` autocomplete

    private var suggestionsShown: Bool {
        suggest?.isShown ?? false
    }

    func closeSuggestions() {
        suggest?.close()
    }

    /// Detects an open `[[prefix` at the caret and shows matching page names
    /// in a popover anchored above the caret. Called after every text change.
    func updateSuggestions() {
        guard let provider = pageNamesProvider, window?.firstResponder === self else {
            closeSuggestions()
            return
        }
        guard let context = openWikiContext() else {
            closeSuggestions()
            return
        }
        let lower = context.prefix.lowercased()
        let matches = provider().filter { lower.isEmpty || $0.lowercased().hasPrefix(lower) }
        guard !matches.isEmpty else {
            closeSuggestions()
            return
        }

        if suggest == nil {
            let controller = WikiSuggestController()
            controller.onPick = { [weak self] name in
                self?.completeWikiLink(name)
            }
            suggest = controller
        }
        suggest!.items = Array(matches.prefix(50))
        suggest!.show(for: self, caretRect: caretRectForCaret(at: context.bracketStart))
    }

    /// Screen-space-free caret rect (view coordinates) for a character index.
    private func caretRectForCaret(at charIndex: Int) -> CGRect {
        guard let layoutManager, let container = textContainer else {
            return .zero
        }
        let charRange = NSRange(location: charIndex, length: 0)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        rect.origin.x += textContainerInset.width
        rect.origin.y += textContainerInset.height
        return rect.integral
    }

    /// The `[[` opening before the caret with no closing `]]` yet, if any.
    /// Returns the location of `[[` and the typed prefix since it.
    private func openWikiContext() -> (bracketStart: Int, prefix: String)? {
        let s = string as NSString
        let caret = selectedRange()
        guard caret.length == 0, caret.location > 0 else { return nil }
        let lineStart = s.lineRange(for: NSRange(location: caret.location - 1, length: 0)).location
        let before = s.substring(with: NSRange(location: lineStart, length: caret.location - lineStart)) as NSString
        let found = before.range(of: "[[", options: .backwards)
        guard found.location != NSNotFound else { return nil }
        let prefix = before.substring(from: found.location + 2)
        // Closed link or nested bracket: not an autocomplete target.
        if prefix.contains("]]") || prefix.contains("[") { return nil }
        return (lineStart + found.location, prefix)
    }

    private func completeWikiLink(_ name: String) {
        closeSuggestions()
        guard let context = openWikiContext() else { return }
        let caret = selectedRange()
        let replaceRange = NSRange(location: context.bracketStart, length: caret.location - context.bracketStart)
        let replacement = "[[\(name)]]"
        shouldChangeText(in: replaceRange, replacementString: replacement)
        textStorage?.replaceCharacters(in: replaceRange, with: replacement)
        didChangeText()
        let after = context.bracketStart + (replacement as NSString).length
        selectedRange = NSRange(location: after, length: 0)
    }

    private func completeSelectedSuggestion() {
        guard let suggest, let name = suggest.selectedName else { return }
        completeWikiLink(name)
    }

    // MARK: - Outliner behaviors

    override func insertNewline(_ sender: Any?) {
        if suggestionsShown {
            completeSelectedSuggestion()
            return
        }
        let s = string as NSString
        let caret = selectedRange().location
        let lineStart = (s.lineRange(for: NSRange(location: min(caret, s.length), length: 0)).location)
        let lineText = s.substring(with: NSRange(location: lineStart, length: caret - lineStart))

        let indentUnits = BlockTree.leadingWhitespaceUnits(lineText)
        let afterIndent = lineText.drop { $0 == "\t" || $0 == " " }
        let isEmptyBullet = afterIndent == "-" || afterIndent == "*"

        if isEmptyBullet {
            // Exit the list: clear the empty bullet and insert a plain newline.
            // UTF-16 length: text before the caret can contain astral chars
            // (emoji), where Swift's scalar count diverges from NSString's.
            let clearRange = NSRange(location: lineStart, length: (lineText as NSString).length)
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
        if suggestionsShown {
            completeSelectedSuggestion()
            return
        }
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

    override func moveUp(_ sender: Any?) {
        if suggestionsShown {
            suggest?.moveSelection(-1)
            return
        }
        super.moveUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        if suggestionsShown {
            suggest?.moveSelection(1)
            return
        }
        super.moveDown(sender)
    }

    // MARK: - Syntax highlighting

    private var markerColors: [String: NSColor] {
        [
            "TODO": .systemOrange,
            "DOING": NSColor.readableLink,
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
            // UTF-16 offsets: emoji make a line's scalar count diverge from
            // its storage length, which would shift every later attribute.
            let lineLen = (line as NSString).length
            defer { lineStart += lineLen + 1 }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let indentLen = line.count - (line.drop { $0 == "\t" || $0 == " " }).count

            // Headings.
            if trimmed.hasPrefix("#") {
                let r = NSRange(location: lineStart, length: lineLen)
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
            .foregroundColor: NSColor.readableLink,
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

// MARK: - Wikilink suggestion popover

/// Autocomplete-style wikilink picker: a borderless, non-activating panel
/// floating above the caret. It never becomes key, so typing never leaves
/// the editor; ↑/↓ move the highlight and ⏎/⇥ complete (handled by the
/// text view). A popover would take key focus on show, breaking typing.
final class WikiSuggestController: NSObject {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 0),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered,
                                defer: false)
    private let listView = SuggestListView()
    private let scrollView = SuggestScrollView()
    private let background = NSVisualEffectView()
    /// Width of the editor the panel anchors to; the list matches it so
    /// full page names are readable instead of squeezed into a tiny box.
    private var editorWidth: CGFloat = 320
    private let edgeInset: CGFloat = 4

    static let maxVisibleRows = 8

    var onPick: ((String) -> Void)?

    var items: [String] = [] {
        didSet {
            listView.items = items
            selected = items.isEmpty ? 0 : min(selected, items.count - 1)
            listView.selected = selected
            syncSize()
        }
    }

    var selected: Int = 0

    var selectedName: String? {
        items.indices.contains(selected) ? items[selected] : nil
    }

    var isShown: Bool {
        panel.isVisible
    }

    override init() {
        super.init()
        listView.onPick = { [weak self] index in
            guard let self, self.items.indices.contains(index) else { return }
            self.onPick?(self.items[index])
        }
        scrollView.documentView = listView
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.verticalScrollElasticity = .none

        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        background.addSubview(scrollView)

        panel.contentView = background
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.ignoresMouseEvents = false
    }

    func show(for textView: NSView, caretRect: CGRect) {
        guard !items.isEmpty else { return }
        editorWidth = max(textView.bounds.width, 160)
        listView.selected = selected
        syncSize()
        position(above: caretRect.offsetBy(dx: 0, dy: -1), in: textView)
        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    func close() {
        if panel.isVisible {
            panel.orderOut(nil)
        }
        selected = 0
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + delta + items.count) % items.count
        listView.selected = selected
        listView.needsDisplay = true
        let row = CGRect(x: 0,
                         y: CGFloat(selected) * SuggestListView.rowHeight,
                         width: listView.bounds.width,
                         height: SuggestListView.rowHeight)
        listView.scrollToVisible(row)
    }

    /// Screen-space placement: bottom edge just above the caret, centered
    /// on it, clamped to the screen. Falls below the caret when there is no
    /// room above. Re-runs on every show (each keystroke) so the panel
    /// tracks the caret.
    private func position(above caretRect: CGRect, in textView: NSView) {
        guard let window = textView.window else { return }
        let windowRect = textView.convert(caretRect, to: nil)
        let screenRect = window.convertToScreen(windowRect)
        let size = panel.frame.size
        var origin = CGPoint(x: screenRect.midX - size.width / 2,
                             y: screenRect.maxY + 6)
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
            if origin.y + size.height > visible.maxY {
                origin.y = screenRect.minY - size.height - 6
            }
            origin.y = max(visible.minY, origin.y)
        }
        panel.setFrameOrigin(origin)
    }

    private func syncSize() {
        let width = min(max(editorWidth, 260), 720)
        let rows = max(items.count, 1)
        let visibleRows = min(rows, Self.maxVisibleRows)
        let size = NSSize(width: width,
                          height: CGFloat(visibleRows) * SuggestListView.rowHeight + edgeInset * 2)
        background.frame = NSRect(origin: .zero, size: size)
        scrollView.frame = background.bounds.insetBy(dx: edgeInset, dy: edgeInset)
        listView.frame = NSRect(origin: .zero,
                                size: NSSize(width: width - edgeInset * 2,
                                             height: CGFloat(rows) * SuggestListView.rowHeight))
        panel.setContentSize(size)
    }
}

/// Scroll view that consumes every scroll event itself, including
/// out-of-range ones at the edges: NSScrollView otherwise forwards them up
/// the responder chain, and they escape the non-activating panel into the
/// editor's window, where the stray event nudges the caret.
final class SuggestScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard let doc = documentView else { return }
        let maxY = max(0, doc.bounds.height - contentView.bounds.height)
        let y = max(0, min(contentView.bounds.origin.y - event.scrollingDeltaY, maxY))
        contentView.scroll(to: NSPoint(x: 0, y: y))
        reflectScrolledClipView(contentView)
    }

    override func swipe(with event: NSEvent) {}
}

/// Self-drawing suggestion rows; keeps the popover lightweight and keeps
/// keyboard focus with the editor. Rows are centered; long names truncate.
final class SuggestListView: NSView {
    static let rowHeight: CGFloat = 24

    var items: [String] = [] {
        didSet { needsDisplay = true }
    }
    var selected: Int = 0 {
        didSet { needsDisplay = true }
    }
    var onPick: ((Int) -> Void)?

    private var font = NSFont.systemFont(ofSize: 12.5)

    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        for (i, item) in items.enumerated() {
            let row = CGRect(x: 0, y: CGFloat(i) * Self.rowHeight, width: bounds.width, height: Self.rowHeight)
            let isSelected = i == selected
            if isSelected {
                NSColor.controlAccentColor.setFill()
                row.fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: isSelected ? NSColor.white : NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
            (item as NSString).draw(in: row.insetBy(dx: 9, dy: 0), withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let index = Int(p.y / Self.rowHeight)
        if items.indices.contains(index) {
            onPick?(index)
        }
    }
}
