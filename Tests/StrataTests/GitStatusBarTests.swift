import AppKit
import Testing
@testable import Strata
@testable import StrataDev

/// In a repository the status bar says where the branch is and what's changed, from the status already read.
@Suite struct GitStatusBarTests {
    @Test func theSummaryNamesTheBranchItsDistanceAndTheChanges() async throws {
        let repo = try await GitFixture(["a": "1\n", "b": "1\n"])
        try repo.write("a", "2\n")
        try repo.write("b", "2\n")
        try await repo.git("add", "b")
        try repo.write("new", "n\n")
        let snapshot = await GitStatusLoader.load(repo.repository, mode: .matching, timeout: 30)
        #expect(snapshot.statusBarText == "main · 1 staged · 2 modified · 1 untracked")

        try await repo.git("checkout", "-q", "--", "a")
        try await repo.git("commit", "-q", "-m", "b")
        try FileManager.default.removeItem(at: repo.url("new"))
        let clean = await GitStatusLoader.load(repo.repository, mode: .matching, timeout: 30)
        #expect(clean.statusBarText == "main · No changes")
    }

    @Test func aheadAndBehindTheUpstreamShowAsArrows() {
        var branch = GitBranchInfo()
        branch.head = "topic"
        branch.upstream = "origin/topic"
        branch.ahead = 2
        branch.behind = 1
        #expect(GitStatusSnapshot.statusBarText(branch: branch, operation: nil, counts: GitStatusCounts()) == "topic ↑2 ↓1 · No changes")
        #expect(GitStatusSnapshot.statusBarText(branch: branch, operation: .merging, counts: GitStatusCounts())
                == "topic ↑2 ↓1 · Merging · No changes")
    }

    @Test func thePaneShowsItInARepositoryAndNotElsewhere() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        try repo.write("a", "2\n")
        let plain = try TestTree("x")
        let environment = try IndependentEnvironment()
        environment.services.git.isEnabled = true
        let browser = BrowserViewController(services: environment.services)
        _ = browser.view
        defer { browser.stopBackgroundWork() }
        browser.load(repo.root)
        await browser.directoryReads.task?.value
        for _ in 0..<500 where !browser.statusText.contains("main") { try await Task.sleep(for: .milliseconds(10)) }
        #expect(browser.statusText.contains("main · 1 modified"))

        browser.load(plain.root)
        await browser.directoryReads.task?.value
        #expect(!browser.statusText.contains("main"))
        withExtendedLifetime((environment, plain)) {}
    }
}
