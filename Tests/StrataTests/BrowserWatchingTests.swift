import Foundation
import Synchronization
import Testing
@testable import Strata
@testable import StrataDev

/// A pane watches the folder it shows and that folder's repository; what it found for a folder it no longer shows is
/// dropped (late results never win).
@MainActor struct BrowserWatchingTests {
    @Test func aRepositoryFoundAfterThePaneMovedOnOrStoppedIsDropped() async throws {
        let tree = try TestTree("repo/.git/HEAD", "repo/src/")
        let store = GitStatusStore()
        store.isEnabled = true
        let watching = BrowserWatching()
        var current = true
        watching.watch([], repositoryOf: tree.url("repo/src"), in: store, changed: {}, isCurrent: { current })
        await watching.finding?.value
        #expect(watching.git?.repository.root.standardizedFileURL.path == tree.url("repo").standardizedFileURL.path)
        current = false
        watching.watch([], repositoryOf: tree.url("repo"), in: store, changed: {}, isCurrent: { current })
        #expect(watching.git == nil)
        await watching.finding?.value
        #expect(watching.git == nil)
        current = true
        watching.watch([], repositoryOf: tree.url("repo"), in: store, changed: {}, isCurrent: { current })
        watching.stop()
        await watching.finding?.value
        #expect(watching.git == nil)
        #expect(tree.snapshot() == ["repo/", "repo/.git/", "repo/.git/HEAD", "repo/src/"])
    }

    @Test func aChangeInTheWatchedFolderReadsItAgain() async throws {
        let tree = try TestTree("folder/")
        let watching = BrowserWatching()
        let changes = Mutex(0)
        // Watching once its folder is open: a change made then is caught.
        await watching.watch([tree.url("folder")], repositoryOf: tree.url("folder"), in: GitStatusStore(),
                             changed: { changes.withLock { $0 += 1 } }, isCurrent: { true }).value
        try tree.add(["folder/new.txt"])
        for _ in 0..<500 where changes.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(changes.withLock { $0 } > 0)
        watching.stop()
        #expect(tree.snapshot() == ["folder/", "folder/new.txt"])
    }

    /// Tools that rewrite a file where it is (no new name, no rename) change its contents and date but not the
    /// folder's entries; the folder is read again all the same, so its dates and sizes don't go stale.
    @Test func aFileRewrittenInPlaceReadsTheFolderAgain() async throws {
        let tree = try TestTree("folder/", "folder/a.txt", "elsewhere/", "elsewhere/b.txt")
        let watching = BrowserWatching()
        let changes = Mutex(0)
        await watching.watch([tree.url("folder")], repositoryOf: tree.url("folder"), in: GitStatusStore(),
                             changed: { changes.withLock { $0 += 1 } }, isCurrent: { true }).value
        // Making the tree just before watching arrives as events too: none of them counts.
        for _ in 0..<50 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(changes.withLock { $0 } == 0)
        // Another folder's file changing is none of this pane's business.
        try Self.appendInPlace(tree.url("elsewhere/b.txt"))
        for _ in 0..<50 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(changes.withLock { $0 } == 0)

        try Self.appendInPlace(tree.url("folder/a.txt"))
        for _ in 0..<500 where changes.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(changes.withLock { $0 } > 0)
        watching.stop()
        #expect(tree.snapshot() == ["elsewhere/", "elsewhere/b.txt", "folder/", "folder/a.txt"])
    }

    @Test func aPaneShowsTheNewDateAndSizeOfAFileRewrittenInPlace() async throws {
        let tree = try TestTree("folder/", "folder/a.txt")
        let file = tree.url("folder/a.txt")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: file.path)
        let environment = try IndependentEnvironment()
        let browser = BrowserViewController(services: environment.services)
        _ = browser.view
        defer { browser.stopBackgroundWork() }
        browser.load(tree.url("folder"))
        await browser.directoryReads.task?.value
        let before = try #require(browser.node(for: file)?.entry)
        #expect(before.modified == Date(timeIntervalSince1970: 1_000_000_000))

        try Self.appendInPlace(file)
        for _ in 0..<500 where browser.node(for: file)?.entry.modified == before.modified { try await Task.sleep(for: .milliseconds(10)) }
        let after = try #require(browser.node(for: file)?.entry)
        #expect(after.modified != before.modified)
        #expect(after.size == (before.size ?? 0) + 5)
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["folder/", "folder/a.txt"])
    }

    private static func appendInPlace(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("more\n".utf8))
        try handle.close()
    }
}
