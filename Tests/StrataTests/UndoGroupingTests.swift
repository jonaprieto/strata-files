import Foundation
import Testing
@testable import Strata
@testable import StrataModel

/// Undo steps registered when asynchronous work ends, outside any event, are ready for ⌘Z at once. The app's undo
/// manager groups by event: a step registered outside one opened a group that only the next event closed, and that
/// event was the ⌘Z itself, so Edit ▸ Undo was off when it was checked.
@Suite struct UndoGroupingTests {
    @Test func moveToTrashCanBeUndoneAtOnceWithTheAppsUndoManager() async throws {
        let tree = try TestTree("a.txt", "ab.txt")
        defer { tree.removeFromTrash() }
        // As the app's: grouping by event, nothing opened by hand.
        let undo = UndoManager()
        #expect(undo.groupsByEvent)

        try await FileOps.trashInBackground([tree.url("a.txt")], undo: undo, copies: .live, history: .shared)
        #expect(undo.groupingLevel == 0)
        #expect(undo.canUndo)
        #expect(undo.undoActionName == OperationLog.displayName("Move to Trash"))
        #expect(undo.groupsByEvent)

        undo.undo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == ["a.txt", "ab.txt"])
    }

    @Test func aStepRegisteredInsideAnOpenGroupStaysInIt() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        var ran = 0
        for _ in 0..<2 {
            let step = undo.beginStep()
            undo.registerUndo(withTarget: undo) { _ in ran += 1 }
            undo.endStep(step)
        }
        undo.endUndoGrouping()
        // One step: both run with one Undo.
        undo.undo()
        #expect(ran == 2)
        #expect(!undo.canUndo)
    }
}
