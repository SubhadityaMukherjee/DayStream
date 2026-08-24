import SwiftUI
import AppKit

/// A non-scrolling, content-fitting markdown editor with outliner niceties:
/// - Enter continues the bullet at the same indent (empty bullet exits the list)
/// - Tab / Shift-Tab indent / outdent the current line
/// - `/todo `, `/doing `, `/later `, `/done ` expand to TODO-style markers
/// - Escape flushes the pending save (callers decide what "done" means)
/// - ⌘S auto-formats and saves via `onSaveCommit` (callers normalize text first)
/// - ⌘K links the selection (URL on the clipboard -> `[text](url)`, else `[[wikilink]]`)
/// - ⌘⏎ toggles the current line's TODO/DONE marker (sync handled by caller)
/// - Typing `[[` suggests existing page names; ↑/↓ pick, ⏎/⇥ complete
/// - Drag & drop images into `assets/`, URLs and files as links
/// - Live preview: markdown syntax renders and hides on lines away from the
///   caret (glyph-level — the raw text never changes; see LiveMarkdown)
///
/// Data flow: the text view owns the text while editing. `text` is read only
/// at creation, and external corrections arrive via `pushedText` — keystrokes
/// never round-trip through SwiftUI state. (A `Binding` here re-rendered the
/// hosting section on every keystroke, which churned the glass layout and
/// made typing laggy with a visually jumpy caret.)
struct MarkdownEditorView: NSViewRepresentable {
    /// Text the editor starts with (captured when the view is created).
    var text: String
    /// External text to push into the editor (watcher adoption, add-todo).
    /// nil = leave the editor alone; repeats of the last applied value are
    /// ignored, and equal-to-current text is a no-op.
    var pushedText: String? = nil
    /// nil = resolve from settings at view-update time, cached by signature.
    var font: NSFont? = nil
    /// Importer for dropped images; nil disables image importing.
    var imageImporter: ((Data, String?) -> String?)? = nil
    /// Existing `[[page]]` names for autocomplete; nil disables suggestions.
    var pageNamesProvider: (() -> [String])? = nil
    var onTextChanged: ((String) -> Void)? = nil
    var onCommit: (() -> Void)? = nil
    var onSaveCommit: (() -> Void)? = nil
    /// ⌘-click on a `[[wikilink]]` (or a `[label](url)` with a real URL)
    /// fires this with the `daystream://`/http URL; callers route it through
    /// the environment's openURL action (MainView handles daystream://).
    var onOpenLink: ((URL) -> Void)? = nil
    /// Fired after ⌘⏎ toggles a line's marker: the task content (text minus
    /// bullet/marker) and whether it is now done. Callers echo the state to
    /// matching tasks in other notes via `VaultStore.syncTodoState`.
    var onTodoToggled: ((_ taskContent: String, _ nowDone: Bool) -> Void)? = nil
    /// Increment to move the caret to the end on the next update (used after
    /// appending a task template, where preserving the old caret is wrong).
    var caretAtEndRequest: Int = 0

    func makeNSView(context: Context) -> EditorContainerView {
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
        tv.textContainerInset = Self.inset(liveMarkdown: AppSettings.shared.liveMarkdownRendering)
        tv.textContainer?.lineFragmentPadding = 4
        // Content-fitting, not scrolling: width tracks the container, height
        // is whatever the text needs (set in the container's layout pass).
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.string = text
        tv.revealAllSyntaxInitially()
        tv.layoutManager?.delegate = tv
        tv.liveMarkdownEnabled = AppSettings.shared.liveMarkdownRendering
        context.coordinator.appliedLiveMarkdown = tv.liveMarkdownEnabled
        tv.delegate = context.coordinator
        tv.onCommit = onCommit
        tv.onSaveCommit = onSaveCommit
        tv.onTodoToggled = onTodoToggled
        tv.onOpenLink = onOpenLink
        tv.imageImporter = imageImporter
        tv.pageNamesProvider = pageNamesProvider
        tv.highlight()
        context.coordinator.appliedFontSignature = Self.fontSignature(tv.font)
        context.coordinator.installSpaceMonitor(for: tv)

        let container = EditorContainerView()
        container.editor = tv
        tv.autoresizingMask = [.width]
        container.addSubview(tv)

        // Focus is opt-in: every day in the stream is an editor now, and a
        // cell materialized by scrolling must never steal first responder.
        // ⌘N-style flows bump `caretAtEndRequest`, which focuses here (cell
        // not yet alive) or in updateNSView (already alive).
        context.coordinator.lastCaretAtEndRequest = caretAtEndRequest
        DispatchQueue.main.async {
            if caretAtEndRequest > 0 {
                tv.window?.makeFirstResponder(tv)
            }
            let end = NSRange(location: (tv.string as NSString).length, length: 0)
            tv.selectedRange = end
            tv.scrollRangeToVisible(end)
        }
        return container
    }

    static func dismantleNSView(_ nsView: EditorContainerView, coordinator: Coordinator) {
        coordinator.removeSpaceMonitor()
        nsView.editor?.closeSuggestions()
    }

    func updateNSView(_ nsView: EditorContainerView, context: Context) {
        guard let tv = nsView.editor else { return }
        tv.onTextChanged = onTextChanged
        tv.onCommit = onCommit
        tv.onSaveCommit = onSaveCommit
        tv.onTodoToggled = onTodoToggled
        tv.onOpenLink = onOpenLink
        tv.imageImporter = imageImporter
        tv.pageNamesProvider = pageNamesProvider

        if let pushed = pushedText, pushed != context.coordinator.appliedPushedText {
            context.coordinator.appliedPushedText = pushed
            if tv.string != pushed {
                tv.applyExternalText(pushed)
            }
        }
        if context.coordinator.lastCaretAtEndRequest != caretAtEndRequest {
            context.coordinator.lastCaretAtEndRequest = caretAtEndRequest
            tv.window?.makeFirstResponder(tv)
            let end = NSRange(location: (tv.string as NSString).length, length: 0)
            tv.selectedRange = end
            tv.scrollRangeToVisible(end)
        }
        let resolvedFont = font ?? AppSettings.shared.editorFont()
        // NSFont instances created from descriptors don't reliably compare
        // equal, so cache by signature — re-applying the font (plus a full
        // re-highlight) on every update made typing heavy.
        let signature = Self.fontSignature(resolvedFont)
        if signature != context.coordinator.appliedFontSignature {
            context.coordinator.appliedFontSignature = signature
            tv.font = resolvedFont
            tv.highlight()
            nsView.invalidateIntrinsicContentSize()
        }
        let liveRendering = AppSettings.shared.liveMarkdownRendering
        if context.coordinator.appliedLiveMarkdown != liveRendering {
            context.coordinator.appliedLiveMarkdown = liveRendering
            tv.liveMarkdownEnabled = liveRendering
        }
    }

    /// Horizontal inset doubles as the glyph gutter: when live preview is on,
    /// checkboxes / bullet dashes draw there and every line's text starts at
    /// a fixed column — content never shifts between raw and rendered states.
    static func inset(liveMarkdown: Bool) -> NSSize {
        NSSize(width: liveMarkdown ? 24 : 0, height: 6)
    }

    private static func fontSignature(_ font: NSFont?) -> String {
        guard let font else { return "" }
        return "\(font.fontName)|\(font.pointSize)"
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var appliedPushedText: String?
        var lastCaretAtEndRequest = 0
        var appliedFontSignature: String?
        var appliedLiveMarkdown: Bool?
        private var spaceMonitor: Any?
        private weak var textView: EditorTextView?

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
            guard let tv = notification.object as? EditorTextView else { return }
            tv.handleTextChanged()
            tv.onTextChanged?(tv.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? EditorTextView else { return }
            tv.refreshActiveLineHiding()
        }

        /// ⌘-click on a link-attributed range (AppKit requires ⌘ in editable
        /// text views): route the URL to the caller, which hands it to the
        /// environment's openURL action.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let tv = textView as? EditorTextView else { return false }
            let url: URL?
            switch link {
            case let u as URL: url = u
            case let s as String: url = URL(string: s)
            default: url = nil
            }
            guard let url else { return false }
            tv.onOpenLink?(url)
            return true
        }
    }
}

/// Editor state that changes on every keystroke, deliberately held *outside*
/// SwiftUI's invalidation graph (a class instance inside `@State`): writing
/// `text`/`isDirty` @State per keystroke re-rendered the hosting section and
/// its glass chrome on every key press. Callers keep the session as the
/// source of truth for saves and edit/commit flows.
final class EditorSession {
    var text = ""
    /// File text as of the last sync (start of editing, our own save, or an
    /// external update). Used to detect external changes while editing.
    var base = ""
    var saveTask: Task<Void, Never>?

    var isClean: Bool { text == base }

    func cancelSave() {
        saveTask?.cancel()
        saveTask = nil
    }
}

/// Content-fitting host for the text view. No scrolling of its own — the
/// enclosing stream does all of it. (An inner NSScrollView, even with no
/// scrollers, intercepted wheel events at the editor's edges and made the
/// stream sticky.) Sizes itself to the full text height.
final class EditorContainerView: NSView {
    weak var editor: EditorTextView?

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        guard let tv = editor, let container = tv.textContainer, let layout = container.layoutManager else {
            return super.intrinsicContentSize
        }
        layout.ensureLayout(for: container)
        let height = layout.usedRect(for: container).height + tv.textContainerInset.height * 2 + 8
        return NSSize(width: -1, height: max(height, 96))
    }

    override func layout() {
        super.layout()
        guard let tv = editor, let container = tv.textContainer, let layout = container.layoutManager else { return }
        layout.ensureLayout(for: container)
        let height = layout.usedRect(for: container).height + tv.textContainerInset.height * 2
        tv.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
    }
}

final class EditorTextView: NSTextView {
    var onTextChanged: ((String) -> Void)?
    var onCommit: (() -> Void)?
    var onSaveCommit: (() -> Void)?
    var onTodoToggled: ((_ taskContent: String, _ nowDone: Bool) -> Void)?
    var onOpenLink: ((URL) -> Void)?
    var imageImporter: ((Data, String?) -> String?)? = nil
    var pageNamesProvider: (() -> [String])? = nil
    private var suggest: WikiSuggestController?
    /// Edit recorded in shouldChangeText (UTF-16 range after the edit) and
    /// consumed by the next handleTextChanged for line-local highlighting.
    private var pendingEditRange: NSRange?
    /// External replacement deferred while an input method has marked text.
    private var pendingExternalText: String?
    /// Idle-timer that reconciles cross-line effects (fences) after typing.
    private var highlightReconcileTask: Task<Void, Never>?
    /// Live markdown preview: syntax on lines away from the caret renders as
    /// null (zero-width) glyphs; the raw characters never leave the storage.
    var liveMarkdownEnabled = true {
        didSet {
            guard oldValue != liveMarkdownEnabled else { return }
            textContainerInset = MarkdownEditorView.inset(liveMarkdown: liveMarkdownEnabled)
            revealAllSyntaxInitially()
            decorationsDirty = true
            invalidateAllGlyphs()
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    /// Full line(s) the selection touches — their syntax stays visible so
    /// the line being edited always shows its raw markdown.
    private var activeLineCharRange = NSRange(location: 0, length: 0)
    private var lastFenceLineCount = -1

    /// One bullet line's rendered marker (drawn in the gutter).
    struct LineDecoration {
        let lineRange: NSRange
        /// TODO/DOING/LATER/NOW/DONE, nil for plain bullets.
        let marker: String?
        /// "2h 15m" for finished tasks that carry added:: + completed::.
        let duration: String?
    }
    private(set) var decorations: [LineDecoration] = []
    private var decorationsDirty = true
    /// Checkbox rects from the last draw pass — the click target list.
    private(set) var checkboxRects: [(rect: NSRect, lineRange: NSRange)] = []
    private var lastCheckboxRectsKey = ""

    deinit {
        highlightReconcileTask?.cancel()
    }

    // MARK: - Text change plumbing

    /// Content height changed: tell the hosting container so SwiftUI
    /// re-sizes the day's row.
    func invalidateFittingSize() {
        (superview as? EditorContainerView)?.invalidateIntrinsicContentSize()
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let ok = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if ok {
            let replacementLength = (replacementString as NSString?)?.length ?? 0
            pendingEditRange = NSRange(location: affectedCharRange.location, length: replacementLength)
        }
        return ok
    }

    /// Runs on every text change: deferred external replacements, live
    /// highlighting of the edited line, wikilink suggestions, and the
    /// content-fitting size refresh. Stays entirely inside the text view so
    /// a keystroke never triggers SwiftUI work.
    func handleTextChanged() {
        applyPendingExternalText()
        highlightPendingEdit()
        refreshActiveLineHiding()
        updateSuggestions()
        invalidateFittingSize()
        decorationsDirty = true
        needsDisplay = true
    }

    /// Replaces the whole text with an externally produced version, keeping
    /// the caret (clamped) so reading and typing positions survive. During
    /// an input-method session the swap is deferred — replacing under marked
    /// text corrupts the composition.
    func applyExternalText(_ newText: String) {
        guard !hasMarkedText() else {
            pendingExternalText = newText
            return
        }
        pendingEditRange = nil
        let sel = selectedRange()
        revealAllSyntaxInitially()
        string = newText
        highlight()
        selectedRange = NSRange(location: min(sel.location, (newText as NSString).length), length: 0)
        scrollRangeToVisible(selectedRange)
        refreshActiveLineHiding()
        invalidateFittingSize()
    }
    private func applyPendingExternalText() {
        guard let pending = pendingExternalText, !hasMarkedText() else { return }
        pendingExternalText = nil
        applyExternalText(pending)
    }

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
        if event.clickCount == 1 {
            let point = convert(event.locationInWindow, from: nil)
            // Checkbox clicks toggle without taking focus or moving the
            // caret: focusing would surface this editor's dormant selection
            // (the end-of-text position set at creation) and drag the caret
            // there. The toggle itself needs no first responder.
            let sloppy = NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
            for (rect, lineRange) in checkboxRects where rect.intersects(sloppy) {
                toggleTodo(atLineStart: lineRange.location)
                return
            }
            // On the caret's line the raw marker word shows instead of the
            // checkbox — clicking the word toggles too. ±1 char because
            // characterIndex snaps to the nearest glyph boundary.
            let index = characterIndex(for: point)
            if index != NSNotFound, let marker = todoMarkerRange(around: index) {
                let len = (string as NSString).length
                let near = [max(index - 1, 0), index, min(index + 1, len)]
                if near.contains(where: { NSLocationInRange($0, marker.marker) }) {
                    selectedRange = NSRange(location: marker.lineStart, length: 0)
                    toggleTodoOnCurrentLine()
                    return
                }
            }
        }
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    /// Marker word + enclosing line if `index` sits on a TODO-family marker.
    private func todoMarkerRange(around index: Int) -> (lineStart: Int, marker: NSRange)? {
        let s = string as NSString
        guard index <= s.length else { return nil }
        let lineRange = s.lineRange(for: NSRange(location: min(index, s.length), length: 0))
        guard lineRange.length > 0 else { return nil }
        let line = s.substring(with: lineRange)
        guard let inLine = LiveMarkdown.todoMarkerRange(inLine: line) else { return nil }
        let absolute = NSRange(location: lineRange.location + inLine.location, length: inLine.length)
        guard NSLocationInRange(index, absolute) else { return nil }
        return (lineRange.location, absolute)
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

    // MARK: - ⌘⏎ / checkbox: toggle TODO/DONE

    private func toggleTodoOnCurrentLine() {
        let s = string as NSString
        let caret = selectedRange().location
        let lineStart = s.lineRange(for: NSRange(location: min(caret, s.length), length: 0)).location
        toggleTodo(atLineStart: lineStart)
    }

    /// Toggles without moving the caret: checkbox clicks must keep the line
    /// inactive, or it flips to raw syntax ("TODO" text) and back — a flash.
    private func toggleTodo(atLineStart lineStart: Int) {
        let s = string as NSString
        guard lineStart <= s.length else { return }
        let lineRange = s.lineRange(for: NSRange(location: lineStart, length: 0))
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
                if to == "DONE" {
                    stampCompletion(lineStart: lineRange.location)
                }
                let content = rest.dropFirst(from.count).trimmingCharacters(in: .whitespaces)
                onTodoToggled?(content, to == "DONE")
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
        onTodoToggled?(rest, false)
    }

    /// Records when a task was finished, exactly like the old rendered-view
    /// checkbox did (`VaultStore.toggleTodo` → `withCompletionStamp`): a
    /// `completed::` property line under the bullet, updated in place on
    /// re-completion. Without this, duration badges never light up for
    /// editor-toggled tasks.
    private func stampCompletion(lineStart: Int) {
        let s = string as NSString
        let lineIndex = s.substring(to: lineStart).components(separatedBy: "\n").count - 1
        let stamped = NoteFormatter.withCompletionStamp(s as String, blockLineIndex: lineIndex, at: Date())
        guard stamped != s as String else { return }
        applyExternalText(stamped)
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

    /// Patterns are line-local (`\n` excluded) and live in LiveMarkdown,
    /// shared with the live-preview hider so styling and hiding always
    /// agree on what counts as syntax.

    func highlight() {
        guard let storage = textStorage else { return }
        decorationsDirty = true
        needsDisplay = true
        let full = NSRange(location: 0, length: storage.length)
        let baseFont = font ?? .systemFont(ofSize: 14)

        storage.beginEditing()
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
        ], range: full)

        let s = storage.string as NSString
        var inFence = false
        s.enumerateSubstrings(in: full, options: .byLines) { substring, lineRange, _, _ in
            let fenceBeforeLine = inFence
            if let substring, BlockTree.fenceMarker(substring.trimmingCharacters(in: .whitespaces)) != nil {
                inFence.toggle()
            }
            self.styleLine(lineRange, in: s, storage: storage, baseFont: baseFont, inFence: fenceBeforeLine)
        }
        storage.endEditing()
    }

    /// Highlights only the lines touched by the last edit. Fenced-code state
    /// is derived by scanning the preceding lines (cheap prefix checks), so
    /// the edited line renders exactly as a full pass would paint it.
    private func highlightPendingEdit() {
        guard let storage = textStorage else { return }
        defer { pendingEditRange = nil }
        guard let edited = pendingEditRange else { return }
        let s = storage.string as NSString
        guard edited.location <= s.length else { return }
        let clamped = NSRange(location: edited.location,
                              length: min(edited.length, s.length - edited.location))
        let lineRange = s.lineRange(for: clamped)
        let baseFont = font ?? .systemFont(ofSize: 14)
        let inFence = fenceOpen(before: lineRange.location, in: s)
        storage.beginEditing()
        styleLine(lineRange, in: s, storage: storage, baseFont: baseFont, inFence: inFence)
        storage.endEditing()
        scheduleHighlightReconcile()
    }

    /// Fence edits change the styling of *following* lines, which the
    /// line-local pass can't know about. A short idle pass over the whole
    /// document reconciles those (and is cheap: no regex compilation).
    private func scheduleHighlightReconcile() {
        highlightReconcileTask?.cancel()
        highlightReconcileTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.highlight()
                self?.reconcileFenceDrivenHiding()
            }
        }
    }

    /// Opening or closing a fence flips which following lines are verbatim
    /// code (their "syntax" is literal text and must not be hidden);
    /// regenerate glyphs when the fence-marker count moved.
    private func reconcileFenceDrivenHiding() {
        let count = fenceLineCount
        defer { lastFenceLineCount = count }
        guard count != lastFenceLineCount else { return }
        invalidateAllGlyphs()
    }

    /// Whether a fenced code block is open at `index` (start of a line).
    private func fenceOpen(before index: Int, in s: NSString) -> Bool {
        guard index > 0 else { return false }
        var open = false
        s.enumerateSubstrings(in: NSRange(location: 0, length: index), options: .byLines) { substring, _, _, _ in
            if let substring, BlockTree.fenceMarker(substring.trimmingCharacters(in: .whitespaces)) != nil {
                open.toggle()
            }
        }
        return open
    }

    /// Subtle metadata color for bookkeeping lines (`added::` stamps):
    /// semi-transparent white on dark glass, semi-transparent black in light
    /// mode so it stays legible either way.
    private static let metadataColor: NSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor.white.withAlphaComponent(0.55)
            : NSColor.black.withAlphaComponent(0.45)
    }

    /// Styles one line (range excludes the newline). Resets base attributes
    /// first so removed markers don't keep stale styling.
    private func styleLine(_ lineRange: NSRange, in s: NSString, storage: NSTextStorage, baseFont: NSFont, inFence: Bool) {
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
        ]
        storage.setAttributes(baseAttrs, range: lineRange)
        guard lineRange.length > 0 else { return }
        let line = s.substring(with: lineRange)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let mono = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular)

        // Bookkeeping properties: quiet gray while visible (on the active
        // line), fully hidden once the caret moves away.
        if LiveMarkdown.isBookkeepingPropertyLine(trimmed) {
            storage.addAttributes([
                .font: mono,
                .foregroundColor: Self.metadataColor,
            ], range: lineRange)
            return
        }

        // Fenced code blocks: monospaced, kept verbatim (no marker, wikilink
        // or emphasis styling inside).
        if BlockTree.fenceMarker(trimmed) != nil {
            storage.addAttributes([
                .font: mono,
                .foregroundColor: NSColor.systemBrown,
            ], range: lineRange)
            return
        }
        if inFence {
            storage.addAttributes([
                .font: mono,
                .foregroundColor: NSColor.labelColor,
            ], range: lineRange)
            return
        }

        // Headings — real ones only; `#hashtags` keep their marker.
        if LiveMarkdown.isHeadingLine(trimmed) {
            storage.addAttributes([
                .font: NSFont.systemFont(ofSize: baseFont.pointSize + 1.5, weight: .semibold),
            ], range: lineRange)
            return
        }

        // TODO-family markers on bullet lines.
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            let afterBullet = trimmed.dropFirst(2)
            for (marker, color) in markerColors {
                if afterBullet.hasPrefix(marker + " ") || afterBullet == marker {
                    // Indent is tabs/spaces only, so scalar and UTF-16 counts
                    // agree here.
                    let indentLen = line.count - (line.drop { $0 == "\t" || $0 == " " }).count
                    let markerOffset = indentLen + 2
                    let r = NSRange(location: lineRange.location + markerOffset, length: marker.count)
                    if r.location >= lineRange.location,
                       NSMaxRange(r) <= NSMaxRange(lineRange) {
                        storage.addAttributes([
                            .foregroundColor: color,
                            .font: NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold),
                        ], range: r)
                        // Finished tasks strike through and dim their
                        // content, like the old rendered rows did.
                        if marker == "DONE", NSMaxRange(r) < NSMaxRange(lineRange) {
                            storage.addAttributes([
                                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                .foregroundColor: NSColor.secondaryLabelColor,
                            ], range: NSRange(location: NSMaxRange(r), length: NSMaxRange(lineRange) - NSMaxRange(r)))
                        }
                    }
                    break
                }
            }
        }

        // Wikilinks, code spans, emphasis — line-local by pattern.
        func paint(_ regex: NSRegularExpression, _ attributes: [NSAttributedString.Key: Any]) {
            regex.enumerateMatches(in: s as String, range: lineRange) { match, _, _ in
                if let match {
                    storage.addAttributes(attributes, range: match.range)
                }
            }
        }
        // Wikilinks — link-colored, underlined, and ⌘-clickable: the
        // daystream:// URL routes through MainView's openURL action, same
        // as the old rendered links. The hidden [[ ]] glyphs keep the
        // attribute, so the visible name is the click target.
        LiveMarkdown.wikilinkRegex.enumerateMatches(in: s as String, range: lineRange) { match, _, _ in
            guard let match else { return }
            var attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.readableLink,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
            let inner = NSRange(location: match.range.location + 2, length: match.range.length - 4)
            if inner.length > 0, let url = WikiName.linkURL(forWikilink: s.substring(with: inner)) {
                attrs[.link] = url
            }
            storage.addAttributes(attrs, range: match.range)
        }
        paint(LiveMarkdown.codeSpanRegex, [
            .font: mono,
            .foregroundColor: NSColor.systemBrown,
        ])
        paint(LiveMarkdown.boldRegex, [
            .font: NSFont.systemFont(ofSize: baseFont.pointSize, weight: .bold),
        ])

        // Italic content — matches overlapping a bold span are its markers.
        var boldMatches: [NSRange] = []
        LiveMarkdown.boldRegex.enumerateMatches(in: s as String, range: lineRange) { match, _, _ in
            if let match { boldMatches.append(match.range) }
        }
        LiveMarkdown.italicRegex.enumerateMatches(in: s as String, range: lineRange) { match, _, _ in
            guard let match,
                  !boldMatches.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
            else { return }
            let content = NSRange(location: match.range.location + 1, length: match.range.length - 2)
            guard content.length > 0 else { return }
            storage.addAttributes(
                [.font: NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)],
                range: content)
        }

        // Markdown links: label reads as a link; brackets and URL hide
        // when the line is away from the caret (see LiveMarkdown). Real
        // http(s)/daystream destinations are ⌘-clickable like wikilinks.
        LiveMarkdown.linkRegex.enumerateMatches(in: s as String, range: lineRange) { match, _, _ in
            guard let match else { return }
            let matchText = s.substring(with: match.range) as NSString
            let close = matchText.range(of: "]")
            guard close.location != NSNotFound, close.location >= 2 else { return }
            var attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.readableLink,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
            // "(url)" runs from after "]" to the last char before ")".
            if close.location + 2 < matchText.length - 1 {
                let dest = matchText.substring(
                    with: NSRange(location: close.location + 2, length: matchText.length - close.location - 3))
                let lower = dest.lowercased()
                if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("daystream://"),
                   let url = URL(string: dest) {
                    attrs[.link] = url
                }
            }
            storage.addAttributes(attrs, range: NSRange(location: match.range.location + 1, length: close.location - 1))
        }
    }

    // MARK: - Gutter decorations (checkboxes, bullet dashes, duration badges)

    /// On inactive lines the bullet prefix renders away (null glyphs) and a
    /// marker glyph is drawn in the gutter instead: a checkbox for task
    /// lines, a dash for plain bullets. The caret's line keeps its raw
    /// syntax, mirroring how the rest of the live preview behaves.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard liveMarkdownEnabled, let layoutManager, let container = textContainer else {
            checkboxRects = []
            return
        }
        if decorationsDirty { rebuildDecorations() }
        checkboxRects = []
        let s = string as NSString
        let baseFont = font ?? .systemFont(ofSize: 14)

        for deco in decorations {
            guard deco.lineRange.length > 0,
                  NSIntersectionRange(deco.lineRange, activeLineCharRange).length == 0
            else { continue }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: deco.lineRange, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { continue }
            let fragment = layoutManager.lineFragmentRect(
                forGlyphAt: glyphRange.location, effectiveRange: nil)

            // Content start x: first glyph after the hidden prefix.
            let line = s.substring(with: deco.lineRange)
            let prefix = LiveMarkdown.renderableBulletPrefix(inLine: line) ?? NSRange(location: 0, length: 0)
            let contentStart = deco.lineRange.location + prefix.location + prefix.length
            var contentX = fragment.minX
            if contentStart < NSMaxRange(deco.lineRange) {
                let contentGlyphs = layoutManager.glyphRange(
                    forCharacterRange: NSRange(location: contentStart, length: 1), actualCharacterRange: nil)
                if contentGlyphs.length > 0 {
                    contentX = layoutManager.boundingRect(
                        forGlyphRange: NSRange(location: contentGlyphs.location, length: 1), in: container).minX
                }
            }

            if deco.marker != nil {
                let box = drawCheckbox(in: fragment, contentX: contentX, done: deco.marker == "DONE")
                checkboxRects.append((box, deco.lineRange))
            } else {
                drawBulletDash(contentX: contentX, fragment: fragment, baseFont: baseFont)
            }
            if let duration = deco.duration {
                drawDurationBadge(duration, fragment: fragment)
            }
        }
        // Cursor rects only rebuild on mouse-move/geometry events; ask the
        // window for a refresh when the checkbox set actually changed.
        let key = checkboxRects
            .map { "\(Int($0.rect.minX))~\(Int($0.rect.minY))" }
            .joined(separator: "|")
        if key != lastCheckboxRectsKey {
            lastCheckboxRectsKey = key
            window?.invalidateCursorRects(for: self)
        }
    }

    /// Pointing hand over checkboxes — added after super so they win over
    /// the text view's I-beam where they overlap.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard liveMarkdownEnabled else { return }
        for (rect, _) in checkboxRects {
            addCursorRect(rect.insetBy(dx: -3, dy: -3), cursor: .pointingHand)
        }
    }

    private func drawCheckbox(in fragment: NSRect, contentX: CGFloat, done: Bool) -> NSRect {
        let size: CGFloat = 13.5
        let x = contentX + textContainerInset.width - size - 6
        let y = fragment.midY + textContainerInset.height - size / 2
        let rect = NSRect(x: x, y: y, width: size, height: size)
        let box = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        box.lineWidth = 1.3
        let color: NSColor = done ? .systemGreen : .secondaryLabelColor.withAlphaComponent(0.65)
        color.setStroke()
        box.stroke()
        if done {
            // Flipped coordinates (NSTextView): y grows downward, so a "✓"
            // goes down to the bottom-middle, then up to the top-right.
            let check = NSBezierPath()
            check.move(to: NSPoint(x: rect.minX + 3.1, y: rect.minY + size * 0.56))
            check.line(to: NSPoint(x: rect.minX + size * 0.42, y: rect.minY + size * 0.82))
            check.line(to: NSPoint(x: rect.maxX - 2.9, y: rect.minY + size * 0.24))
            check.lineWidth = 1.8
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.systemGreen.setStroke()
            check.stroke()
        }
        return rect
    }

    private func drawBulletDash(contentX: CGFloat, fragment: NSRect, baseFont: NSFont) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: baseFont.pointSize, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let dash = "-" as NSString
        let size = dash.size(withAttributes: attrs)
        let x = contentX + textContainerInset.width - size.width - 9
        let y = fragment.midY + textContainerInset.height - size.height / 2
        dash.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }

    private static let durationAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
        .foregroundColor: NSColor.systemGreen,
    ]
    private static let durationIcon: NSImage? = {
        let base = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemGreen])
        return base?.withSymbolConfiguration(config)
    }()

    /// Completion-time badge for finished tasks, like the old rendered rows:
    /// green capsule at the line's trailing edge (the `completed::` line it
    /// summarizes is hidden and collapsed).
    private func drawDurationBadge(_ duration: String, fragment: NSRect) {
        let text = duration as NSString
        let textSize = text.size(withAttributes: Self.durationAttrs)
        let h: CGFloat = 15
        let iconSize: CGFloat = 9
        let w = 6 + iconSize + 3 + textSize.width + 6
        let x = bounds.width - w - 10
        let y = fragment.midY + textContainerInset.height - h / 2
        let capsule = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h),
                                   xRadius: h / 2, yRadius: h / 2)
        NSColor.systemGreen.withAlphaComponent(0.13).setFill()
        capsule.fill()
        Self.durationIcon?.draw(in: NSRect(x: x + 6, y: y + (h - iconSize) / 2, width: iconSize, height: iconSize))
        text.draw(at: NSPoint(x: x + 6 + iconSize + 3, y: y + (h - textSize.height) / 2),
                  withAttributes: Self.durationAttrs)
    }

    private func rebuildDecorations() {
        decorationsDirty = false
        decorations = []
        guard let storage = textStorage, storage.length > 0 else { return }
        let text = storage.string
        let lines = text.components(separatedBy: "\n")
        var starts: [Int] = []
        var offset = 0
        for line in lines {
            starts.append(offset)
            offset += (line as NSString).length + 1
        }

        // Duration per task line, from the block parse (`added::`/`completed::`).
        var durations: [Int: String] = [:]
        func collect(_ blocks: [Block]) {
            for block in blocks {
                if block.todoState == .done, block.isBullet, lines.indices.contains(block.lineIndex),
                   let added = block.properties.first(where: { $0.key.lowercased() == "added" })?.value,
                   let completed = block.properties.first(where: { $0.key.lowercased() == "completed" })?.value,
                   let a = NoteFormatter.parseTimestamp(added),
                   let c = NoteFormatter.parseTimestamp(completed),
                   c >= a {
                    durations[starts[block.lineIndex]] = NoteFormatter.duration(from: a, to: c)
                }
                collect(block.children)
            }
        }
        collect(BlockTree.parse(text))

        var inFence = false
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if BlockTree.fenceMarker(trimmed) != nil { inFence.toggle(); continue }
            if inFence { continue }
            let full = NSRange(location: 0, length: (line as NSString).length)
            guard LiveMarkdown.bulletPrefixRegex.firstMatch(in: line, range: full) != nil else { continue }
            let marker = LiveMarkdown.todoMarkerRange(inLine: line)
                .map { String((line as NSString).substring(with: $0)) }
            decorations.append(LineDecoration(
                lineRange: NSRange(location: starts[i], length: (line as NSString).length),
                marker: marker,
                duration: durations[starts[i]]))
        }
    }
}

// MARK: - Live markdown preview

extension EditorTextView {
    /// Everything visible until the first real layout; the caret-landing
    /// selection change then narrows the active line for real.
    func revealAllSyntaxInitially() {
        activeLineCharRange = NSRange(location: 0, length: textStorage?.length ?? 0)
        lastFenceLineCount = fenceLineCount
    }

    /// Re-derives the active line from the selection and regenerates glyphs
    /// for the lines whose visibility flipped. Cheap: two line ranges.
    /// The selection only drives the active line while this text view is the
    /// first responder — dormant editors have no line under edit, so every
    /// line renders live (checkboxes, hidden syntax). Otherwise a stale
    /// caret pins one line raw forever: recurring/deadline tasks prepend at
    /// the top of a note whose editor was created empty (caret 0), and the
    /// pushed text adopts that dead position.
    func refreshActiveLineHiding() {
        guard let layoutManager, let storage = textStorage else { return }
        guard storage.length > 0 else {
            activeLineCharRange = NSRange(location: 0, length: 0)
            return
        }
        let s = storage.string as NSString
        let loc = min(selectedRange().location, s.length)
        let len = min(selectedRange().length, s.length - loc)
        let newActive = window?.firstResponder === self
            ? s.lineRange(for: NSRange(location: loc, length: len))
            : NSRange(location: 0, length: 0)
        guard !NSEqualRanges(newActive, activeLineCharRange) else { return }

        for r in [activeLineCharRange, newActive] where r.length > 0 && r.location < s.length {
            let clamped = NSRange(location: r.location, length: min(r.length, s.length - r.location))
            layoutManager.invalidateGlyphs(forCharacterRange: clamped, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: clamped, actualCharacterRange: nil)
        }
        activeLineCharRange = newActive
        invalidateFittingSize()
        // Marker visibility (checkbox vs raw word) flips with the active line.
        needsDisplay = true
    }

    func invalidateAllGlyphs() {
        guard let layoutManager, let storage = textStorage, storage.length > 0 else { return }
        let full = NSRange(location: 0, length: storage.length)
        layoutManager.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        invalidateFittingSize()
    }

    private var fenceLineCount: Int {
        guard let storage = textStorage, storage.length > 0 else { return 0 }
        let s = storage.string as NSString
        var count = 0
        s.enumerateSubstrings(in: NSRange(location: 0, length: s.length), options: .byLines) { sub, _, _, _ in
            if let sub, BlockTree.fenceMarker(sub.trimmingCharacters(in: .whitespaces)) != nil {
                count += 1
            }
        }
        return count
    }

    /// Hide-set for a glyph-generation chunk: per-line syntax ranges over the
    /// chunk's lines, skipping fenced code and the active line. Fence state
    /// needs a doc-start scan — same cost profile as the existing
    /// fenceOpen(before:) pass; daily notes stay small.
    private func hiddenRanges(forCharacterRange range: NSRange) -> [NSRange] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        let s = storage.string as NSString
        let loc = min(range.location, s.length)
        let len = min(range.length, s.length - loc)
        guard len > 0 else { return [] }
        let covered = s.lineRange(for: NSRange(location: loc, length: len))
        var hidden: [NSRange] = []
        var inFence = false
        s.enumerateSubstrings(in: NSRange(location: 0, length: NSMaxRange(covered)), options: .byLines) { sub, lineRange, _, _ in
            let opensFence = sub.map { BlockTree.fenceMarker($0.trimmingCharacters(in: .whitespaces)) != nil } ?? false
            defer { if opensFence { inFence.toggle() } }
            guard !inFence else { return }
            guard NSIntersectionRange(lineRange, covered).length > 0 else { return }
            guard NSIntersectionRange(lineRange, self.activeLineCharRange).length == 0 else { return }
            guard let sub, !sub.isEmpty else { return }
            // Bookkeeping properties (added::/completed::/id::) vanish
            // entirely — the rendered view never showed them either.
            if LiveMarkdown.isBookkeepingPropertyLine(sub) {
                hidden.append(lineRange)
                return
            }
            hidden.append(contentsOf: LiveMarkdown.hiddenRanges(line: sub, offset: lineRange.location))
        }
        return hidden
    }
}

extension EditorTextView: NSLayoutManagerDelegate {
    /// Hides syntax glyphs (away from the caret's line) by nulling them:
    /// null glyphs draw nothing and take no space, while the characters —
    /// and therefore saves, undo, and caret/IME machinery — stay intact.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        func storeDefaults() {
            layoutManager.setGlyphs(glyphs, properties: properties, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        }
        guard liveMarkdownEnabled, glyphRange.length > 0 else {
            storeDefaults()
            return glyphRange.length
        }
        let charRange = NSRange(location: characterIndexes[0],
                                length: characterIndexes[glyphRange.length - 1] - characterIndexes[0] + 1)
        let hidden = hiddenRanges(forCharacterRange: charRange)
        guard !hidden.isEmpty else {
            storeDefaults()
            return glyphRange.length
        }
        var props = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
        for i in 0..<glyphRange.length {
            let charIndex = characterIndexes[i]
            if hidden.contains(where: { charIndex >= $0.location && charIndex < NSMaxRange($0) }) {
                props[i].insert(.null)
            }
        }
        props.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }

    /// Fully hidden bookkeeping lines (`added::` etc., away from the caret)
    /// collapse to zero height — null glyphs only remove their width, and
    /// the blank stripe they left between tasks read as stray spacing. The
    /// caret entering the line re-expands it (refreshActiveLineHiding
    /// invalidates that line's layout, so this runs again un-collapsed).
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<CGRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<CGRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        if liveMarkdownEnabled, glyphRange.length > 0 {
            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let s = string as NSString
            if charRange.location < s.length {
                let lineRange = s.lineRange(for: NSRange(location: charRange.location, length: 0))
                let line = s.substring(with: lineRange)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if LiveMarkdown.isBookkeepingPropertyLine(line),
                   NSIntersectionRange(lineRange, activeLineCharRange).length == 0 {
                    lineFragmentRect.pointee.size.height = 0
                    lineFragmentUsedRect.pointee.size.height = 0
                }
            }
        }
        return true
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
