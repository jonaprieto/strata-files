import AppKit
import Testing
@testable import Strata

@Suite struct CopyPathTextTests {
    @Test func nameIsTheLastComponentOfWhatCopyPathCopies() {
        #expect(ClipboardCommands.name(ofPath: "/Users/me/repo/a.txt") == "a.txt")
        #expect(ClipboardCommands.name(ofPath: "deploy@web-1:/srv/app") == "app")
        #expect(ClipboardCommands.name(ofPath: "web") == "web")
        #expect(ClipboardCommands.name(ofPath: "/Users/me/folder/") == "folder")
    }

    @Test func relativeToTheRepositoryRootWhenThereIsOne() {
        #expect(ClipboardCommands.relativePath("/r/Sources/a.swift", repositoryRoot: "/r", folder: "/r/Sources") == "Sources/a.swift")
        #expect(ClipboardCommands.relativePath("/r", repositoryRoot: "/r", folder: "/r") == ".")
        // A look-alike folder next to the root is not inside it.
        #expect(ClipboardCommands.relativePath("/rr/a", repositoryRoot: "/r", folder: "/rr") == "a")
    }

    @Test func relativeToThePaneFolderOutsideARepository() {
        #expect(ClipboardCommands.relativePath("/f/sub/a", repositoryRoot: nil, folder: "/f") == "sub/a")
        #expect(ClipboardCommands.relativePath("/f", repositoryRoot: nil, folder: "/f") == ".")
        #expect(ClipboardCommands.relativePath("/elsewhere/a", repositoryRoot: nil, folder: "/f") == "/elsewhere/a")
    }

    private func browser(at folder: URL, _ environment: IndependentEnvironment) async -> BrowserViewController {
        let browser = BrowserViewController(services: environment.services)
        _ = browser.view
        browser.load(folder)
        await browser.directoryReads.task?.value
        return browser
    }

    @Test func copyNameAndRelativePathFromAPane() async throws {
        let tree = try TestTree("repo/", "repo/.git/", "repo/.git/HEAD", "repo/src/", "repo/src/a.swift", "repo/src/ab.swift")
        let environment = try IndependentEnvironment()
        let browser = await browser(at: tree.url("repo/src"), environment)
        browser.select([tree.url("repo/src/a.swift"), tree.url("repo/src/ab.swift")])

        browser.copyName(nil)
        #expect(environment.services.clipboard.pasteboard.string(forType: .string) == "a.swift\nab.swift")
        browser.copyRelativePath(nil)
        await browser.commandWork?.value
        #expect(environment.services.clipboard.pasteboard.string(forType: .string) == "src/a.swift\nsrc/ab.swift")
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["repo/", "repo/.git/", "repo/.git/HEAD", "repo/src/", "repo/src/a.swift", "repo/src/ab.swift"])
    }

    @Test func withNothingSelectedTheFolderIsCopied() async throws {
        let tree = try TestTree("repo/", "repo/.git/", "repo/.git/HEAD", "repo/src/", "repo/src/a")
        let environment = try IndependentEnvironment()
        let browser = await browser(at: tree.url("repo/src"), environment)
        browser.select([])

        browser.copyRelativePath(nil)
        await browser.commandWork?.value
        #expect(environment.services.clipboard.pasteboard.string(forType: .string) == "src")
        browser.copyName(nil)
        #expect(environment.services.clipboard.pasteboard.string(forType: .string) == "src")
        withExtendedLifetime((tree, environment)) {}
    }

    @Test func aLaterCopyWinsOverAPendingRelativePath() async throws {
        // The relative path ("f/a") differs from the name ("a"), so a late relative write would show.
        let tree = try TestTree("repo/", "repo/.git/", "repo/.git/HEAD", "repo/f/", "repo/f/a")
        let environment = try IndependentEnvironment()
        let browser = await browser(at: tree.url("repo/f"), environment)
        browser.select([tree.url("repo/f/a")])

        browser.copyRelativePath(nil)
        let pending = browser.commandWork
        browser.copyName(nil)
        await pending?.value
        #expect(environment.services.clipboard.pasteboard.string(forType: .string) == "a")
        withExtendedLifetime((tree, environment)) {}
    }
}
