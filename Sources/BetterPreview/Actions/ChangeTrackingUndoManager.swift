import Foundation

/// An undo manager that knows whether the document differs from its last
/// save, the way NSDocument's change count does: every closed top-level undo
/// group that registered actions is +1, every undo -1, every redo +1, and
/// the document is clean when the count equals the count at the last save.
/// Making a new change while undone past the save makes the save unreachable.
///
/// Changes that register no undo are reported with `noteChange()` and keep
/// the document dirty until the next save. A change reported in the same
/// event (undo group) as a registered action counts as that undoable change;
/// one reported in an earlier event stays unsaved even after later undoable
/// edits are undone.
final class ChangeTrackingUndoManager: UndoManager {
    private var changeCount = 0
    /// nil: the saved state can no longer be reached by undo/redo.
    private var savedCount: Int? = 0
    private var groupHasActions = false
    /// A change without undo, from an earlier event: only a save clears it.
    private var untrackedChange = false
    /// `noteChange()` in the current event: absorbed if an undoable group
    /// closes in this event, else it becomes `untrackedChange`.
    private var pendingChange = false
    private var pendingCheckScheduled = false
    private var undoableGroupClosedThisEvent = false
    /// Called after the dirty state may have changed (on the main thread).
    var onChange: (() -> Void)?

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(willCloseGroup(_:)),
                           name: .NSUndoManagerWillCloseUndoGroup, object: self)
        center.addObserver(self, selector: #selector(didUndo), name: .NSUndoManagerDidUndoChange, object: self)
        center.addObserver(self, selector: #selector(didRedo), name: .NSUndoManagerDidRedoChange, object: self)
    }

    /// Includes changes in an undo group that is still open.
    var hasUnsavedChanges: Bool {
        untrackedChange || pendingChange || groupHasActions || savedCount != changeCount
    }

    /// A change was made (it may or may not have registered undo). Changes
    /// made by undo or redo themselves are counted by those.
    func noteChange() {
        // Reported right after its undoable group closed (same event): that
        // group is this change.
        if !isUndoing && !isRedoing && !undoableGroupClosedThisEvent {
            pendingChange = true
            schedulePendingCheck()
        }
        onChange?()
    }

    /// After the current event: a pending change that no undoable group
    /// took becomes permanent (until saved). While a group is still open
    /// its close decides instead.
    private func schedulePendingCheck() {
        guard !pendingCheckScheduled else { return }
        pendingCheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            pendingCheckScheduled = false
            undoableGroupClosedThisEvent = false
            guard pendingChange, groupingLevel == 0 else { return }
            pendingChange = false
            untrackedChange = true
        }
    }

    func markSaved() {
        // A still-open group with actions counts once it closes.
        savedCount = changeCount + (groupHasActions ? 1 : 0)
        untrackedChange = false
        pendingChange = false
        onChange?()
    }

    /// The document was replaced by the file's contents.
    func resetChanges() {
        removeAllActions()
        changeCount = 0
        savedCount = 0
        groupHasActions = false
        untrackedChange = false
        pendingChange = false
        onChange?()
    }

    // MARK: Registration

    private func noteRegistration() {
        if !isUndoing && !isRedoing { groupHasActions = true }
    }

    override func registerUndo(withTarget target: Any, selector: Selector, object anObject: Any?) {
        noteRegistration()
        super.registerUndo(withTarget: target, selector: selector, object: anObject)
    }

    override func prepare(withInvocationTarget target: Any) -> Any {
        noteRegistration()
        return super.prepare(withInvocationTarget: target)
    }

    /// The block form (`registerUndo(withTarget:handler:)` in Swift).
    override func __registerUndoWithTarget(_ target: Any, handler: @escaping @MainActor @Sendable (Any) -> Void) {
        noteRegistration()
        super.__registerUndoWithTarget(target, handler: handler)
    }

    // MARK: Counting

    @objc private func willCloseGroup(_ note: Notification) {
        guard groupingLevel == 1, !isUndoing, !isRedoing else { return }
        defer { groupHasActions = false }
        guard groupHasActions,
              (note.userInfo?[NSUndoManagerGroupIsDiscardableKey] as? Bool) != true else {
            // Nothing undoable in this event: a change noted in it stays.
            if pendingChange {
                pendingChange = false
                untrackedChange = true
            }
            return
        }
        if let saved = savedCount, changeCount < saved { savedCount = nil }
        changeCount += 1
        // A change noted in this event is this undoable one; earlier
        // untracked changes stay (undo cannot bring those back).
        pendingChange = false
        undoableGroupClosedThisEvent = true
        schedulePendingCheck()
        onChange?()
    }

    @objc private func didUndo() {
        changeCount -= 1
        onChange?()
    }

    @objc private func didRedo() {
        changeCount += 1
        onChange?()
    }
}
