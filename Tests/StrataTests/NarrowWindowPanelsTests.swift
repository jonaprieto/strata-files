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

    @Test func aNarrowWindowKeepsTheLocationAndBothPanelButtons() async throws {
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
        let toolbar = try #require(window.toolbar)
        toolbar.itemIdentifiers = BrowserToolbar.defaults
        for id in [NSToolbarItem.Identifier.toggleSidebar, .toggleInspector] {
            #expect(toolbar.items.first { $0.itemIdentifier == id }?.visibilityPriority == .high)
        }
        window.setContentSize(NSSize(width: 450, height: 700))
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        #expect(owner.pathBar.window === window)
        #expect(toolbar.visibleItems?.contains { $0.itemIdentifier == .pathBar } == true)
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["a"])
    }

    @Test func bAndShiftBToggleTheSidebarAndInspectorAndIGetsInfo() {
        #expect(StrataCommand.toggleSidebar.key == "b" && StrataCommand.toggleSidebar.modifiers == .command)
        #expect(StrataCommand.toggleInspector.key == "b" && StrataCommand.toggleInspector.modifiers == [.command, .shift])
        #expect(StrataCommand.getInfo.key == "i" && StrataCommand.getInfo.modifiers == .command)
    }
}

@Suite struct NarrowWindowChromeTests {
    private func window(_ tree: TestTree, _ environment: IndependentEnvironment) throws -> BrowserWindowController {
        let owner = BrowserWindowController(location: tree.root, services: environment.services)
        owner.window?.setFrameAutosaveName("")
        owner.split.splitView.autosaveName = nil
        try #require(owner.window).toolbar?.itemIdentifiers = BrowserToolbar.defaults
        return owner
    }

    private func close(_ owner: BrowserWindowController) {
        owner.window?.contentViewController = nil
        owner.panes.forEach { $0.stopBackgroundWork() }
    }

    private func resize(_ owner: BrowserWindowController, _ width: CGFloat) {
        owner.window?.setContentSize(NSSize(width: width, height: 700))
        owner.window?.contentView?.superview?.layoutSubtreeIfNeeded()
    }

    @Test func aWindowTooNarrowForTheToolbarsPathShowsItAboveThePane() async throws {
        let tree = try TestTree("a")
        let environment = try IndependentEnvironment()
        let owner = try window(tree, environment)
        defer { close(owner) }
        let toolbar = try #require(owner.window?.toolbar)
        let paneBar = owner.pane.host.pathBar

        resize(owner, 360)
        #expect(owner.toolbarItems.pathBar?.isHidden == true)
        #expect(!paneBar.isHiddenOrHasHiddenAncestor)
        let shown = Set((toolbar.visibleItems ?? []).map(\.itemIdentifier))
        #expect(shown.isSuperset(of: [.back, .forward, .search]))

        resize(owner, 1240)
        #expect(owner.toolbarItems.pathBar?.isHidden == false)
        #expect(paneBar.isHiddenOrHasHiddenAncestor)
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["a"])
    }

    @Test func aNarrowFooterWrapsBetweenItsDetails() async throws {
        let tree = try TestTree("a")
        let environment = try IndependentEnvironment()
        let owner = try window(tree, environment)
        defer { close(owner) }
        let footer = owner.split.status
        // Narrowing hides the Inspector, which refreshes the footer, so the text goes in after.
        resize(owner, 320)
        footer.text = "5 items · 2 selected, 4,2 MB · jonaprieto/audit-workspace · 3 untracked · 195,99 GB free"
        owner.window?.contentView?.superview?.layoutSubtreeIfNeeded()
        let label = try #require(Self.labels(in: footer.view).first)
        let line = try #require(label.font).boundingRectForFont.height

        #expect(label.frame.height > line * 1.5)
        #expect(!label.stringValue.contains("…"))
        #expect(label.stringValue.components(separatedBy: " · ").allSatisfy { !$0.contains(" ") })
        #expect(footer.text.hasPrefix("5 items · 2 selected"))
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["a"])
    }

    private static func labels(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { [$0 as? NSTextField].compactMap { $0 } + labels(in: $0) }
    }
}
