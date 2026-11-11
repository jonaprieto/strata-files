import AppKit
import Testing
@testable import Strata
@testable import StrataDev

/// The Git History panel beside the files: it follows the active pane's repository, a commit shows that commit's files
/// read only in the pane, and Working Files brings the pane back.
@Suite struct GitHistoryPanelTests {
    /// Two commits; "sub/old" only in the first.
    private func history() async throws -> GitFixture {
        let repo = try await GitFixture(["a": "1\n", "sub/old": "o\n"])
        try repo.write("a", "2\n")
        try FileManager.default.removeItem(at: repo.url("sub/old"))
        try repo.write("sub/new", "n\n")
        try await repo.git("add", "-A")
        try await repo.git("commit", "-q", "-m", "second")
        return repo
    }

    private func window(at folder: URL, _ environment: IndependentEnvironment) async -> BrowserWindowController {
        let owner = BrowserWindowController(location: folder, services: environment.services)
        owner.window?.setFrameAutosaveName("")
        owner.split.splitView.autosaveName = nil
        for pane in owner.panes { await pane.browser.directoryReads.task?.value }
        return owner
    }

    private func close(_ owner: BrowserWindowController) {
        owner.window?.contentViewController = nil
        owner.panes.forEach { $0.stopBackgroundWork() }
    }

    /// Shows the panel and waits until it follows a repository and its log has loaded.
    private func showPanel(_ owner: BrowserWindowController) async throws -> GitHistoryPanelController {
        owner.toggleGitHistory(nil)
        let panel = owner.split.history
        for _ in 0..<500 where panel.repository == nil { try await Task.sleep(for: .milliseconds(10)) }
        await panel.log?.loadTask?.value
        return panel
    }

    @Test func thePanelFollowsThePanesRepository() async throws {
        let repo = try await history()
        let environment = try IndependentEnvironment()
        environment.services.git.isEnabled = true
        let owner = await window(at: repo.url("sub"), environment)
        defer { close(owner) }
        #expect(!owner.split.isHistoryShown)

        let panel = try await showPanel(owner)
        #expect(owner.split.isHistoryShown)
        #expect(panel.repository?.rootPath == repo.repository.rootPath)
        #expect(panel.log?.commits.map(\.subject) == ["second", "first"])
        #expect(panel.viewing == nil)
        let button = NSToolbarItem(itemIdentifier: BrowserToolbar.identifier(.toggleGitHistory))
        #expect(owner.validateToolbarItem(button))
        #expect(button.toolTip == String(localized: "Hide Git History"))
        let count = owner.split.splitViewItems.count
        owner.toggleGitHistory(nil)
        #expect(!owner.split.isHistoryShown && owner.split.splitViewItems.count == count - 1)
        #expect(owner.split.splitViewItems.last === owner.split.inspectorItem)
        withExtendedLifetime(environment) {}
    }

    @Test func aCommitShowsItsFilesReadOnlyAndWorkingFilesComesBack() async throws {
        let repo = try await history()
        let environment = try IndependentEnvironment()
        environment.services.git.isEnabled = true
        let owner = await window(at: repo.url("sub"), environment)
        defer { close(owner) }
        let panel = try await showPanel(owner)
        let first = try #require(panel.log?.commits.last)

        await panel.show(first).value
        await owner.browser.directoryReads.task?.value
        let shown = try #require(owner.browser.directory)
        #expect(GitSnapshotCache.commit(containing: shown)?.commit == first.id)
        #expect(shown.lastPathComponent == "sub")
        #expect(owner.browser.allRows.map(\.entry.name) == ["old"])
        #expect(panel.viewing == first.id)
        #expect(owner.browser.statusText.contains(first.shortID))
        // Nothing in a commit's files can be changed.
        owner.browser.select([shown.appending(path: "old")])
        #expect(!owner.browser.validateMenuItem(StrataCommand.moveToTrash.menuItem()))
        #expect(!owner.browser.validateMenuItem(StrataCommand.newFolder.menuItem()))

        await panel.showWorkingFiles().value
        await owner.browser.directoryReads.task?.value
        #expect(owner.browser.directory?.lexicallyStandardized.path == repo.url("sub").lexicallyStandardized.path)
        #expect(panel.viewing == nil)
        #expect(repo.text("a") == "2\n" && repo.text("sub/new") == "n\n")
        withExtendedLifetime(environment) {}
    }

    @Test func aFolderMissingFromTheCommitOpensItsNearestFolderThatWasThere() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        try repo.write("added/x", "x\n")
        try await repo.git("add", "-A")
        try await repo.git("commit", "-q", "-m", "second")
        let environment = try IndependentEnvironment()
        environment.services.git.isEnabled = true
        let owner = await window(at: repo.url("added"), environment)
        defer { close(owner) }
        let panel = try await showPanel(owner)
        let first = try #require(panel.log?.commits.last)

        await panel.show(first).value
        await owner.browser.directoryReads.task?.value
        let shown = try #require(owner.browser.directory)
        #expect(GitSnapshotCache.commit(containing: shown)?.top == shown)
        withExtendedLifetime(environment) {}
    }

    /// The log's keys and arrows move in the panel too, and the pane follows the commit chosen.
    @Test func movingInThePanelShowsThatCommitsFiles() async throws {
        let repo = try await history()
        let environment = try IndependentEnvironment()
        environment.services.git.isEnabled = true
        let owner = await window(at: repo.url("sub"), environment)
        defer { close(owner) }
        let panel = try await showPanel(owner)
        let log = try #require(panel.log)
        let (second, first) = (log.commits[0], log.commits[1])

        #expect(log.handleKey("n"))
        await panel.pendingMove?.value
        await owner.browser.directoryReads.task?.value
        #expect(panel.viewing == first.id)
        #expect(owner.browser.allRows.map(\.entry.name) == ["old"])

        let up = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                               characters: String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!),
                                               charactersIgnoringModifiers: String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!),
                                               isARepeat: false, keyCode: 126))
        log.table.keyDown(with: up)
        await panel.pendingMove?.value
        #expect(log.selectedCommits == [second])
        #expect(panel.viewing == second.id)
        withExtendedLifetime(environment) {}
    }

    /// Return shows the commit's changes in the pane, where they have room; `q` brings the files back.
    @Test func returnShowsTheCommitsDiffInThePane() async throws {
        let repo = try await history()
        let environment = try IndependentEnvironment()
        environment.services.git.isEnabled = true
        let owner = await window(at: repo.url("sub"), environment)
        defer { close(owner) }
        let panel = try await showPanel(owner)
        let log = try #require(panel.log)
        let newest = try #require(log.commits.first)

        #expect(log.handleKey("\r"))
        let diff = try #require(owner.browser.gitStatus?.diffView)
        #expect(diff.kind == .commit(newest.id))
        #expect(panel.viewing == nil)
        #expect(diff.handleKey("q"))
        #expect(owner.browser.gitStatus == nil)
        withExtendedLifetime(environment) {}
    }

    /// In the narrow panel a commit takes two lines, its subject alone on the first; the log in the status keeps one.
    @Test func thePanelsCommitsPutTheSubjectOnALineOfItsOwn() async throws {
        let repo = try await history()
        let environment = try IndependentEnvironment()
        environment.services.git.isEnabled = true
        let owner = await window(at: repo.url("sub"), environment)
        defer { close(owner) }
        let panel = try await showPanel(owner)
        let log = try #require(panel.log)
        let cell = try #require(log.tableView(log.table, viewFor: log.table.tableColumns.last, row: 0) as? NSTableCellView)
        let lines = cell.textField?.stringValue.components(separatedBy: "\n") ?? []
        #expect(lines.first == "second")
        #expect(lines.count == 2 && lines[1].contains(log.commits[0].shortID))
        #expect(cell.textField?.maximumNumberOfLines == 2)
        #expect(log.table.rowHeight >= 2 * 16)

        let status = GitLogViewController(all: false, workbench: GitWorkbench(repository: repo.repository, writer: environment.services.gitWriter))
        _ = status.view
        await status.loadTask?.value
        let single = try #require(status.tableView(status.table, viewFor: status.table.tableColumns.last, row: 0) as? NSTableCellView)
        #expect(single.textField?.maximumNumberOfLines == 1)
        #expect(!(single.textField?.stringValue.contains("\n") ?? true))
        withExtendedLifetime(environment) {}
    }

    /// With two panes the panel takes the other pane's place, as wide as it was; hiding the panel brings that pane back
    /// at its folder. Nothing can be sent to a pane that isn't shown.
    @Test func inTwoPanesThePanelTakesTheOtherPanesPlace() async throws {
        let repo = try await history()
        let environment = try IndependentEnvironment()
        environment.services.git.isEnabled = true
        let owner = BrowserWindowController(location: repo.url("sub"), secondPane: repo.root, services: environment.services)
        owner.window?.setFrameAutosaveName("")
        owner.split.splitView.autosaveName = nil
        defer { close(owner) }
        owner.window?.setContentSize(NSSize(width: 1200, height: 600))
        owner.split.splitView.layoutSubtreeIfNeeded()
        owner.split.panes.splitView.setPosition(owner.split.panes.splitView.bounds.width / 2, ofDividerAt: 0)
        owner.split.panes.splitView.layoutSubtreeIfNeeded()
        for pane in owner.panes { await pane.browser.directoryReads.task?.value }
        let active = owner.pane
        let other = try #require(owner.panes.first { $0 !== active })
        let width = other.host.view.frame.width

        _ = try await showPanel(owner)
        owner.split.splitView.layoutSubtreeIfNeeded()
        #expect(!owner.isDualPane && owner.pane === active)
        #expect(owner.otherBrowser == nil)
        #expect(abs(owner.split.history.view.frame.width - width) <= 2)

        owner.toggleGitHistory(nil)
        #expect(!owner.split.isHistoryShown && owner.isDualPane && owner.pane === active)
        let back = try #require(owner.panes.first { $0 !== active })
        #expect(back.location.lexicallyStandardized == other.location.lexicallyStandardized)
        withExtendedLifetime(environment) {}
    }

    @Test func outsideARepositoryThePanelSaysSo() async throws {
        let plain = try TestTree("x")
        let environment = try IndependentEnvironment()
        let owner = await window(at: plain.root, environment)
        defer { close(owner) }
        owner.toggleGitHistory(nil)
        let panel = owner.split.history
        _ = panel.view
        #expect(owner.split.isHistoryShown)
        // The repository is looked for away from the main thread; none is found.
        for _ in 0..<500 where panel.emptyMessage.isHidden { try await Task.sleep(for: .milliseconds(10)) }
        #expect(panel.repository == nil)
        #expect(panel.emptyMessage.isHidden == false)
        withExtendedLifetime((environment, plain)) {}
    }
}
