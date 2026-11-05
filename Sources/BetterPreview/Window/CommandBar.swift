import AppKit
import BPCore

@MainActor
protocol CommandBarDelegate: AnyObject {
    /// Return was pressed. The delegate closes the bar.
    func commandBar(_ bar: CommandBar, submit text: String)
    /// Esc, Ctrl-[, Ctrl-c or Backspace on empty text. The delegate closes the bar.
    func commandBarCancel(_ bar: CommandBar)
    /// The text changed by typing (coalesced; only when `incremental`).
    func commandBar(_ bar: CommandBar, didEdit text: String)
    /// Completion candidates for a `:` line, as full replacement lines.
    func commandBarCompletions(for text: String) -> [String]
}

/// The `:` / `/` / `?` input line, shown over the status bar in command mode.
/// Created on first use and reused. Special keys reach it through
/// `handle(_:)` before the field editor sees them; plain typing goes to the
/// text field directly.
@MainActor
final class CommandBar: NSView, NSTextFieldDelegate {
    enum Kind {
        case command, searchForward, searchBackward

        var prefix: String {
            switch self {
            case .command: ":"
            case .searchForward: "/"
            case .searchBackward: "?"
            }
        }

        var isSearch: Bool { self != .command }
    }

    weak var delegate: CommandBarDelegate?
    private(set) var kind = Kind.command
    /// Report edits as they happen (incremental search).
    private var incremental = false

    let field = NSTextField(string: "")
    private let prefixLabel = NSTextField(labelWithString: ":")
    private var theme: Theme = .fallbackDark
    private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// Shared by all windows, like vim.
    private static var commandHistory = CommandHistory()
    private static var searchHistory = CommandHistory()

    private(set) var completionList: CompletionList?
    private var completions: [String] = []
    private var completionIndex: Int?
    private var editReportScheduled = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for label in [prefixLabel, field] {
            label.isBordered = false
            label.isBezeled = false
            label.drawsBackground = false
            label.focusRingType = .none
            addSubview(label)
        }
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var text: String { field.stringValue }

    func apply(theme: Theme, font: NSFont) {
        self.theme = theme
        self.font = font
        layer?.backgroundColor = theme.inputbarBg.cgColor
        for label in [prefixLabel, field] {
            label.font = font
            label.textColor = theme.inputbarFg.nsColor
        }
        (field.currentEditor() as? NSTextView)?.insertionPointColor = theme.inputbarFg.nsColor
        needsLayout = true
    }

    /// Prepares the bar for a new input; the caller shows it and focuses `field`.
    func begin(_ kind: Kind, text: String, incremental: Bool) {
        self.kind = kind
        self.incremental = incremental
        prefixLabel.stringValue = kind.prefix
        field.stringValue = text
        history.resetBrowsing()
        endCompletion()
        needsLayout = true
    }

    /// Called by the owner once the field is first responder.
    func didFocus() {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        editor.insertionPointColor = theme.inputbarFg.nsColor
        editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
    }

    /// Records the submitted text in the history for this kind. Passwords
    /// typed for `export` (`pw=…`, `owner=…`) are kept out of the history.
    func remember(_ text: String) {
        if !kind.isSearch, Self.containsPassword(text) { return }
        history.add(text)
    }

    static func containsPassword(_ text: String) -> Bool {
        CommandParser.splitArguments(text).contains { word in
            let lower = word.lowercased()
            return lower.hasPrefix("pw=") || lower.hasPrefix("owner=")
        }
    }

    /// The last submitted search query, for an empty `/`.
    static var lastSearch: String? { searchHistory.last }

    private var history: CommandHistory {
        get { kind.isSearch ? Self.searchHistory : Self.commandHistory }
        set { if kind.isSearch { Self.searchHistory = newValue } else { Self.commandHistory = newValue } }
    }

    override func layout() {
        super.layout()
        let height = ceil(font.ascender - font.descender + font.leading) + 2
        let y = floor((bounds.height - height) / 2)
        // Both cells inset their text equally, so the field starts where the
        // prefix text ends.
        let prefixWidth = ceil(prefixLabel.attributedStringValue.size().width)
        prefixLabel.frame = NSRect(x: 6, y: y, width: prefixWidth + 6, height: height)
        field.frame = NSRect(x: 6 + prefixWidth, y: y, width: max(0, bounds.width - prefixWidth - 12), height: height)
    }

    // MARK: Keys

    /// Handles keys with a meaning beyond typing. Returns false to let the
    /// field editor process the key.
    func handle(_ stroke: KeyStroke) -> Bool {
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() == true { return false }
        let ctrl = stroke.modifiers == [.ctrl]
        switch (stroke.key, stroke.modifiers) {
        case ("Return", []):
            delegate?.commandBar(self, submit: text)
        case ("Esc", []), ("[", [.ctrl]), ("c", [.ctrl]):
            delegate?.commandBarCancel(self)
        case ("Backspace", []) where text.isEmpty:
            delegate?.commandBarCancel(self)
        case ("Tab", []), ("Tab", [.shift]):
            complete(backward: stroke.modifiers == [.shift])
        case ("Up", []):
            if let entry = history.older(than: text) { replaceText(entry) }
        case ("Down", []):
            if let entry = history.newer() { replaceText(entry) }
        case ("w", _) where ctrl:
            deleteBackward(toWordStart: true)
        case ("u", _) where ctrl:
            deleteBackward(toWordStart: false)
        default:
            return false
        }
        return true
    }

    /// Inserts `string` at the end, as if typed.
    func type(_ string: String) {
        field.stringValue += string
        didFocus()
        textDidChange()
    }

    // MARK: Editing

    private func replaceText(_ string: String) {
        field.stringValue = string
        didFocus()
        endCompletion()
        scheduleEditReport()
    }

    /// Ctrl-w (previous word) and Ctrl-u (start of line), from the cursor.
    private func deleteBackward(toWordStart: Bool) {
        let string = field.stringValue as NSString
        let editor = field.currentEditor()
        let cursor = editor?.selectedRange.location ?? string.length
        var start = 0
        if toWordStart {
            start = cursor
            let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "/"))
            func isSeparator(_ i: Int) -> Bool {
                UnicodeScalar(string.character(at: i)).map(separators.contains) ?? false
            }
            while start > 0, isSeparator(start - 1) { start -= 1 }
            while start > 0, !isSeparator(start - 1) { start -= 1 }
        }
        guard start < cursor else { return }
        field.stringValue = string.replacingCharacters(in: NSRange(location: start, length: cursor - start), with: "")
        editor?.selectedRange = NSRange(location: start, length: 0)
        textDidChange()
    }

    func controlTextDidChange(_ notification: Notification) { textDidChange() }

    /// Focus moved elsewhere (a click into the document): cancel, like vim.
    /// The delegate ignores this while it is closing the bar itself.
    func controlTextDidEndEditing(_ notification: Notification) { delegate?.commandBarCancel(self) }

    private func textDidChange() {
        history.resetBrowsing()
        endCompletion()
        scheduleEditReport()
    }

    /// At most one report per 30 ms, carrying the latest text.
    private func scheduleEditReport() {
        guard incremental, !editReportScheduled else { return }
        editReportScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self, editReportScheduled else { return }
            editReportScheduled = false
            delegate?.commandBar(self, didEdit: text)
        }
    }

    /// Drops an edit report that has not been delivered yet.
    func cancelPendingEdit() { editReportScheduled = false }

    // MARK: Completion

    private func complete(backward: Bool) {
        guard kind == .command else { return }
        if completionIndex == nil {
            completions = delegate?.commandBarCompletions(for: text) ?? []
            guard !completions.isEmpty else { return }
            completionIndex = backward ? completions.count - 1 : 0
        } else if let index = completionIndex {
            completionIndex = (index + (backward ? completions.count - 1 : 1)) % completions.count
        }
        guard let index = completionIndex else { return }
        field.stringValue = completions[index]
        didFocus()
        // A single candidate is final; the next Tab completes from it (e.g.
        // descends into the directory just completed).
        if completions.count == 1 { return endCompletion() }
        let list = completionList ?? makeCompletionList()
        list.show(completions, selected: index, theme: theme, font: font)
        list.isHidden = false
        superview?.needsLayout = true
    }

    private func makeCompletionList() -> CompletionList {
        let list = CompletionList()
        superview?.addSubview(list, positioned: .above, relativeTo: self)
        completionList = list
        return list
    }

    func endCompletion() {
        completions = []
        completionIndex = nil
        if let list = completionList, !list.isHidden {
            list.isHidden = true
            superview?.needsLayout = true
        }
    }
}
