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
        owner.toggleTerminalDrawer(nil)
        // Shown again, the same shell: never a second one.
        #expect(started.count == 1)
        withExtendedLifetime((tree, environment)) {}
    }
}
