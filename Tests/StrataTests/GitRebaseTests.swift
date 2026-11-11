import Foundation
import Testing
@testable import Strata
@testable import StrataDev

/// Interactive rebase from a todo list Strata writes: no editor opens, a stop can continue, skip or abort, and a
/// finished rebase can be undone while the branch hasn't moved.
@Suite struct GitRebaseTests {
    /// Commits "one" to "four" over "first", each adding its own file.
    private func history() async throws -> (GitFixture, [GitCommit]) {
        let repo = try await GitFixture(["base": "0\n"])
        for name in ["one", "two", "three", "four"] {
            try repo.write(name, name + "\n")
            try await repo.git("add", name)
            try await repo.git("commit", "-q", "-m", name)
        }
        let output = try await repo.git(["log", GitLogParser.format, "-4"])
        return (repo, GitLogParser.parse(Data(output.utf8)).reversed())
    }

    private func workbench(_ repo: GitFixture, _ environment: IndependentEnvironment) async -> GitWorkbench {
        await environment.services.gitWriter.trust.trust(repo.repository)
        return GitWorkbench(repository: repo.repository, writer: environment.services.gitWriter)
    }

    private func subjects(_ repo: GitFixture) async throws -> String { try await repo.git("log", "--format=%s") }

    @Test func theTodoGitReads() {
        let commits = (1...3).map { GitCommit(id: String(repeating: "\($0)", count: 40), parents: [], author: "", email: "", date: .now, refs: [], subject: "s\($0)") }
        var todo = GitRebaseTodo(commits)
        todo.steps[1].action = .squash
        todo.steps[2].action = .reword("New\nmessage")
        let messages = ["/m2"]
        #expect(todo.text(messageFiles: messages) == """
            pick \(commits[0].id) s1
            squash \(commits[1].id) s2
            pick \(commits[2].id) s3
            exec git commit --amend --quiet --no-edit --allow-empty --cleanup=strip -F '/m2'

            """)
        #expect(todo.problem == nil)
        todo.steps[0].action = .fixup
        #expect(todo.problem != nil)
        todo.steps[0].action = .drop
        todo.steps[1].action = .drop
        todo.steps[2].action = .drop
        #expect(todo.problem != nil)
        todo.move(from: 2, to: 0)
        #expect(todo.steps.map(\.commit.subject) == ["s3", "s1", "s2"])
    }

    @Test func reorderingDroppingSquashingAndRewording() async throws {
        let (repo, commits) = try await history()
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)
        var todo = GitRebaseTodo(commits)
        todo.move(from: 3, to: 0)                    // four first
        todo.steps[2].action = .drop                 // two
        todo.steps[3].action = .squash               // three into one
        todo.steps[0].action = .reword("Four, reworded")

        let (outcome, undo) = await bench.rebase(todo, onto: commits[0].parents.first)
        #expect(outcome == .done)
        // Newest first: "three" squashed into "one" keeps one's subject.
        #expect(try await subjects(repo) == "one\nFour, reworded\nfirst\n")
        #expect(repo.text("two") == nil && repo.text("three") == "three\n" && repo.text("four") == "four\n")
        #expect(try await repo.git("rev-list", "--count", "HEAD") == "3\n")
        #expect(undo != nil)
        withExtendedLifetime(environment) {}
    }

    @Test func fixupKeepsTheFirstMessage() async throws {
        let (repo, commits) = try await history()
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)
        var todo = GitRebaseTodo(Array(commits.suffix(2)))
        todo.steps[1].action = .fixup
        _ = await bench.rebase(todo, onto: commits[1].id)
        #expect(try await subjects(repo) == "three\ntwo\none\nfirst\n")
        #expect(repo.text("four") == "four\n")
        withExtendedLifetime(environment) {}
    }

    @Test func undoingAFinishedRebase() async throws {
        let (repo, commits) = try await history()
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)
        let before = try await repo.git("rev-parse", "HEAD")
        var todo = GitRebaseTodo(commits)
        todo.steps[1].action = .drop
        let (_, undo) = await bench.rebase(todo, onto: commits[0].parents.first)

        #expect(await bench.undo(try #require(undo)) == .done)
        #expect(try await repo.git("rev-parse", "HEAD") == before)
        #expect(repo.text("two") == "two\n")
        withExtendedLifetime(environment) {}
    }

    @Test func anUndoIsRefusedOnceTheBranchMoved() async throws {
        let (repo, commits) = try await history()
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)
        var todo = GitRebaseTodo(commits)
        todo.steps[1].action = .drop
        let (_, undo) = await bench.rebase(todo, onto: commits[0].parents.first)
        try repo.write("later", "x\n")
        try await repo.git("add", "later")
        try await repo.git("commit", "-q", "-m", "later")
        let head = try await repo.git("rev-parse", "HEAD")

        guard case .failed = await bench.undo(try #require(undo)) else { Issue.record("undo dropped a later commit"); return }
        #expect(try await repo.git("rev-parse", "HEAD") == head)
        withExtendedLifetime(environment) {}
    }

    @Test func editStopsAndContinueFinishes() async throws {
        let (repo, commits) = try await history()
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)
        var todo = GitRebaseTodo(commits)
        todo.steps[1].action = .edit

        let (outcome, undo) = await bench.rebase(todo, onto: commits[0].parents.first)
        #expect(outcome == .stopped)
        #expect(undo == nil)
        #expect(await bench.load()?.operation != nil)
        try repo.write("two", "two, edited\n")
        _ = await bench.stage(["two"])
        _ = await bench.extend()
        #expect(await bench.rebaseContinue() == .done)
        #expect(await bench.load()?.operation == nil)
        #expect(repo.text("two") == "two, edited\n")
        #expect(try await subjects(repo) == "four\nthree\ntwo\none\nfirst\n")
        withExtendedLifetime(environment) {}
    }

    @Test func aConflictStopsAndAbortPutsEverythingBack() async throws {
        let repo = try await GitFixture(["a": "0\n"])
        for text in ["1\n", "2\n"] {
            try repo.write("a", text)
            try await repo.git("commit", "-q", "-am", text)
        }
        let output = try await repo.git(["log", GitLogParser.format, "-2"])
        let commits = Array(GitLogParser.parse(Data(output.utf8)).reversed())
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)
        let before = try await repo.git("rev-parse", "HEAD")
        var todo = GitRebaseTodo(commits)
        todo.move(from: 1, to: 0)

        let (outcome, _) = await bench.rebase(todo, onto: commits[0].parents.first)
        #expect(outcome == .stopped)
        #expect(await bench.load()?.conflicted == ["a"])
        #expect(await bench.rebaseAbort() == .done)
        #expect(try await repo.git("rev-parse", "HEAD") == before)
        #expect(repo.text("a") == "2\n")
        #expect(try await repo.git("status", "--porcelain") == "")
        withExtendedLifetime(environment) {}
    }

    @Test func aPlanThatLeavesACommitOutIsRefused() async throws {
        let (repo, commits) = try await history()
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)
        let head = try await repo.git("rev-parse", "HEAD")
        // "one" is after the base but missing from the plan: git would drop it without a word.
        guard case .failed = await bench.rebase(GitRebaseTodo(Array(commits.dropFirst())), onto: commits[0].parents.first).0 else {
            Issue.record("ran a plan missing a commit"); return
        }
        #expect(try await repo.git("rev-parse", "HEAD") == head)
        #expect(repo.text("one") == "one\n")
        withExtendedLifetime(environment) {}
    }

    @Test func untrustedOrInvalidPlansChangeNothing() async throws {
        let (repo, commits) = try await history()
        let environment = try IndependentEnvironment()
        let bench = GitWorkbench(repository: repo.repository, writer: environment.services.gitWriter)
        let head = try await repo.git("rev-parse", "HEAD")
        #expect(await bench.rebase(GitRebaseTodo(commits), onto: commits[0].parents.first).0 == .refused(.untrusted))
        await environment.services.gitWriter.trust.trust(repo.repository)
        var todo = GitRebaseTodo(commits)
        todo.steps[0].action = .squash
        guard case .failed = await bench.rebase(todo, onto: commits[0].parents.first).0 else { Issue.record("ran an invalid plan"); return }
        #expect(await bench.rebase(GitRebaseTodo(commits), onto: "--exec=touch x").0 != .done)
        #expect(try await repo.git("rev-parse", "HEAD") == head)
        #expect(!FileManager.default.fileExists(atPath: repo.url("x").path))
        withExtendedLifetime(environment) {}
    }
}
