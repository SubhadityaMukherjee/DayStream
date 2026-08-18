import SwiftUI
import AppKit

/// A non-scrolling, content-fitting markdown editor with outliner niceties:
/// - Enter continues the bullet at the same indent (empty bullet exits the list)
/// - Tab / Shift-Tab indent / outdent the current line
/// - `/todo `, `/doing `, `/later `, `/done ` expand to TODO-style markers
/// - Escape ends editing (and flushes the pending save)
struct MarkdownEditorView: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
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

        let scroll = EditorScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.editor = tv

        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
            tv.selectedRange = NSRange(location: tv.string.count, length: 0)
        }
        return scroll
    }

    func updateNSView(_ nsView: EditorScrollView, context: Context) {
        guard let tv = nsView.editor else { return }
        if tv.string != text, !context.coordinator.isEditingLocally {
            tv.string = text
        }
        nsView.invalidateIntrinsicContentSize()
        tv.onCommit = onCommit
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

    private var slashMarkers: [String: String] {
        ["/todo": "TODO", "/doing": "DOING", "/later": "LATER", "/now": "NOW", "/done": "DONE"]
    }

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
        let indent = String(repeating: "\t", count: indentUnits)
        insertText("\n" + indent + "- ", replacementRange: selectedRange())
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

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // escape
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }
}
