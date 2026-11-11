import Foundation
import Testing
@testable import Strata
@testable import StrataDev

/// Staging changes only the index, and only for what was chosen. Every test compares the whole index and the working
/// files before and after.
@Suite struct GitStagingTests {
    private func workbench(_ repo: GitFixture, _ environment: IndependentEnvironment, trusted: Bool = true) async -> GitWorkbench {
        if trusted { await environment.services.gitWriter.trust.trust(repo.repository) }
        return GitWorkbench(repository: repo.repository, writer: environment.services.gitWriter)
    }

    @Test func statusSortsChangesIntoSections() async throws {
        let repo = try await GitFixture(["a": "1\n", "b": "1\n", "c": "1\n"])
        try repo.write("a", "2\n")
        try repo.write("b", "2\n")
        try await repo.git("add", "b")
        try repo.write("new/n", "n\n")
        try FileManager.default.removeItem(at: repo.url("c"))
        let environment = try IndependentEnvironment()
        let status = try #require(await workbench(repo, environment).load())

        #expect(status.branch.head == "main")
        #expect(status.untracked == ["new/n"])
        #expect(status.unstaged.map(\.path) == ["a", "c"])
        #expect(status.unstaged.first { $0.path == "c" }?.isDeleted == true)
        #expect(status.staged.map(\.path) == ["b"])
        #expect(status.unstaged[0].hunks[0].lines.map(\.text) == ["1", "2"])
        withExtendedLifetime(environment) {}
    }

    @Test func stagingAFileTakesOnlyThatFile() async throws {
        let repo = try await GitFixture(["a": "1\n", "ab": "1\n", "a.txt": "1\n", "sub/a": "1\n"])
        for path in ["a", "ab", "a.txt", "sub/a"] { try repo.write(path, "2\n") }
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)

        #expect(await bench.stage(["a"]) == .done)
        let staged = try await repo.git("diff", "--cached", "--name-only")
        #expect(staged == "a\n")
        #expect(try await repo.git("diff", "--name-only") == "a.txt\nab\nsub/a\n")
        for path in ["a", "ab", "a.txt", "sub/a"] { #expect(repo.text(path) == "2\n") }
        withExtendedLifetime(environment) {}
    }

    @Test func stagingAFolderTakesEverythingUnderItIncludingNewFiles() async throws {
        let repo = try await GitFixture(["dir/a": "1\n", "dirt/b": "1\n"])
        try repo.write("dir/a", "2\n")
        try repo.write("dir/new", "n\n")
        try repo.write("dirt/b", "2\n")
        try FileManager.default.removeItem(at: repo.url("dir/a"))
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)

        #expect(await bench.stage(["dir"]) == .done)
        #expect(try await repo.git("diff", "--cached", "--name-status") == "D\tdir/a\nA\tdir/new\n")
        #expect(try await repo.git("diff", "--name-only") == "dirt/b\n")
        withExtendedLifetime(environment) {}
    }

    @Test func unstagingPutsTheIndexBackAndKeepsTheWork() async throws {
        let repo = try await GitFixture(["a": "1\n", "b": "1\n"])
        try repo.write("a", "2\n")
        try repo.write("b", "2\n")
        try await repo.git("add", "-A")
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)

        #expect(await bench.unstage(["a"]) == .done)
        #expect(try await repo.git("diff", "--cached", "--name-only") == "b\n")
        #expect(repo.text("a") == "2\n")
        withExtendedLifetime(environment) {}
    }

    @Test func unstagingBeforeTheFirstCommit() async throws {
        let repo = try await GitFixture(["a": "1\n", "b": "1\n"], commit: false)
        try await repo.git("add", "-A")
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)

        #expect(await bench.unstage(["a"]) == .done)
        #expect(try await repo.index().contains("\tb\n"))
        #expect(!(try await repo.index().contains("\ta\n")))
        #expect(repo.text("a") == "1\n")
        withExtendedLifetime(environment) {}
    }

    @Test func stagingAndUnstagingOneHunk() async throws {
        // Far enough apart that git's three lines of context keep them in separate hunks.
        let ten = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let repo = try await GitFixture(["a": ten])
        let changed = ten.replacingOccurrences(of: "line 2\n", with: "LINE 2\n").replacingOccurrences(of: "line 15\n", with: "LINE 15\n")
        try repo.write("a", changed)
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)
        let file = try #require(await bench.load()?.unstaged.first)

        #expect(await bench.stage(file, hunk: 1) == .done)
        #expect(try await repo.git("show", ":a") == ten.replacingOccurrences(of: "line 15\n", with: "LINE 15\n"))
        let staged = try #require(await bench.load()?.staged.first)
        #expect(await bench.unstage(staged, hunk: 0) == .done)
        #expect(try await repo.git("show", ":a") == ten)
        #expect(repo.text("a") == changed)
        withExtendedLifetime(environment) {}
    }

    @Test func aStaleHunkChangesNothing() async throws {
        let repo = try await GitFixture(["a": "1\n2\n3\n"])
        try repo.write("a", "1\nTWO\n3\n")
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)
        let file = try #require(await bench.load()?.unstaged.first)
        // The file changed again after the diff was read; the old hunk no longer fits the index.
        try await repo.git("add", "a")
        let before = try await repo.index()

        guard case .failed = await bench.stage(file, hunk: 0) else { Issue.record("a stale hunk applied"); return }
        #expect(try await repo.index() == before)
        withExtendedLifetime(environment) {}
    }

    @Test func untrustedRepositoriesRefuseBeforeAnythingChanges() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        try repo.write("a", "2\n")
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment, trusted: false)
        let before = try await repo.index()

        #expect(await bench.stage(["a"]) == .refused(.untrusted))
        #expect(await bench.commit(message: "x", amend: false) == .refused(.untrusted))
        #expect(try await repo.index() == before)
        // Reading status needs no trust.
        #expect(await bench.load()?.unstaged.map(\.path) == ["a"])
        withExtendedLifetime(environment) {}
    }

    @Test func committingAndAmending() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        try repo.write("a", "2\n")
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)
        _ = await bench.stage(["a"])

        #expect(await bench.commit(message: "Second\n\nBody line.\n# not a comment once stripped? yes it is", amend: false) == .done)
        #expect(try await repo.git("log", "-1", "--format=%B") == "Second\n\nBody line.\n\n")
        #expect(await bench.commit(message: "Second, reworded", amend: true) == .done)
        #expect(try await repo.git("log", "--format=%s") == "Second, reworded\nfirst\n")
        withExtendedLifetime(environment) {}
    }

    @Test func anEmptyMessageOrNothingStagedIsRefusedUpFront() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)
        #expect(await bench.commit(message: "  \n# only a comment\n", amend: false) == .emptyMessage)
        #expect(await bench.commit(message: "x", amend: false) == .nothingStaged)
        #expect(try await repo.git("log", "--format=%s") == "first\n")
        withExtendedLifetime(environment) {}
    }

    @Test func pathsAreLiteralNeverPatterns() async throws {
        let repo = try await GitFixture(["*": "1\n", "a": "1\n", ":(glob)b": "1\n"])
        for path in ["*", "a", ":(glob)b"] { try repo.write(path, "2\n") }
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)

        #expect(await bench.stage(["*"]) == .done)
        #expect(try await repo.git("diff", "--cached", "--name-only") == "*\n")
        #expect(await bench.stage([":(glob)b"]) == .done)
        #expect(try await repo.git("diff", "--cached", "--name-only") == "*\n:(glob)b\n")
        withExtendedLifetime(environment) {}
    }

    @Test func theCommandsGitIsGiven() {
        #expect(GitCommands.stage(["a b", "-x"]) == ["add", "-A", "--", ":(literal)a b", ":(literal)-x"])
        #expect(GitCommands.unstage(["a"], hasHead: true) == ["restore", "--staged", "--", ":(literal)a"])
        #expect(GitCommands.unstage(["a"], hasHead: false) == ["rm", "--cached", "-r", "-q", "--", ":(literal)a"])
        #expect(GitCommands.applyToIndex(patch: "/p", reverse: true) == ["apply", "--cached", "--whitespace=nowarn", "--reverse", "/p"])
        #expect(GitCommands.commit(messageFile: "/m", amend: true) == ["commit", "--cleanup=strip", "-F", "/m", "--amend"])
        #expect(GitCommands.isEmptyMessage(" \n# x\n\t\n"))
        #expect(!GitCommands.isEmptyMessage("# x\nfix"))
    }
}
