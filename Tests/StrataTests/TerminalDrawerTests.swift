import AppKit
import Testing
@testable import Strata

/// The terminal drawer types for the user and never runs anything itself.
@Suite struct TerminalDrawerTests {
    @Test func droppedPathsAreQuotedAndNeverEndInReturn() {
        let text = TerminalText.paths([URL(fileURLWithPath: "/tmp/a b"), URL(fileURLWithPath: "/tmp/it's"), URL(fileURLWithPath: "/tmp/$(rm -rf ~)")])
        #expect(text == "'/tmp/a b' '/tmp/it'\\''s' '/tmp/$(rm -rf ~)' ")
        #expect(text?.contains("\n") == false && text?.contains("\r") == false)
        // A name with a control character could act as a key in the shell's line editor: nothing is typed.
        #expect(TerminalText.paths([URL(fileURLWithPath: "/tmp/a\rb")]) == nil)
        #expect(TerminalText.paths([URL(fileURLWithPath: "/tmp/ok"), URL(fileURLWithPath: "/tmp/a\nb")]) == nil)
        #expect(TerminalText.paths([]) == nil)
        #expect(TerminalText.changeDirectory(to: URL(fileURLWithPath: "/Users/me/my repo")) == "cd '/Users/me/my repo'")
    }

    /// Shown again from another folder, an idle shell goes there; one running a program is left alone, and a shell
    /// already there is too.
    @Test func anIdleShellFollowsThePaneWhenShownAgain() {
        let folder = URL(fileURLWithPath: "/Users/me/my repo")
        #expect(TerminalText.follow(to: folder, shellIn: "/Users/me", atPrompt: true) == "\u{05}\u{15} cd '/Users/me/my repo'\r")
        #expect(TerminalText.follow(to: folder, shellIn: "/Users/me", atPrompt: false) == nil)
        #expect(TerminalText.follow(to: folder, shellIn: "/Users/me/my repo", atPrompt: true) == nil)
        #expect(TerminalText.follow(to: folder, shellIn: "/Users/me/my repo/", atPrompt: true) == nil)
        #expect(TerminalText.follow(to: URL(fileURLWithPath: "/var/x"), shellIn: "/private/var/x", atPrompt: true) == nil)
        #expect(TerminalText.follow(to: nil, shellIn: "/Users/me", atPrompt: true) == nil)
        #expect(TerminalText.follow(to: URL(fileURLWithPath: "/tmp/a\rb"), shellIn: "/Users/me", atPrompt: true) == nil)
    }

    /// The shell's folder and whether a program is in front, read from a real shell (sh, not the login shell).
    @Test func theShellsFolderAndPromptAreReadFromTheSystem() async throws {
        let tree = try TestTree("a/")
        let drawer = TerminalDrawerController()
        _ = drawer.view
        drawer.terminal.startProcess(executable: "/bin/sh", args: [], environment: ["PATH=/usr/bin:/bin", "PS1=$ "], execName: nil,
                                     currentDirectory: tree.url("a").path)
        defer { drawer.terminal.terminate() }
        // A shell starting and a program taking over can be slow while other suites run; each wait ends once it holds.
        for _ in 0..<3000 where drawer.shellState().folder == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(drawer.shellState().folder.map { PathSpelling.short(URL(fileURLWithPath: $0)) } == PathSpelling.short(tree.url("a")))
        #expect(drawer.shellState().atPrompt)
        // A program in front of the shell has the terminal: the shell isn't at its prompt.
        drawer.terminal.send(txt: "sleep 30\r")
        for _ in 0..<3000 where drawer.shellState().atPrompt { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!drawer.shellState().atPrompt)
        withExtendedLifetime(tree) {}
    }

    @Test func showingTheDrawerAgainTakesTheShellToThePanesFolder() async throws {
        let tree = try TestTree("a/", "b/")
        let environment = try IndependentEnvironment()
        let owner = BrowserWindowController(location: tree.url("a"), services: environment.services)
        owner.window?.setFrameAutosaveName("")
        owner.split.splitView.autosaveName = nil
        defer {
            owner.window?.contentViewController = nil
            owner.panes.forEach { $0.stopBackgroundWork() }
        }
        await owner.browser.directoryReads.task?.value
        let drawer = owner.split.terminal
        var typed: [String] = []
        var shell = (folder: Optional(tree.url("a").path), atPrompt: true)
        drawer.startShell = { _, _ in }
        drawer.shellState = { shell }
        drawer.type = { typed.append($0) }

        owner.toggleTerminalDrawer(nil)
        owner.toggleTerminalDrawer(nil)
        owner.navigate(to: tree.url("b"))
        await owner.browser.directoryReads.task?.value
        shell.atPrompt = false
        owner.toggleTerminalDrawer(nil)
        #expect(typed.isEmpty, "A program is running in the shell: nothing is typed into it.")
        owner.toggleTerminalDrawer(nil)
        shell.atPrompt = true
        owner.toggleTerminalDrawer(nil)
        #expect(typed == [TerminalText.follow(to: try #require(owner.browser.directory), shellIn: tree.url("a").path, atPrompt: true)])
        #expect(typed.first?.contains("/b'") == true)
        // Shown again where the shell already is: nothing more.
        shell.folder = tree.url("b").path
        owner.toggleTerminalDrawer(nil)
        owner.toggleTerminalDrawer(nil)
        #expect(typed.count == 1)
        withExtendedLifetime((tree, environment)) {}
    }

    @Test func theDrawerStartsOneShellInThePanesFolderAndHides() async throws {
        let tree = try TestTree("a/")
        let environment = try IndependentEnvironment()
        let owner = BrowserWindowController(location: tree.url("a"), services: environment.services)
        owner.window?.setFrameAutosaveName("")
        owner.split.splitView.autosaveName = nil
        defer {
            owner.window?.contentViewController = nil
            owner.panes.forEach { $0.stopBackgroundWork() }
        }
        await owner.browser.directoryReads.task?.value
        var started: [URL?] = []
        owner.split.terminal.startShell = { _, folder in started.append(folder) }

        owner.toggleTerminalDrawer(nil)
        #expect(owner.split.terminal.isShown)
        #expect(owner.split.terminal.heightConstraint.constant == TerminalDrawerController.defaultHeight)
        #expect(started.map { $0?.lexicallyStandardized } == [tree.url("a").lexicallyStandardized])
        owner.toggleTerminalDrawer(nil)
        #expect(!owner.split.terminal.isShown)
        #expect(owner.split.terminal.heightConstraint.constant == 0)
        let button = NSToolbarItem(itemIdentifier: BrowserToolbar.identifier(.toggleTerminalDrawer))
        #expect(owner.validateToolbarItem(button))
        #expect(button.toolTip == String(localized: "Show Terminal"))
        owner.toggleTerminalDrawer(nil)
        #expect(owner.validateToolbarItem(button))
        #expect(button.toolTip == String(localized: "Hide Terminal"))
        // Shown again, the same shell: never a second one.
        #expect(started.count == 1)
        withExtendedLifetime((tree, environment)) {}
    }
}
