import AppKit
import BPCore

/// State of a `/` or `?` input while it is open.
struct SearchSession {
    /// Where the view was when the bar opened; restored on cancel.
    var start: DocumentPosition
    var directionBefore: Bool
    /// The last query sent by incremental search, if any.
    var lastSent: String?
    /// The search that was active before this one (restored on cancel).
    var previous: PDFDocumentController.SearchMemento?
}

/// The input bar: opening, submitting, cancelling, incremental search and
/// completion sources.
extension DocumentWindowController: CommandBarDelegate {
    /// The input bar, created on first use.
    var commandBar: CommandBar {
        if let bar = commandBarStorage { return bar }
        let bar = CommandBar()
        bar.delegate = self
        bar.apply(theme: theme, font: NSFont.bpUIFont(options))
        commandBarStorage = bar
        contentView.commandBar = bar
        return bar
    }

    func openCommandBar(_ kind: CommandBar.Kind, text: String = "") {
        if mode == .command { closeCommandBar() }
        engineStorage?.reset()
        clearMessage()
        let bar = commandBar
        if kind.isSearch {
            searchSession = SearchSession(start: content.currentPosition,
                                          directionBefore: content.searchDirectionBackward,
                                          previous: (content as? PDFDocumentController)?.searchMemento())
            content.searchDirectionBackward = kind == .searchBackward
        }
        bar.begin(kind, text: text, incremental: kind.isSearch && options.incrementalSearch)
        setMode(.command)
        contentView.isCommandBarShown = true
        contentView.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(bar.field)
        bar.didFocus()
        refreshStatus()
    }

    /// Hides the bar and returns focus to the document.
    func closeCommandBar() {
        guard mode == .command else { return }
        commandBarStorage?.cancelPendingEdit()
        commandBarStorage?.endCompletion()
        searchSession = nil
        setMode(baseMode)
        contentView.isCommandBarShown = false
        focusDocument()
    }

    /// Runs one `:` command line; errors become an error message.
    func runCommandLine(_ line: String) {
        do {
            dispatch(try CommandParser.parse(line))
        } catch {
            showMessage(error.localizedDescription, isError: true)
        }
    }

    // MARK: CommandBarDelegate

    func commandBar(_ bar: CommandBar, submit text: String) {
        bar.remember(text)
        let kind = bar.kind
        guard kind.isSearch else {
            closeCommandBar()
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { runCommandLine(text) }
            return
        }
        let session = searchSession
        let query = text.isEmpty ? (CommandBar.lastSearch ?? "") : text
        closeCommandBar()
        if let start = session?.start { recordJump(from: start) }
        content.searchDirectionBackward = kind == .searchBackward
        // Incremental search already ran this exact query.
        if query != session?.lastSent, !query.isEmpty {
            dispatch(ActionInvocation(.searchRun, query))
        }
    }

    func commandBarCancel(_ bar: CommandBar) {
        guard mode == .command else { return }
        let session = searchSession
        closeCommandBar()
        guard let session else { return }
        content.searchDirectionBackward = session.directionBefore
        if session.lastSent != nil {
            clearMessage()
            if let previous = session.previous, let pdf = content as? PDFDocumentController {
                pdf.restoreSearch(previous)
            } else {
                dispatch(ActionInvocation(.searchClear))
            }
            content.go(to: session.start, animated: false)
        }
    }

    func commandBar(_ bar: CommandBar, didEdit text: String) {
        guard mode == .command, searchSession != nil else { return }
        searchSession?.lastSent = text
        dispatch(ActionInvocation(.searchRun, text))
    }

    func commandBarCompletions(for text: String) -> [String] {
        let config = AppEnvironment.shared.config
        let context = CompletionContext(optionNames: Options.rcKeys + Theme.colorKeys.keys.sorted(),
                                        themeNames: ThemeRegistry.names(in: config) + ["auto"])
        let base = content.fileURL.deletingLastPathComponent()
        return CommandCompleter.complete(text, context: context) { directory in
            Self.listDirectory(directory.hasPrefix("/") ? URL(fileURLWithPath: directory)
                                                        : base.appendingPathComponent(directory))
        }
    }

    /// Entry names with a trailing "/" for directories.
    private static func listDirectory(_ url: URL) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries.map { entry in
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return entry.lastPathComponent + (isDirectory == true ? "/" : "")
        }
    }
}
