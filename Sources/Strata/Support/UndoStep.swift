import Foundation

/// An Undo step `UndoManager.beginStep` opened, for `endStep`.
package struct UndoStepToken {
    fileprivate let opened: Bool
    fileprivate let groupedByEvent: Bool
}

package extension UndoManager {
    /// Opens a group for one Undo step when none is open; `endStep` closes it. Work that ends after its event (a trash,
    /// a copy, a git command finishing in the background) registers outside any group: grouping by event would open one
    /// that only the next event closes, and when that event is ⌘Z, Edit ▸ Undo is off as it's checked. Opening a group
    /// by hand then would open the event's group around it too, so grouping by event is off until the step is closed.
    /// Inside an open group (an event's, or an undo running) the step joins it.
    func beginStep() -> UndoStepToken {
        guard groupingLevel == 0 else { return UndoStepToken(opened: false, groupedByEvent: groupsByEvent) }
        let byEvent = groupsByEvent
        groupsByEvent = false
        beginUndoGrouping()
        return UndoStepToken(opened: true, groupedByEvent: byEvent)
    }

    func endStep(_ token: UndoStepToken) {
        guard token.opened else { return }
        endUndoGrouping()
        groupsByEvent = token.groupedByEvent
    }
}
