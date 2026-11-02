import AppKit
import Testing
@testable import Strata
@testable import StrataModel

@Suite struct WindowMinimumWidthTests {
    private static let columns: [NSUserInterfaceItemIdentifier: CGFloat] = [.name: 90, .modified: 110, .size: 60, .kind: 80]

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

    @Test func columnsLeaveLeastNeededFirstAndNameNeverLeaves() {
        func leftOut(at width: CGFloat) -> Set<NSUserInterfaceItemIdentifier> {
            BrowserViewController.columnsLeftOut(of: Self.columns, width: width, spacing: 3)
        }
        #expect(leftOut(at: 1000).isEmpty)
        #expect(leftOut(at: 400) == [.kind])
        #expect(leftOut(at: 300) == [.kind, .modified])
        #expect(leftOut(at: 100) == [.kind, .modified, .size])
    }

    @Test func aColumnThatLeftComesBackAndSavedChoicesStayAsTheyWere() async throws {
        let tree = try TestTree("folder/", "folder/a.txt")
        let environment = try IndependentEnvironment()
        environment.preferences.hiddenListColumns = ["created"]
        let owner = BrowserWindowController(location: tree.url("folder"), secondPane: nil, services: environment.services)
        owner.window?.setFrameAutosaveName("")
        owner.split.splitView.autosaveName = nil
        defer { owner.window?.contentViewController = nil; owner.panes.forEach { $0.stopBackgroundWork() } }
        let browser = owner.panes[0].browser
        await browser.directoryReads.task?.value
        browser.setMode(.list, remember: false)
        let window = try #require(owner.window)
        func shown(atWidth width: CGFloat) -> Set<String> {
            window.setFrame(NSRect(x: 0, y: 0, width: width, height: 600), display: false)
            window.layoutIfNeeded()
            return Set(browser.outlineView.tableColumns.filter { !$0.isHidden }.map(\.identifier.rawValue))
        }
        owner.split.splitViewItems[0].isCollapsed = true
        owner.split.inspectorItem.isCollapsed = true

        let wide = shown(atWidth: 1240)
        #expect(wide.contains("modified") && wide.contains("kind") && !wide.contains("created"))
        #expect(shown(atWidth: 320) == ["name", "size"])
        #expect(shown(atWidth: 1240) == wide)
        #expect(environment.preferences.hiddenListColumns == ["created"])
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["folder/", "folder/a.txt"])
    }
}
