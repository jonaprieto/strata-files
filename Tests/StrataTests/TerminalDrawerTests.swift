import AppKit
import Testing
@testable import Strata

/// The terminal drawer types for the user; the only line it runs takes an idle shell to the pane's folder.
@Suite struct TerminalDrawerTests {
    /// A mouse pressing `handle`, moving by `offset` in the window (up is positive) and letting go.
    private func drag(_ handle: NSView, by offset: NSPoint) {
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let start = NSPoint(x: 100, y: 100), end = NSPoint(x: 100 + offset.x, y: 100 + offset.y)
        handle.mouseDown(with: event(.leftMouseDown, start))
        handle.mouseDragged(with: event(.leftMouseDragged, end))
        handle.mouseUp(with: event(.leftMouseUp, end))
    }

    /// SwiftTerm keeps its colors as fixed values; the terminal's text and background follow the appearance, so dark
    /// never shows black text, nor light white.
    @Test func theTerminalsColorsFollowLightAndDark() throws {
        let terminal = DroppingTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        func brightness(_ color: NSColor) throws -> CGFloat { try #require(color.usingColorSpace(.sRGB)).brightnessComponent }
        for (name, dark) in [(NSAppearance.Name.darkAqua, true), (.aqua, false), (.darkAqua, true)] {
            terminal.appearance = NSAppearance(named: name)
            #expect((try brightness(terminal.nativeForegroundColor) > 0.7) == dark, "\(name)")
            #expect((try brightness(terminal.nativeBackgroundColor) < 0.3) == dark, "\(name)")
        }
    }

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
        let drawer = TerminalDrawerController(preferences: try Prefs.isolated())
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

    /// The drawer sits under the panes or at their right, the whole height; the choice is kept for the next window.
    @Test func theDrawerMovesToTheRightAndBackAndNewWindowsKeepIt() async throws {
        let tree = try TestTree("a/")
        let environment = try IndependentEnvironment()
        func open() async -> BrowserWindowController {
            let owner = BrowserWindowController(location: tree.url("a"), services: environment.services)
            owner.window?.setFrameAutosaveName("")
            owner.split.splitView.autosaveName = nil
            owner.window?.setContentSize(NSSize(width: 1200, height: 700))
            await owner.browser.directoryReads.task?.value
            owner.split.terminal.startShell = { _, _ in }
            return owner
        }
        let owner = await open()
        defer {
            owner.window?.contentViewController = nil
            owner.panes.forEach { $0.stopBackgroundWork() }
        }
        let drawer = owner.split.terminal
        func frames() -> (panes: NSRect, drawer: NSRect) {
            owner.split.splitView.layoutSubtreeIfNeeded()
            let content = drawer.view.superview!
            return (owner.split.panes.view.convert(owner.split.panes.view.bounds, to: content), drawer.view.frame)
        }
        owner.toggleTerminalDrawer(nil)
        #expect(drawer.edge == .bottom)
        var shown = frames()
        #expect(shown.drawer.height == TerminalDrawerController.defaultHeight && shown.drawer.maxY <= shown.panes.minY + 0.5)

        drawer.moveToOtherEdge()
        #expect(drawer.edge == .right && environment.services.preferences.terminalAtRight)
        shown = frames()
        #expect(shown.drawer.width == TerminalDrawerController.defaultWidth && shown.drawer.minX >= shown.panes.maxX - 0.5)
        // The whole height below the toolbar, which the panes run up under.
        let guide = drawer.view.superview!.safeAreaRect
        #expect(abs(shown.drawer.minY - shown.panes.minY) <= 0.5 && abs(shown.drawer.maxY - guide.maxY) <= 0.5, "\(shown) \(guide)")
        // Dragging the edge facing the panes toward them grows the drawer.
        drag(drawer.handle, by: NSPoint(x: -60, y: 0))
        #expect(drawer.sizeConstraint.constant == TerminalDrawerController.defaultWidth + 60)
        owner.toggleTerminalDrawer(nil)
        shown = frames()
        #expect(drawer.sizeConstraint.constant == 0 && shown.drawer.width == 0)

        let next = await open()
        defer {
            next.window?.contentViewController = nil
            next.panes.forEach { $0.stopBackgroundWork() }
        }
        _ = next.split.terminal.view
        #expect(next.split.terminal.edge == .right)

        owner.toggleTerminalDrawer(nil)
        drawer.moveToOtherEdge()
        shown = frames()
        #expect(drawer.edge == .bottom && !environment.services.preferences.terminalAtRight)
        #expect(shown.drawer.height == TerminalDrawerController.defaultHeight && shown.drawer.maxY <= shown.panes.minY + 0.5)
        drag(drawer.handle, by: NSPoint(x: 0, y: 50))
        #expect(drawer.sizeConstraint.constant == TerminalDrawerController.defaultHeight + 50)
        drag(drawer.handle, by: NSPoint(x: 0, y: -30))
        #expect(drawer.sizeConstraint.constant == TerminalDrawerController.defaultHeight + 20)
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
        #expect(owner.split.terminal.sizeConstraint.constant == TerminalDrawerController.defaultHeight)
        #expect(started.map { $0?.lexicallyStandardized } == [tree.url("a").lexicallyStandardized])
        owner.toggleTerminalDrawer(nil)
        #expect(!owner.split.terminal.isShown)
        #expect(owner.split.terminal.sizeConstraint.constant == 0)
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
