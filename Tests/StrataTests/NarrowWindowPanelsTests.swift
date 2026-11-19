import AppKit
import Testing
@testable import Strata

@Suite struct NarrowWindowPanelsTests {
    @Test func aNarrowWindowHidesTheSidebarAndInspectorUntilOneIsShown() async throws {
        let tree = try TestTree("a")
        let environment = try IndependentEnvironment()
        let owner = BrowserWindowController(location: tree.root, services: environment.services)
        owner.window?.setFrameAutosaveName("")
        owner.split.splitView.autosaveName = nil
        defer {
            owner.window?.contentViewController = nil
            owner.panes.forEach { $0.stopBackgroundWork() }
        }
        let window = try #require(owner.window)
        let sidebar = owner.split.splitViewItems[0], inspector = owner.split.inspectorItem
        func resize(_ width: CGFloat) {
            window.setContentSize(NSSize(width: width, height: 700))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        sidebar.isCollapsed = false
        inspector.isCollapsed = false

        resize(800)
        #expect(!sidebar.isCollapsed && inspector.isCollapsed)
        resize(600)
        #expect(sidebar.isCollapsed && inspector.isCollapsed)
        resize(1240)
        #expect(!sidebar.isCollapsed && !inspector.isCollapsed)

        resize(600)
        inspector.isCollapsed = false
        resize(620)
        #expect(sidebar.isCollapsed && !inspector.isCollapsed)

        resize(1240)
        inspector.isCollapsed = true
        resize(600)
        resize(1240)
        // Hidden by hand, not for the width: it stays hidden.
        #expect(!sidebar.isCollapsed && inspector.isCollapsed)
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["a"])
    }

    @Test func bAndShiftBToggleTheSidebarAndInspectorAndIGetsInfo() {
        #expect(StrataCommand.toggleSidebar.key == "b" && StrataCommand.toggleSidebar.modifiers == .command)
        #expect(StrataCommand.toggleInspector.key == "b" && StrataCommand.toggleInspector.modifiers == [.command, .shift])
        #expect(StrataCommand.getInfo.key == "i" && StrataCommand.getInfo.modifiers == .command)
    }
}
