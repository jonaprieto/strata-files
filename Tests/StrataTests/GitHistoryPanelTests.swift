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
