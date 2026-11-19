import AppKit
import Testing
@testable import Strata
@testable import StrataModel

@Suite struct DiredKeysTests {
    private func window(at folder: URL, second: URL? = nil, _ environment: IndependentEnvironment) async -> BrowserWindowController {
        environment.preferences.diredKeys = true
        let owner = BrowserWindowController(location: folder, secondPane: second, services: environment.services)
        owner.window?.setFrameAutosaveName("")
        owner.split.splitView.autosaveName = nil
        for pane in owner.panes { await pane.browser.directoryReads.task?.value }
        return owner
    }

    private func close(_ owner: BrowserWindowController) {
        owner.window?.contentViewController = nil
        owner.panes.forEach { $0.stopBackgroundWork() }
    }

    private func until(_ done: () -> Bool) async throws {
        for _ in 0..<1_000 where !done() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(done())
    }

    @Test func eachLetterNamesItsMenuCommandAndOtherLettersNothing() {
        let commands: [(String, StrataCommand)] = [
            ("f", .openSelection), ("^", .goToEnclosingFolder), ("g", .reloadFolder), ("R", .renameSelection),
            ("+", .newFolder), ("C", .copyToOtherPane), ("D", .moveToTrash), ("w", .copyName), ("W", .copyRelativePath),
        ]
        for (letter, command) in commands {
            guard case .run(let found) = DiredKey(letter) else { Issue.record("\(letter) runs nothing"); continue }
            #expect(found.id == command.id)
        }
        for letter in ["d", "x", "r", "c", "q", "é", ""] { #expect(DiredKey(letter) == nil) }
    }

    @Test func lettersFilterWhileDiredKeysAreOff() async throws {
        let tree = try TestTree("a", "D")
        let environment = try IndependentEnvironment()
        let owner = await window(at: tree.root, environment)
        defer { close(owner) }
        environment.preferences.diredKeys = false
        owner.browser.select([tree.url("a")])

        #expect(owner.browser.handle(.type("D")))
        #expect(owner.browser.filter == "D")
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["D", "a"])
    }

    @Test func aLetterWithNoCommandDoesNothing() async throws {
        let tree = try TestTree("a", "b")
        let environment = try IndependentEnvironment()
        let owner = await window(at: tree.root, environment)
        defer { close(owner) }
        owner.browser.select([tree.url("a")])

        #expect(owner.browser.handle(.type("a")))
        #expect(owner.browser.filter.isEmpty)
        #expect(owner.browser.selectedURLs == [tree.url("a")])
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["a", "b"])
    }

    @Test func nAndPMoveTheSelection() async throws {
        let tree = try TestTree("a", "b", "c")
        let environment = try IndependentEnvironment()
        let owner = await window(at: tree.root, environment)
        defer { close(owner) }
        let browser = owner.browser
        browser.setMode(.list, remember: false)
        owner.window?.makeFirstResponder(browser.outlineView)
        browser.select([tree.url("a")])

        _ = browser.handle(.type("n"))
        #expect(browser.selectedURLs == [tree.url("b")])
        _ = browser.handle(.type("n"))
        #expect(browser.selectedURLs == [tree.url("c")])
        _ = browser.handle(.type("p"))
        #expect(browser.selectedURLs == [tree.url("b")])
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["a", "b", "c"])
    }

    @Test func jAndKPressedForRealMoveTheSelection() async throws {
        let tree = try TestTree("a", "b")
        let environment = try IndependentEnvironment()
        let owner = await window(at: tree.root, environment)
        defer { close(owner) }
        let browser = owner.browser
        browser.setMode(.list, remember: false)
        owner.window?.makeFirstResponder(browser.outlineView)
        browser.select([tree.url("a")])
        func press(_ letter: String) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: 0, context: nil, characters: letter,
                                                      charactersIgnoringModifiers: letter, isARepeat: false, keyCode: 0))
            browser.outlineView.keyDown(with: event)
        }

        try press("j")
        #expect(browser.selectedURLs == [tree.url("b")])
        try press("k")
        #expect(browser.selectedURLs == [tree.url("a")])
        #expect(browser.filter.isEmpty)
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["a", "b"])
    }

    @Test func capitalJAndKAddToTheSelectionInAList() async throws {
        let tree = try TestTree("a", "b", "c")
        let environment = try IndependentEnvironment()
        let owner = await window(at: tree.root, environment)
        defer { close(owner) }
        let browser = owner.browser
        browser.setMode(.list, remember: false)
        owner.window?.makeFirstResponder(browser.outlineView)
        browser.select([tree.url("a")])

        _ = browser.handle(.type("J"))
        _ = browser.handle(.type("J"))
        #expect(browser.selectedURLs == [tree.url("a"), tree.url("b"), tree.url("c")])
        _ = browser.handle(.type("K"))
        #expect(browser.selectedURLs == [tree.url("a"), tree.url("b")])
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["a", "b", "c"])
    }

    @Test func hAndLLeaveAndEnterFoldersInAList() async throws {
        let tree = try TestTree("inside/", "inside/a")
        let environment = try IndependentEnvironment()
        let owner = await window(at: tree.root, environment)
        defer { close(owner) }
        owner.browser.setMode(.list, remember: false)
        owner.browser.select([tree.url("inside")])

        _ = owner.browser.handle(.type("l"))
        try await until { owner.browser.directory?.lastPathComponent == "inside" }
        _ = owner.browser.handle(.type("h"))
        try await until { owner.browser.directory?.lastPathComponent == tree.root.lastPathComponent }
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["inside/", "inside/a"])
    }

    @Test func hAndLMoveAcrossColumns() async throws {
        let tree = try TestTree("inside/", "inside/a")
        let environment = try IndependentEnvironment()
        let owner = await window(at: tree.root, environment)
        defer { close(owner) }
        let window = try #require(owner.window)
        owner.browser.setMode(.columns, remember: false)
        owner.browser.select([tree.url("inside")])
        let columns = try #require(owner.browser.presentations.columnController)
        let panes = { Self.views(of: ColumnPane.self, in: columns.view) }
        try await until { panes().contains { !$0.isRoot && $0.isLoaded } }
        let root = try #require(panes().first { $0.isRoot })
        let deeper = try #require(panes().first { !$0.isRoot })
        window.makeFirstResponder(root.tableView)

        _ = owner.browser.handle(.type("l"))
        #expect(window.firstResponder === deeper.tableView)
        _ = owner.browser.handle(.type("h"))
        #expect(window.firstResponder === root.tableView)
        #expect(owner.browser.directory?.lastPathComponent == tree.root.lastPathComponent)
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["inside/", "inside/a"])
    }

    @Test func hjklMoveBetweenDiskUsageTiles() async throws {
        let tree = try TestTree("big", "small")
        try Data(count: 64_000).write(to: tree.url("big"))
        try Data(count: 16_000).write(to: tree.url("small"))
        let environment = try IndependentEnvironment()
        let owner = await window(at: tree.root, environment)
        defer { close(owner) }
        let window = try #require(owner.window)
        owner.browser.setMode(.treemap, remember: false)
        let map = try #require(owner.browser.presentations.treemapController).treemapView
        try await until { [tree.url("big"), tree.url("small")].allSatisfy { map.tile(forKey: $0.fileViewKey) != nil } }
        let big = try #require(map.frame(forKey: tree.url("big").fileViewKey))
        let small = try #require(map.frame(forKey: tree.url("small").fileViewKey))
        window.makeFirstResponder(map)
        owner.browser.select([tree.url("big")])
        try #require(small.midX > big.midX)

        _ = owner.browser.handle(.type("l"))
        #expect(owner.browser.selectedURLs == [tree.url("small")])
        _ = owner.browser.handle(.type("h"))
        #expect(owner.browser.selectedURLs == [tree.url("big")])
        #expect(owner.browser.directory?.lastPathComponent == tree.root.lastPathComponent)
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["big", "small"])
    }

    @Test func hAndKPastTheEdgeOfDiskUsageGoToTheEnclosingFolder() async throws {
        for letter in ["h", "k"] {
            let tree = try TestTree("inside/", "inside/big", "inside/small")
            try Data(count: 64_000).write(to: tree.url("inside/big"))
            try Data(count: 16_000).write(to: tree.url("inside/small"))
            let environment = try IndependentEnvironment()
            let owner = await window(at: tree.url("inside"), environment)
            defer { close(owner) }
            owner.browser.setMode(.treemap, remember: false)
            let map = try #require(owner.browser.presentations.treemapController).treemapView
            try await until { map.tile(forKey: tree.url("inside/big").fileViewKey) != nil }
            let big = try #require(map.frame(forKey: tree.url("inside/big").fileViewKey))
            let small = try #require(map.frame(forKey: tree.url("inside/small").fileViewKey))
            try #require(big.midX < small.midX && big.minY <= small.minY + 1)
            owner.window?.makeFirstResponder(map)
            owner.browser.select([tree.url("inside/big")])

            _ = owner.browser.handle(.type(letter))
            try await until { owner.browser.directory?.lastPathComponent == tree.root.lastPathComponent }
            withExtendedLifetime(environment) {}
            #expect(tree.snapshot() == ["inside/", "inside/big", "inside/small"])
        }
    }

    @Test func diskUsageTakesDAndShiftMovesFromItsKeyboard() async throws {
        let tree = try TestTree("big", "small", "smaller")
        try Data(count: 64_000).write(to: tree.url("big"))
        try Data(count: 32_000).write(to: tree.url("small"))
        try Data(count: 16_000).write(to: tree.url("smaller"))
        let environment = try IndependentEnvironment()
        let owner = await window(at: tree.root, environment)
        defer {
            tree.removeFromTrash(history: environment.services.transfers.history)
            close(owner)
        }
        owner.browser.setMode(.treemap, remember: false)
        let map = try #require(owner.browser.presentations.treemapController).treemapView
        let names = ["big", "small", "smaller"]
        try await until { names.allSatisfy { map.tile(forKey: tree.url($0).fileViewKey) != nil } }
        owner.window?.makeFirstResponder(map)
        owner.browser.select([tree.url("big")])
        func press(_ characters: String, keyCode: UInt16 = 0, _ modifiers: NSEvent.ModifierFlags = []) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                                      windowNumber: 0, context: nil, characters: characters,
                                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
            map.keyDown(with: event)
        }
        let big = try #require(map.frame(forKey: tree.url("big").fileViewKey))
        let small = try #require(map.frame(forKey: tree.url("small").fileViewKey))
        let right = String(Character(try #require(UnicodeScalar(NSRightArrowFunctionKey))))
        try #require(small.midX > big.midX)

        try press(right, keyCode: KeyCode.rightArrow, [.shift, .function, .numericPad])
        #expect(Set(owner.browser.selectedURLs) == [tree.url("big"), tree.url("small")])
        try press("L", [.shift])
        #expect(owner.browser.selectedURLs.count >= 2)
        owner.browser.select([tree.url("small")])
        try press("D", [.shift])
        try await until { !tree.snapshot().contains("small") }
        try await until { map.tile(forKey: tree.url("small").fileViewKey) == nil }
        #expect(tree.snapshot() == ["big", "smaller"])
        withExtendedLifetime(environment) {}
    }

    @Test func slashStartsAFilterAndEscapeTakesItBack() async throws {
        let tree = try TestTree("a", "ad")
        let environment = try IndependentEnvironment()
        let owner = await window(at: tree.root, environment)
        defer { close(owner) }
        let browser = owner.browser
        browser.select([tree.url("a")])

        _ = browser.handle(.type("/"))
        _ = browser.handle(.escape)
        _ = browser.handle(.type("a"))
        #expect(browser.filter.isEmpty)

        _ = browser.handle(.type("/"))
        _ = browser.handle(.type("a"))
        _ = browser.handle(.type("D"))
        #expect(browser.filter == "aD")
        _ = browser.handle(.escape)
        #expect(browser.filter.isEmpty)
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["a", "ad"])
    }

    @Test func leavingTheFolderForgetsASlash() async throws {
        let tree = try TestTree("a")
        let environment = try IndependentEnvironment()
        let owner = await window(at: tree.root, environment)
        defer { close(owner) }
        _ = owner.browser.handle(.type("/"))
        owner.browser.clearFilter()

        _ = owner.browser.handle(.type("a"))
        #expect(owner.browser.filter.isEmpty)
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["a"])
    }

    @Test func fGoesIntoAFolderAndCaretComesBack() async throws {
        let tree = try TestTree("inside/", "inside/a")
        let environment = try IndependentEnvironment()
        let owner = await window(at: tree.root, environment)
        defer { close(owner) }
        owner.browser.select([tree.url("inside")])

        _ = owner.browser.handle(.type("f"))
        try await until { owner.browser.directory?.lastPathComponent == "inside" }
        _ = owner.browser.handle(.type("^"))
        try await until { owner.browser.directory?.lastPathComponent == tree.root.lastPathComponent }
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["inside/", "inside/a"])
    }

    @Test func dTrashesExactlyTheSelectionInEveryView() async throws {
        for mode in BrowserViewMode.ordered {
            let tree = try TestTree("a", "ab", "a.txt", "folder/", "folder/a")
            let environment = try IndependentEnvironment()
            let owner = await window(at: tree.root, environment)
            defer {
                tree.removeFromTrash(history: environment.services.transfers.history)
                close(owner)
            }
            owner.browser.setMode(mode, remember: false)
            owner.browser.select([tree.url("a")])
            try #require(owner.browser.selectedURLs == [tree.url("a")])

            _ = owner.browser.handle(.type("D"))
            try await until { !tree.snapshot().contains("a") }
            #expect(tree.snapshot() == ["a.txt", "ab", "folder/", "folder/a"])
        }
    }

    @Test func aDeeperColumnTakesItsLettersAndTrashesOnlyItsSelection() async throws {
        let tree = try TestTree("inside/", "inside/a", "inside/ab", "a")
        let environment = try IndependentEnvironment()
        let owner = await window(at: tree.root, environment)
        defer {
            tree.removeFromTrash(history: environment.services.transfers.history)
            close(owner)
        }
        owner.browser.setMode(.columns, remember: false)
        owner.browser.select([tree.url("inside")])
        let columns = try #require(owner.browser.presentations.columnController)
        func deeper() -> ColumnPane? { Self.views(of: ColumnPane.self, in: columns.view).first { !$0.isRoot && $0.isLoaded } }
        try await until { deeper() != nil }
        let pane = try #require(deeper())
        environment.preferences.diredKeys = false
        #expect(!pane.handleKey(.type("D")))
        environment.preferences.diredKeys = true

        let row = try #require(pane.entries.firstIndex { $0.name == "a" })
        pane.tableView.selectRowIndexes([row], byExtendingSelection: false)
        #expect(pane.handleKey(.type("D")))
        try await until { !tree.snapshot().contains("inside/a") }
        #expect(tree.snapshot() == ["a", "inside/", "inside/ab"])
    }

    private static func views<View: NSView>(of type: View.Type, in root: NSView) -> [View] {
        root.subviews.flatMap { ([$0 as? View].compactMap { $0 }) + views(of: type, in: $0) }
    }

    @Test func aKeyFromThePaneWithoutTheFocusChangesNothing() async throws {
        let tree = try TestTree("left/", "left/a", "right/", "right/b")
        let environment = try IndependentEnvironment()
        let owner = await window(at: tree.url("left"), second: tree.url("right"), environment)
        defer { close(owner) }
        let quiet = try #require(owner.panes.first { $0 !== owner.pane })
        for pane in owner.panes {
            let folder = try #require(pane.browser.directory)
            pane.browser.select([folder.appendingPathComponent(folder.lastPathComponent == "left" ? "a" : "b")])
            try #require(pane.browser.selectedURLs.count == 1)
        }

        _ = quiet.browser.handle(.type("D"))
        for _ in 0..<20 { await Task.yield() }
        await FileOps.undoWork?.value
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["left/", "left/a", "right/", "right/b"])
    }

    @Test func copyingWithoutASecondPaneIsRefusedAsTheMenuRefusesIt() async throws {
        let tree = try TestTree("a")
        let environment = try IndependentEnvironment()
        let owner = await window(at: tree.root, environment)
        defer { close(owner) }
        owner.browser.select([tree.url("a")])

        _ = owner.browser.handle(.type("C"))
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["a"])
    }
}
