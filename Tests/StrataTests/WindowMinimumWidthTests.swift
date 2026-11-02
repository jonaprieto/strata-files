import AppKit
import Testing
@testable import Strata
@testable import StrataModel

@Suite struct WindowMinimumWidthTests {
    @Test func theSmallestWindowFitsEveryViewWithBothPanelsOpenWhateverTheStatusBarSays() async throws {
        let tree = try TestTree("folder/", "folder/a name far too long to fit in the smallest window at all.txt")
        let environment = try IndependentEnvironment()
        let owner = BrowserWindowController(location: tree.url("folder"), secondPane: nil, services: environment.services)
        owner.window?.setFrameAutosaveName("")
        owner.split.splitView.autosaveName = nil
        defer { owner.window?.contentViewController = nil; owner.panes.forEach { $0.stopBackgroundWork() } }
        for pane in owner.panes { await pane.browser.directoryReads.task?.value }
        let window = try #require(owner.window)
        owner.panes[0].browser.select([tree.url("folder/a name far too long to fit in the smallest window at all.txt")])

        owner.split.status.text = String(repeating: "selected items ", count: 20)
        owner.split.inspectorItem.isCollapsed = false
        for mode in BrowserViewMode.ordered {
            owner.panes[0].browser.setMode(mode, remember: false)
            window.setFrame(NSRect(origin: .zero, size: window.minSize), display: false)
            window.layoutIfNeeded()
            #expect(window.frame.size == window.minSize)
        }
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot().count == 2)
    }
}
