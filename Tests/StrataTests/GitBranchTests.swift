import Foundation
import Testing
@testable import Strata
@testable import StrataDev

/// Branches: listed, made, switched to, renamed and deleted, with git's own refusals kept and bad names refused
/// before git runs.
@Suite struct GitBranchTests {
    private func workbench(_ repo: GitFixture, _ environment: IndependentEnvironment) async -> GitWorkbench {
        await environment.services.gitWriter.trust.trust(repo.repository)
        return GitWorkbench(repository: repo.repository, writer: environment.services.gitWriter)
    }

    private func head(_ repo: GitFixture) async throws -> String {
        try await repo.git("rev-parse", "--abbrev-ref", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func branchesAreListedWithTheCurrentOneMarked() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        try await repo.git("branch", "feature")
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)
        let branches = try #require(await bench.branches())
        #expect(branches.map(\.name) == ["feature", "main"])
        #expect(branches.first { $0.name == "main" }?.isCurrent == true)
        #expect(branches.allSatisfy { !$0.isRemote })
        withExtendedLifetime(environment) {}
    }

    @Test func parsingForEachRefRecords() {
        let records = ["refs/heads/main\u{1f}main\u{1f}abc\u{1f}origin/main\u{1f}*",
                       "refs/remotes/origin/x\u{1f}origin/x\u{1f}def\u{1f}\u{1f} ",
                       "refs/remotes/origin/HEAD\u{1f}origin/HEAD\u{1f}def\u{1f}\u{1f} ",
                       "broken"].joined(separator: "\n")
        let branches = GitBranchParser.parse(Data(records.utf8))
        #expect(branches.map(\.name) == ["main", "origin/x"])
        #expect(branches[0].isCurrent && branches[0].upstream == "origin/main")
        #expect(branches[1].isRemote && branches[1].localName == "x")
    }

    @Test func badNamesAreRefusedBeforeGitRuns() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)
        for name in ["-f", "a..b", "with space", "", "end/", "x.lock", "@", "a~1", "--orphan"] {
            #expect(await bench.createBranch(name, checkout: false) == .invalidName, "\(name) was accepted")
        }
        #expect(try await repo.git("branch", "--format=%(refname:short)") == "main\n")
        withExtendedLifetime(environment) {}
    }

    @Test func creatingSwitchingAndRenaming() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)

        #expect(await bench.createBranch("topic", checkout: false) == .done)
        #expect(try await head(repo) == "main")
        #expect(await bench.createBranch("work", checkout: true) == .done)
        #expect(try await head(repo) == "work")
        #expect(await bench.switchBranch("topic") == .done)
        #expect(try await head(repo) == "topic")
        #expect(await bench.renameBranch("topic", to: "renamed") == .done)
        #expect(try await head(repo) == "renamed")
        #expect(try await repo.git("branch", "--format=%(refname:short)") == "main\nrenamed\nwork\n")
        withExtendedLifetime(environment) {}
    }

    @Test func switchingNeverOverwritesLocalChanges() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        try await repo.git("switch", "-q", "-c", "other")
        try repo.write("a", "other\n")
        try await repo.git("commit", "-q", "-am", "other")
        try await repo.git("switch", "-q", "main")
        try repo.write("a", "mine, not committed\n")
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)

        guard case .failed = await bench.switchBranch("other") else { Issue.record("switched over local changes"); return }
        #expect(try await head(repo) == "main")
        #expect(repo.text("a") == "mine, not committed\n")
        withExtendedLifetime(environment) {}
    }

    @Test func deletingKeepsUnmergedWorkUnlessForced() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        try await repo.git("branch", "merged")
        try await repo.git("switch", "-q", "-c", "unmerged")
        try repo.write("a", "2\n")
        try await repo.git("commit", "-q", "-am", "only here")
        let tip = try await repo.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        try await repo.git("switch", "-q", "main")
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)

        #expect(await bench.deleteBranch("merged", force: false) == .done)
        guard case .failed = await bench.deleteBranch("unmerged", force: false) else { Issue.record("deleted unmerged work"); return }
        #expect(try await repo.git("rev-parse", "unmerged").trimmingCharacters(in: .whitespacesAndNewlines) == tip)
        // The current branch is never deleted.
        guard case .failed = await bench.deleteBranch("main", force: true) else { Issue.record("deleted the current branch"); return }
        #expect(await bench.deleteBranch("unmerged", force: true) == .done)
        #expect(try await repo.git("branch", "--format=%(refname:short)") == "main\n")
        // Its commit is still there to restore from.
        #expect(try await repo.git("cat-file", "-t", tip) == "commit\n")
        withExtendedLifetime(environment) {}
    }

    @Test func switchingToARemoteBranchMakesALocalOneTrackingIt() async throws {
        let origin = try await GitFixture(["a": "1\n"])
        try await origin.git("branch", "shared")
        let repo = try await GitFixture([:], commit: false)
        try await repo.git("remote", "add", "origin", origin.root.path)
        try await repo.git(["-c", "protocol.file.allow=always", "fetch", "-q", "origin"])
        try await repo.git("switch", "-q", "-c", "main", "origin/main")
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)

        let remote = try #require(await bench.branches()?.first { $0.name == "origin/shared" })
        #expect(await bench.switchBranch(remote) == .done)
        #expect(try await head(repo) == "shared")
        #expect(try await repo.git("rev-parse", "--abbrev-ref", "shared@{upstream}") == "origin/shared\n")
        withExtendedLifetime((environment, origin)) {}
    }
}
