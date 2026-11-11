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
        // The files under the status are hidden, not just covered, and come back with it closed.
        #expect(browser.view.subviews.filter { !$0.isHidden } == [browser.gitStatus?.view])
        let button = NSToolbarItem(itemIdentifier: BrowserToolbar.identifier(.toggleGitStatus))
        #expect(owner.validateToolbarItem(button))
        #expect(button.toolTip == String(localized: "Hide Git Status"))
        let toggle = StrataCommand.toggleGitStatus.menuItem()
        #expect(browser.validateMenuItem(toggle))
        #expect(toggle.title == String(localized: "Hide Git Status"))
        browser.toggleGitStatus(nil)
        #expect(browser.outlineScrollView.isHidden == false)
        try await open(browser)
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

    @Test func kDiscardsAfterAskingAndUndoBringsItBack() async throws {
        let repo = try await GitFixture(["a": "1\n", "keep": "1\n"])
        try repo.write("a", "work\n")
        try repo.write("keep", "work\n")
        try repo.write("new", "untracked\n")
        let elsewhere = try TestTree("x")
        let environment = try IndependentEnvironment()
        let (owner, status) = try await trustedWindow(repo, environment, elsewhere)
        defer {
            close(owner)
            repo.tree.removeFromTrash(history: environment.services.transfers.history)
        }
        var asked: [String] = []
        status.prompts.confirm = { title, detail, _, _ in asked.append(detail); return false }
        select(status) { ["a", "new"].contains($0.path ?? "") }
        status.discardSelection()
        await settle(status)
        // Declined: nothing changes.
        #expect(asked.count == 1 && asked[0].contains("new") && asked[0].contains("a"))
        #expect(repo.text("a") == "work\n" && repo.text("new") == "untracked\n")

        status.prompts.confirm = { _, _, _, _ in true }
        select(status) { ["a", "new"].contains($0.path ?? "") }
        status.discardSelection()
        await settle(status)
        #expect(repo.text("a") == "1\n")
        #expect(repo.text("new") == nil)
        #expect(repo.text("keep") == "work\n")

        let undo = try #require(status.lastUndo)
        status.runUndo(undo.undo)
        await settle(status)
        #expect(repo.text("a") == "work\n")
        withExtendedLifetime((environment, elsewhere)) {}
    }

    @Test func stagedRowsAreNeverDiscarded() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        try repo.write("a", "staged\n")
        try await repo.git("add", "a")
        let elsewhere = try TestTree("x")
        let environment = try IndependentEnvironment()
        let (owner, status) = try await trustedWindow(repo, environment, elsewhere)
        defer { close(owner) }
        var asked = false
        status.prompts.confirm = { _, _, _, _ in asked = true; return true }
        select(status) { $0.section == .staged }
        status.discardSelection()
        await settle(status)
        #expect(!asked)
        #expect(status.message?.isError == true)
        #expect(try await repo.git("show", ":a") == "staged\n")
        withExtendedLifetime((environment, elsewhere)) {}
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

        // A hard reset from the log, asked first, and undone.
        status.prompts.confirm = { _, _, _, _ in true }
        status.reset(to: log.commits[1], mode: .hard)
        await settle(status)
        #expect(repo.text("a") == "1\n")
        status.runUndo(try #require(status.lastUndo).undo)
        await settle(status)
        #expect(repo.text("a") == "2\n")
        #expect(try await repo.git("log", "--format=%s", "-1") == "second\n")
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

    @Test func rebasingFromTheLogWithTheEditor() async throws {
        let repo = try await GitFixture(["base": "0\n"])
        for name in ["one", "two", "three"] {
            try repo.write(name, name + "\n")
            try await repo.git("add", name)
            try await repo.git("commit", "-q", "-m", name)
        }
        let elsewhere = try TestTree("x")
        let environment = try IndependentEnvironment()
        let (owner, status) = try await trustedWindow(repo, environment, elsewhere)
        defer { close(owner) }
        status.showLog(all: false)
        let log = try #require(status.logView)
        _ = log.view
        await log.loadTask?.value
        // "two" and everything newer.
        log.table.selectRowIndexes([1], byExtendingSelection: false)
        #expect(log.handleKey("r"))
        let editor = try #require(status.overlays.last as? GitRebaseEditor)
        _ = editor.view
        #expect(editor.todo.steps.map(\.commit.subject) == ["two", "three"])
        #expect(editor.handleKey("d"))
        #expect(editor.handleKey(String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), option: true))
        #expect(editor.todo.steps.map(\.commit.subject) == ["three", "two"])
        #expect(GitRebaseEditor.spoken(editor.todo.steps[1]).hasPrefix("drop"))
        #expect(editor.handleKey("\r"))
        await settle(status)
        #expect(status.overlays.isEmpty)
        #expect(try await repo.git("log", "--format=%s") == "three\none\nfirst\n")
        #expect(repo.text("two") == nil)

        status.runUndo(try #require(status.lastUndo).undo)
        await settle(status)
        #expect(try await repo.git("log", "--format=%s") == "three\ntwo\none\nfirst\n")
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

    // MARK: - Usability

    @Test func onlyNPAndArrowsMoveAndKStillAsksToDiscard() async throws {
        let repo = try await GitFixture(["a": "1\n", "b": "1\n"])
        try repo.write("a", "2\n")
        try repo.write("b", "2\n")
        let elsewhere = try TestTree("x")
        let environment = try IndependentEnvironment()
        let (owner, status) = try await trustedWindow(repo, environment, elsewhere)
        defer { close(owner) }
        select(status) { $0.path == "a" }
        let before = status.table.selectedRowIndexes
        #expect(!status.handleKey("j"))
        #expect(status.table.selectedRowIndexes == before)
        var asked = false
        status.prompts.confirm = { _, _, _, _ in asked = true; return false }
        #expect(status.handleKey("k"))
        await settle(status)
        #expect(asked && status.table.selectedRowIndexes == before)
        #expect(status.handleKey("n"))
        #expect(status.selectedRows.first?.path == "b")
        #expect(repo.text("a") == "2\n" && repo.text("b") == "2\n")
        withExtendedLifetime((environment, elsewhere)) {}
    }

    @Test func stagingMovesOnToTheNextFileAndAnEditedFileStaysSelected() async throws {
        let repo = try await GitFixture(["a": "1\n", "b": "1\n", "c": "1\n"])
        for name in ["a", "b", "c"] { try repo.write(name, "2\n") }
        let elsewhere = try TestTree("x")
        let environment = try IndependentEnvironment()
        let (owner, status) = try await trustedWindow(repo, environment, elsewhere)
        defer { close(owner) }
        select(status) { $0.path == "b" }
        #expect(status.handleKey("s"))
        await settle(status)
        #expect(try await repo.git("diff", "--cached", "--name-only") == "b\n")
        #expect(status.selectedRows.map(\.path) == ["c"])

        // The selected file's diff changes on disk while a file above it goes back to unchanged: it stays the one
        // selected, not whichever row is now where it was.
        try repo.write("a", "1\n")
        try repo.write("c", "3\n")
        status.reload()
        await settle(status)
        #expect(status.status?.unstaged.first { $0.path == "c" }?.hunks.first?.lines.contains { $0.text == "3" } == true)
        #expect(status.selectedRows.map(\.path) == ["c"])
        withExtendedLifetime((environment, elsewhere)) {}
    }

    @Test func keyLinesSayWhatEachViewDoes() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        try repo.write("a", "2\n")
        let elsewhere = try TestTree("x")
        let environment = try IndependentEnvironment()
        let (owner, status) = try await trustedWindow(repo, environment, elsewhere)
        defer { close(owner) }
        #expect(status.hintLabel.stringValue.contains("s stage"))
        #expect(!status.hintLabel.isHidden)
        status.showLog(all: false)
        let log = try #require(status.logView)
        _ = log.view
        await log.loadTask?.value
        #expect(log.hint?.contains("x reset") == true)
        #expect(log.hintLabel.isHidden == false)
        // The panel's log runs none of these.
        let panelLog = GitLogViewController(all: false, workbench: status.workbench)
        _ = panelLog.view
        #expect(panelLog.hintLabel.isHidden)
        panelLog.stop()
        status.showDiff(.unstaged)
        let diff = try #require(status.diffView)
        _ = diff.view
        #expect(diff.hintLabel.stringValue.contains("q back"))
        withExtendedLifetime((environment, elsewhere)) {}
    }

    @Test func theRightClickMenuStagesTheClickedFile() async throws {
        let repo = try await GitFixture(["a": "1\n", "b": "1\n"])
        try repo.write("a", "2\n")
        try repo.write("b", "2\n")
        let elsewhere = try TestTree("x")
        let environment = try IndependentEnvironment()
        let (owner, status) = try await trustedWindow(repo, environment, elsewhere)
        defer { close(owner) }
        select(status) { $0.path == "a" }
        let row = try #require(status.rows.firstIndex { $0.path == "b" })
        let menu = status.contextMenu(for: row)
        // A right click outside the selection selects the clicked row, as in the files.
        #expect(status.selectedRows.map(\.path) == ["b"])
        let stage = try #require(menu.items.firstIndex { $0.title == String(localized: "Stage the selection") })
        #expect(menu.items.contains { $0.title == String(localized: "Discard the selection…") })
        menu.performActionForItem(at: stage)
        await settle(status)
        #expect(try await repo.git("diff", "--cached", "--name-only") == "b\n")
        withExtendedLifetime((environment, elsewhere)) {}
    }

    @Test func feedbackIsMoreThanColor() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        try repo.write("a", "2\n")
        let elsewhere = try TestTree("x")
        let environment = try IndependentEnvironment()
        let (owner, status) = try await trustedWindow(repo, environment, elsewhere)
        defer { close(owner) }
        status.show("Bad", isError: true)
        #expect(status.messageSymbol == "exclamationmark.triangle.fill")
        status.show("Good", isError: false, done: true)
        #expect(status.messageSymbol == "checkmark.circle")
        status.show("Note", isError: false)
        #expect(status.messageSymbol == "info.circle")

        // A key pressed while a command waits says why nothing happened.
        var answer: CheckedContinuation<Bool, Never>?
        status.prompts.confirm = { _, _, _, _ in await withCheckedContinuation { answer = $0 } }
        select(status) { $0.path == "a" }
        status.discardSelection()
        for _ in 0..<500 where answer == nil { try await Task.sleep(for: .milliseconds(10)) }
        status.run(.stage)
        #expect(status.message?.text == String(localized: "Git is still running a command here."))
        answer?.resume(returning: false)
        await settle(status)
        #expect(repo.text("a") == "2\n")
        withExtendedLifetime((environment, elsewhere)) {}
    }

    @Test func theHeaderSpinsWhileTheStatusIsRead() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        let environment = try IndependentEnvironment()
        let status = GitStatusViewController(workbench: GitWorkbench(repository: repo.repository, writer: environment.services.gitWriter),
                                             services: environment.services)
        _ = status.view
        #expect(status.header.accessibilityLabel()?.contains(String(localized: "Git is running")) == true)
        await status.loadTask?.value
        #expect(status.header.accessibilityLabel()?.contains(String(localized: "Git is running")) == false)
        status.stop()
        withExtendedLifetime(environment) {}
    }

    @Test func transientsOpenAtTheSelectedRow() async throws {
        let repo = try await GitFixture(["a": "1\n", "b": "1\n"])
        try repo.write("a", "2\n")
        try repo.write("b", "2\n")
        let elsewhere = try TestTree("x")
        let environment = try IndependentEnvironment()
        let (owner, status) = try await trustedWindow(repo, environment, elsewhere)
        defer { close(owner) }
        status.table.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        select(status) { $0.path == "b" }
        let row = status.table.selectedRow
        #expect(GitTransient.anchor(in: status.table) == status.table.rect(ofRow: row))
        withExtendedLifetime((environment, elsewhere)) {}
    }

    @Test func diffsAndTheLogReadAtAGlance() async throws {
        let added = GitStatusCell.Content.line(GitDiffLine(kind: .added, text: "x"))
        let removed = GitStatusCell.Content.line(GitDiffLine(kind: .removed, text: "x"))
        let context = GitStatusCell.Content.line(GitDiffLine(kind: .context, text: "x"))
        #expect(added.background != nil && removed.background != nil && context.background == nil)
        let cell = GitStatusCell()
        cell.show(added)
        #expect(cell.layer?.backgroundColor != nil)
        cell.show(context)
        #expect(cell.layer?.backgroundColor == nil)

        let commit = GitCommit(id: String(repeating: "a", count: 40), parents: [], author: "A", email: "a@b", date: Date(), refs: [], subject: "s")
        #expect(GitLogViewController.spoken(commit).contains(RelativeDateTimeFormatter.git.localizedString(for: Date(), relativeTo: Date())))
        #expect(!GitLogViewController.spoken(commit).contains("in 0"))

        let repo = try await GitFixture(["a": "1\n"])
        let environment = try IndependentEnvironment()
        let log = GitLogViewController(all: false, workbench: GitWorkbench(repository: repo.repository, writer: environment.services.gitWriter))
        _ = log.view
        await log.loadTask?.value
        #expect(log.table.tableColumns[0].width < 40)
        log.stop()
        withExtendedLifetime(environment) {}
    }

    @Test func longRowsTruncateInANarrowPanelInsteadOfRunningIntoTheNext() {
        let long = String(repeating: "feat(transactions): keep the usual filters ", count: 4)
        let cell = GitStatusCell()
        cell.show(.init(text: NSAttributedString(string: long, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]),
                        accessibility: long, indent: 0))
        let label = try! #require(cell.textField)
        let one = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 1_000)).height
        let narrow = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: 180, height: 1_000)).height
        #expect(narrow == one)
        // A commit's message above its diff keeps its lines; the next row shown in that cell is one line again.
        cell.textField?.maximumNumberOfLines = 0
        cell.show(.init(text: NSAttributedString(string: "a\nb"), accessibility: "", indent: 0))
        #expect(cell.textField?.maximumNumberOfLines == 1)
    }

    @Test func theLogFitsANarrowPanel() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        let environment = try IndependentEnvironment()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let log = GitLogViewController(all: false, workbench: GitWorkbench(repository: repo.repository, writer: environment.services.gitWriter))
        window.contentViewController = log
        window.setContentSize(NSSize(width: 220, height: 300))
        await log.loadTask?.value
        window.contentView?.layoutSubtreeIfNeeded()
        // The commit column ends where the panel does, so long subjects end in an ellipsis rather than off the edge.
        #expect(log.table.frame.width <= 220)
        window.contentViewController = nil
        log.stop()
        withExtendedLifetime(environment) {}
    }
}
