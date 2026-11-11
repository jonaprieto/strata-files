import AppKit
import Testing
@testable import Strata
@testable import StrataDev
@testable import StrataModel

/// The status view in a real pane: what it shows, the keys that change the index, and that nothing else can act on
/// the files beneath it.
@Suite struct GitStatusViewTests {
    private func window(_ repo: GitFixture, other: URL, _ environment: IndependentEnvironment) async -> BrowserWindowController {
        let owner = BrowserWindowController(location: repo.root, secondPane: other, services: environment.services)
        owner.window?.setFrameAutosaveName("")
        owner.split.splitView.autosaveName = nil
        for pane in owner.panes { await pane.browser.directoryReads.task?.value }
        return owner
    }

    private func close(_ owner: BrowserWindowController) {
        owner.window?.contentViewController = nil
        owner.panes.forEach { $0.stopBackgroundWork() }
    }

    @discardableResult
    private func open(_ browser: BrowserViewController) async throws -> GitStatusViewController {
        browser.toggleGitStatus(nil)
        await browser.gitStatusLookup?.value
        let status = try #require(browser.gitStatus)
        _ = status.view
        await settle(status)
        return status
    }

    /// Until no command runs and the latest load has landed: a status change can start a newer load meanwhile.
    private func settle(_ status: GitStatusViewController) async {
        for _ in 0..<50 {
            await status.commandTask?.value
            let load = status.loadTask
            await load?.value
            if status.commandTask == nil, status.loadTask == load { return }
        }
        Issue.record("the status view kept reloading")
    }

    private func select(_ status: GitStatusViewController, _ match: (GitStatusRow) -> Bool) {
        status.table.selectRowIndexes(IndexSet(status.rows.indices.filter { match(status.rows[$0]) }), byExtendingSelection: false)
    }

    @Test func sKeyStagesTheSelectedFileAndOnlyThatPaneChanges() async throws {
        let repo = try await GitFixture(["a": "1\n", "b": "1\n"])
        try repo.write("a", "2\n")
        try repo.write("b", "2\n")
        let elsewhere = try TestTree("x")
        let environment = try IndependentEnvironment()
        await environment.services.gitWriter.trust.trust(repo.repository)
        let owner = await window(repo, other: elsewhere.root, environment)
        defer { close(owner) }
        let browser = owner.panes[0].browser
        browser.select([repo.url("a")])

        let status = try await open(browser)
        #expect(browser.selectedURLs.isEmpty)
        #expect(owner.panes[1].browser.gitStatus == nil)
        #expect(status.rows.contains(.file(.unstaged, path: "a", diff: status.status?.unstaged.first { $0.path == "a" })))

        select(status) { $0.path == "a" && $0.section == .unstaged }
        #expect(status.handleKey("s"))
        await settle(status)
        #expect(try await repo.git("diff", "--cached", "--name-only") == "a\n")
        #expect(status.status?.staged.map(\.path) == ["a"])
        #expect(status.message?.isError == false)
        #expect(repo.text("a") == "2\n" && repo.text("b") == "2\n")
        withExtendedLifetime((environment, elsewhere)) {}
    }

    @Test func anUntrustedRepositoryAsksAndADeclineChangesNothing() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        try repo.write("a", "2\n")
        let elsewhere = try TestTree("x")
        let environment = try IndependentEnvironment()
        let owner = await window(repo, other: elsewhere.root, environment)
        defer { close(owner) }
        let status = try await open(owner.panes[0].browser)
        #expect(!status.isTrusted)
        var asked = 0
        status.askToTrust = { _, _ in asked += 1; return false }

        select(status) { $0.path == "a" }
        status.run(.stage)
        await settle(status)
        #expect(asked == 1)
        #expect(try await repo.git("diff", "--cached", "--name-only") == "")
        #expect(status.message?.isError == true)

        status.askToTrust = { _, _ in asked += 1; return true }
        select(status) { $0.path == "a" }
        status.run(.stage)
        await settle(status)
        #expect(asked == 2)
        #expect(try await repo.git("diff", "--cached", "--name-only") == "a\n")
        #expect(status.isTrusted)
        withExtendedLifetime((environment, elsewhere)) {}
    }

    @Test func fileCommandsAreOffWhileTheStatusShows() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        let elsewhere = try TestTree("x")
        let environment = try IndependentEnvironment()
        let owner = await window(repo, other: elsewhere.root, environment)
        defer { close(owner) }
        let browser = owner.panes[0].browser
        try await open(browser)

        for command in [StrataCommand.moveToTrash, .renameSelection, .duplicate, .newFolder, .paste, .compress, .openSelection] {
            #expect(!browser.validateMenuItem(command.menuItem()), "\(command.title) stays on")
        }
        let toggle = StrataCommand.toggleGitStatus.menuItem()
        #expect(browser.validateMenuItem(toggle))
        #expect(toggle.title == String(localized: "Hide Git Status"))
        // Pressing Move to Trash anyway trashes nothing: nothing is selected underneath.
        browser.moveToTrash(nil)
        await browser.commandWork?.value
        #expect(repo.text("a") == "1\n")
        withExtendedLifetime((environment, elsewhere)) {}
    }

    @Test func leavingTheRepositoryClosesItAndMovingWithinKeepsIt() async throws {
        let repo = try await GitFixture(["a": "1\n", "sub/b": "1\n"])
        let elsewhere = try TestTree("x")
        let environment = try IndependentEnvironment()
        let owner = await window(repo, other: elsewhere.root, environment)
        defer { close(owner) }
        let browser = owner.panes[0].browser
        try await open(browser)

        browser.load(repo.url("sub"))
        await browser.directoryReads.task?.value
        #expect(browser.gitStatus != nil)
        browser.load(elsewhere.root)
        await browser.directoryReads.task?.value
        #expect(browser.gitStatus == nil)
        withExtendedLifetime((environment, elsewhere)) {}
    }

    @Test func outsideARepositoryThereIsNoStatus() async throws {
        let plain = try TestTree("a")
        let elsewhere = try TestTree("x")
        let environment = try IndependentEnvironment()
        let owner = BrowserWindowController(location: plain.root, secondPane: elsewhere.root, services: environment.services)
        owner.window?.setFrameAutosaveName("")
        owner.split.splitView.autosaveName = nil
        defer { close(owner) }
        let browser = owner.panes[0].browser
        await browser.directoryReads.task?.value
        browser.toggleGitStatus(nil)
        await browser.gitStatusLookup?.value
        #expect(browser.gitStatus == nil)
        withExtendedLifetime((environment, plain, elsewhere)) {}
    }

    @Test func tabShowsAFilesChangesWithSpokenLabels() async throws {
        let repo = try await GitFixture(["a": "one\n"])
        try repo.write("a", "two\n")
        let elsewhere = try TestTree("x")
        let environment = try IndependentEnvironment()
        let owner = await window(repo, other: elsewhere.root, environment)
        defer { close(owner) }
        let status = try await open(owner.panes[0].browser)

        select(status) { $0.path == "a" }
        #expect(status.handleKey("\t"))
        let lines = status.rows.indices.filter { if case .line = status.rows[$0] { true } else { false } }
        #expect(lines.count == 2)
        let labels = lines.compactMap { (status.tableView(status.table, viewFor: nil, row: $0) as? GitStatusCell)?.accessibilityLabel() }
        #expect(labels == ["Removed: one", "Added: two"])
        // Tab on the section header opens and closes every file in it.
        select(status) { if case .section(.unstaged, _) = $0 { true } else { false } }
        #expect(status.handleKey("\t"))
        #expect(!status.rows.contains { if case .line = $0 { true } else { false } })
        #expect(status.handleKey("\u{19}"))
        #expect(status.rows.contains { if case .line = $0 { true } else { false } })
        withExtendedLifetime((environment, elsewhere)) {}
    }

    @Test func committingThroughTheEditor() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        try repo.write("a", "2\n")
        try await repo.git("add", "a")
        let elsewhere = try TestTree("x")
        let environment = try IndependentEnvironment()
        await environment.services.gitWriter.trust.trust(repo.repository)
        let owner = await window(repo, other: elsewhere.root, environment)
        defer { close(owner) }
        let status = try await open(owner.panes[0].browser)
        var asked: GitCommitEditor.Request?
        status.editCommitMessage = { request, _ in asked = request; return "Change a" }

        status.commit(.commit)
        await settle(status)
        #expect(asked?.amend == false)
        #expect(asked?.staged.contains("a |") == true)
        #expect(try await repo.git("log", "--format=%s") == "Change a\nfirst\n")
        #expect(status.rows == [.clean])

        // Cancelling the editor commits nothing.
        status.editCommitMessage = { _, _ in nil }
        status.commit(.reword)
        await settle(status)
        #expect(try await repo.git("log", "--format=%s") == "Change a\nfirst\n")
        withExtendedLifetime((environment, elsewhere)) {}
    }

    @Test func theDiffViewShowsWhatItCompares() async throws {
        let repo = try await GitFixture(["a": "1\n", "b": "1\n"])
        try repo.write("a", "2\n")
        try repo.write("b", "2\n")
        try await repo.git("add", "b")
        let elsewhere = try TestTree("x")
        let environment = try IndependentEnvironment()
        let owner = await window(repo, other: elsewhere.root, environment)
        defer { close(owner) }
        let status = try await open(owner.panes[0].browser)

        for (kind, paths) in [(GitDiffKind.unstaged, ["a"]), (.staged, ["b"]), (.uncommitted, ["a", "b"])] {
            status.showDiff(kind)
            let diff = try #require(status.diffView)
            _ = diff.view
            await diff.loadTask?.value
            #expect(diff.files.map(\.path) == paths)
            #expect(diff.handleKey("q"))
            #expect(status.diffView == nil)
        }
        withExtendedLifetime((environment, elsewhere)) {}
    }

    private func trustedWindow(_ repo: GitFixture, _ environment: IndependentEnvironment, _ elsewhere: TestTree) async throws
        -> (BrowserWindowController, GitStatusViewController) {
        await environment.services.gitWriter.trust.trust(repo.repository)
        let owner = await window(repo, other: elsewhere.root, environment)
        return (owner, try await open(owner.panes[0].browser))
    }

    @Test func theLogShowsCommitsWithTheirGraphAndDiffs() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        try repo.write("a", "2\n")
        try await repo.git("commit", "-q", "-am", "second")
        let elsewhere = try TestTree("x")
        let environment = try IndependentEnvironment()
        let (owner, status) = try await trustedWindow(repo, environment, elsewhere)
        defer { close(owner) }

        status.showLog(all: false)
        let log = try #require(status.logView)
        _ = log.view
        await log.loadTask?.value
        #expect(log.commits.map(\.subject) == ["second", "first"])
        #expect(log.graph.count == 2)
        #expect(GitLogViewController.spoken(log.commits[0]).contains("second"))
        log.table.selectRowIndexes([0], byExtendingSelection: false)
        #expect(log.handleKey("\r"))
        let diff = try #require(status.diffView)
        _ = diff.view
        await diff.loadTask?.value
        #expect(diff.files.map(\.path) == ["a"])
        #expect(diff.details?.contains("second") == true)
        #expect(diff.handleKey("q"))
        #expect(status.logView === log)

        withExtendedLifetime((environment, elsewhere)) {}
    }

    @Test func branchesFromTheStatusView() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        let elsewhere = try TestTree("x")
        let environment = try IndependentEnvironment()
        let (owner, status) = try await trustedWindow(repo, environment, elsewhere)
        defer { close(owner) }

        status.prompts.name = { _, _, _ in "topic" }
        status.branch(.createAndSwitch)
        await settle(status)
        #expect(status.status?.branch.head == "topic")
        status.prompts.choose = { _, options, _ in options.contains("main") ? "main" : nil }
        status.branch(.switchTo)
        await settle(status)
        #expect(status.status?.branch.head == "main")
        // Cancelling a prompt changes nothing.
        status.prompts.name = { _, _, _ in nil }
        status.branch(.create)
        await settle(status)
        #expect(try await repo.git("branch", "--format=%(refname:short)") == "main\ntopic\n")
        withExtendedLifetime((environment, elsewhere)) {}
    }

    @Test func closingThePaneStopsTheStatus() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        let elsewhere = try TestTree("x")
        let environment = try IndependentEnvironment()
        let owner = await window(repo, other: elsewhere.root, environment)
        let browser = owner.panes[0].browser
        try await open(browser)
        close(owner)
        #expect(browser.gitStatus == nil)
        withExtendedLifetime((environment, elsewhere)) {}
    }
}
