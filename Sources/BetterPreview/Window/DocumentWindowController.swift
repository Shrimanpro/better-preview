import AppKit
import BPCore

/// Window-level behaviour that later milestones (sidebar, toolbar, inspector,
/// presentation) plug in from their own files: `dispatch` offers every
/// invocation to `features` first.
@MainActor
protocol WindowFeature: AnyObject {
    /// Returns true when the feature handled the invocation.
    func handle(_ invocation: ActionInvocation, in window: DocumentWindowController) -> Bool
    /// Options or theme changed (also called once right after creation).
    func environmentDidChange(options: Options, theme: Theme)
    /// The document's status (page, zoom, dirty, ...) changed.
    func documentStatusDidChange()
    /// The window is closing: remove monitors, observers and timers.
    func windowWillClose()
}

extension WindowFeature {
    func environmentDidChange(options: Options, theme: Theme) {}
    func documentStatusDidChange() {}
    func windowWillClose() {}
}

/// One window showing one document: the document view, the status bar, the
/// input bar, key routing, marks and the jump list. Actions are dispatched in
/// `ActionDispatch.swift`, keys are handled in `+Keys`, the input bar in
/// `+CommandBar`.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate, DocumentHost {
    let content: DocumentController
    var onClose: (() -> Void)?
    var features: [WindowFeature] = []

    private(set) var mode: Mode = .normal
    /// The mode the window returns to from command and insert mode:
    /// `.normal`, or `.presentation` while presenting (set by
    /// PresentationFeature). `setMode(.normal)` means "back to base".
    var baseMode: Mode = .normal
    /// The file changed on disk while the document had unsaved changes, so
    /// it was not reloaded; an in-place save asks first (see +Saving).
    var fileChangedOnDisk = false
    /// Undo for text views (the input bar, form fields, text boxes), kept
    /// apart from the document's undo stack.
    let textUndoManager = UndoManager()
    var options: Options { AppEnvironment.shared.options }
    var theme: Theme { AppEnvironment.shared.theme }

    let contentView: DocumentContentView
    var marks = Marks()
    var jumpList = JumpList()
    /// Where the last jump started, for `''`.
    var lastJumpOrigin: DocumentPosition?

    // Keys (see +Keys).
    var engineStorage: KeymapEngine?
    var engineBindings: [KeyBinding] = []
    var keyTimer: Timer?

    // Input bar (see +CommandBar).
    var commandBarStorage: CommandBar?
    var searchSession: SearchSession?

    private var messageTimer: Timer?
    private var fileWatcher: FileWatcher?
    private var appliedStatusbarOption: Bool?
    private var appliedFont: NSFont?

    /// The document window the user is looking at, if any.
    static var frontmost: DocumentWindowController? {
        if let controller = (NSApp.mainWindow ?? NSApp.keyWindow)?.windowController as? DocumentWindowController {
            return controller
        }
        return NSApp.orderedWindows.lazy.compactMap { $0.windowController as? DocumentWindowController }.first
    }

    init(document: DocumentController) {
        content = document
        contentView = DocumentContentView(documentView: document.view)
        let window = DocumentWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 1100),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        window.setFrameAutosaveName("BPDocumentWindow")
        if !window.setFrameUsingName("BPDocumentWindow") { window.center() }
        super.init(window: window)
        window.delegate = self
        window.title = document.fileURL.lastPathComponent
        window.representedURL = document.fileURL
        window.contentView = contentView
        window.keyRouter = { [unowned self] event in handleKeyEvent(event) }

        document.host = self
        features = []
        applyEnvironment()
        refreshStatus()
        window.makeFirstResponder(document.preferredFirstResponder)
        if let message = ConfigController.shared.takeUndeliveredMessage() { showMessage(message, isError: true) }

        NotificationCenter.default.addObserver(
            self, selector: #selector(environmentDidChange), name: AppEnvironment.didChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func environmentDidChange() { applyEnvironment() }

    private func applyEnvironment() {
        let options = options, theme = theme
        window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window?.backgroundColor = theme.defaultBg.nsColor
        content.apply(options: options, theme: theme)
        for feature in features { feature.environmentDidChange(options: options, theme: theme) }

        let font = NSFont.bpUIFont(options)
        if font != appliedFont {
            appliedFont = font
            contentView.barHeight = StatusBar.height(for: font)
        }
        contentView.statusBar.apply(theme: theme, font: font)
        commandBarStorage?.apply(theme: theme, font: font)
        if appliedStatusbarOption != options.statusbar {
            appliedStatusbarOption = options.statusbar
            contentView.statusBarVisible = options.statusbar
        }
        if AppEnvironment.shared.config.bindings != engineBindings { discardKeyEngine() }
        updateFileWatcher()
    }

    func focusDocument() {
        window?.makeFirstResponder(content.preferredFirstResponder)
    }

    // MARK: DocumentHost

    func setMode(_ requested: Mode) {
        // Leaving command or insert mode returns to the base mode, so a
        // presentation keeps its key map after the input bar or a text edit.
        let mode = requested == .normal ? baseMode : requested
        guard mode != self.mode else { return }
        self.mode = mode
        if mode == baseMode, window?.firstResponder is NSText { focusDocument() }
        refreshStatus()
    }

    func documentStatusDidChange() {
        window?.isDocumentEdited = content.isDirty
        refreshStatus()
        for feature in features { feature.documentStatusDidChange() }
    }

    func showMessage(_ text: String, isError: Bool) {
        contentView.statusBar.message = StatusBar.Message(text: text, isError: isError)
        contentView.showsTransientStatus = true
        messageTimer?.invalidate()
        messageTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearMessage() }
        }
    }

    func clearMessage() {
        messageTimer?.invalidate()
        messageTimer = nil
        guard contentView.statusBar.message != nil else { return }
        contentView.statusBar.message = nil
        contentView.showsTransientStatus = false
    }

    /// The status bar's current message, if any.
    var message: String? { contentView.statusBar.message?.text }

    func recordJump(from position: DocumentPosition) {
        // Incremental search moves around while typing; the input bar records
        // the starting point once when the search is confirmed.
        guard searchSession == nil else { return }
        jumpList.record(position)
        lastJumpOrigin = position
    }

    // MARK: Status bar

    func refreshStatus() {
        let status = content.status
        let bar = contentView.statusBar
        bar.fileName = content.fileURL.lastPathComponent + (content.isDirty ? " [+]" : "")
        var flags = status.flags
        if mode == .insert { flags.insert("insert", at: 0) }
        bar.info = [
            engineStorage?.pendingDisplay ?? "",
            flags.joined(separator: " "),
            status.detail,
            "\(Int((status.zoom * 100).rounded()))%",
            status.pageCount > 0
                ? "\(status.page)/\(status.pageCount)" + (status.position.map { " (\($0)%)" } ?? "")
                : "",
        ]
    }

    // MARK: Auto-reload

    private func updateFileWatcher() {
        guard options.autoReload else {
            fileWatcher = nil
            return
        }
        guard fileWatcher == nil else { return }
        fileWatcher = FileWatcher(url: content.fileURL) { [weak self] in self?.fileDidChangeOnDisk() }
    }

    /// Our own save changes the file too: start watching from the new state.
    func restartFileWatcher() {
        fileWatcher = nil
        updateFileWatcher()
    }

    private func fileDidChangeOnDisk() {
        if content.isDirty {
            fileChangedOnDisk = true
            showMessage("\(content.fileURL.lastPathComponent) changed on disk; not reloaded (unsaved changes)",
                        isError: true)
        } else {
            fileChangedOnDisk = false
            content.reloadFromDisk()
        }
    }

    // MARK: Menu

    @objc func performMenuAction(_ sender: ActionMenuItem) {
        guard let invocation = sender.invocation else { return }
        // Text editing commands belong to a focused text view (input bar,
        // form field, text box, palette, password field), not the document.
        if let selector = Self.textSelectors[invocation.action.name], let text = focusedText {
            // Up the text view's responder chain: undo:/redo: reach its
            // window, whose undo manager is then `textUndoManager`.
            _ = text.tryToPerform(selector, with: sender)
            return
        }
        dispatch(invocation)
    }

    private static let textSelectors: [ActionName: Selector] = [
        .copy: #selector(NSText.copy(_:)), .selectAll: #selector(NSText.selectAll(_:)),
        .undo: Selector(("undo:")), .redo: Selector(("redo:")),
    ]

    /// The text view being edited in the key window (a sheet or the
    /// palette), else in this window, if any.
    var focusedText: NSText? {
        NSApp.keyWindow?.firstResponder as? NSText ?? window?.firstResponder as? NSText
    }

    /// Edit > Delete (nil-targeted `delete:`): a focused text view handles it
    /// itself; otherwise it deletes the selected annotation or signature.
    @objc func delete(_ sender: Any?) {
        dispatch(ActionInvocation(.annotationDelete))
    }

    // MARK: NSWindowDelegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        window.firstResponder is NSText ? textUndoManager : content.undoManager
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        commitPendingEdits()
        guard content.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(content.fileURL.lastPathComponent)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save").hasDestructiveAction = true
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                if saveInPlace() { sender.close() }
            case .alertThirdButtonReturn:
                sender.close()
            default:
                break
            }
        }
        return false
    }

    /// The title bar's safe-area inset changes with full screen.
    func windowDidEnterFullScreen(_ notification: Notification) { contentView.needsLayout = true }
    func windowDidExitFullScreen(_ notification: Notification) { contentView.needsLayout = true }

    func windowDidEndSheet(_ notification: Notification) {
        if mode == baseMode { focusDocument() }
    }

    func windowWillClose(_ notification: Notification) {
        for feature in features { feature.windowWillClose() }
        (content as? PDFDocumentController)?.tearDownFeatures()
        NotificationCenter.default.removeObserver(self)
        keyTimer?.invalidate()
        messageTimer?.invalidate()
        fileWatcher = nil
        onClose?()
    }
}
