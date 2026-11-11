import Foundation
import Testing
@testable import Strata
@testable import StrataDev

/// Commands that rewrite working files: discard, reset and stash. Each changes only what was chosen, is refused up
/// front when it can't be done safely, and comes with an Undo that restores exactly what it changed, never over
/// something that took its place.
@Suite struct GitDiscardTests {
    private func workbench(_ repo: GitFixture, _ environment: IndependentEnvironment) async -> GitWorkbench {
        await environment.services.gitWriter.trust.trust(repo.repository)
        return GitWorkbench(repository: repo.repository, writer: environment.services.gitWriter)
    }

    private func status(_ repo: GitFixture) async throws -> String { try await repo.git("status", "--porcelain") }

    // MARK: Discard

    @Test func discardTakesOnlyTheChosenFileBackToItsStagedVersion() async throws {
        let repo = try await GitFixture(["a": "1\n", "ab": "1\n", "a.txt": "1\n", "sub/a": "1\n"])
        try repo.write("a", "staged\n")
        try await repo.git("add", "a")
        for path in ["a", "ab", "a.txt", "sub/a"] { try repo.write(path, "work\n") }
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)
        let index = try await repo.index()

        let (outcome, undo) = await bench.discard(["a"])
        #expect(outcome == .done)
        #expect(undo != nil)
        #expect(repo.text("a") == "staged\n")
        for path in ["ab", "a.txt", "sub/a"] { #expect(repo.text(path) == "work\n") }
        #expect(try await repo.index() == index)
        withExtendedLifetime(environment) {}
    }

    @Test func undoingADiscardBringsBackTheExactBytes() async throws {
        let repo = try await GitFixture(["a": "1\n", "run.sh": "#!/bin/sh\n"])
        chmod(repo.url("run.sh").path, 0o755)
        try await repo.git("commit", "-q", "-am", "executable")
        try repo.write("a", "work \u{0}\u{ff} bytes\n")
        try repo.write("run.sh", "#!/bin/sh\necho changed\n")
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)
        let before = try Data(contentsOf: repo.url("a"))

        let (outcome, undo) = await bench.discard(["a", "run.sh"])
        #expect(outcome == .done)
        #expect(repo.text("a") == "1\n")
        #expect(await bench.undo(try #require(undo)) == .done)
        #expect(try Data(contentsOf: repo.url("a")) == before)
        #expect(repo.text("run.sh") == "#!/bin/sh\necho changed\n")
        #expect(access(repo.url("run.sh").path, X_OK) == 0)
        withExtendedLifetime(environment) {}
    }

    @Test func undoNeverReplacesAFileChangedSinceTheDiscard() async throws {
        let repo = try await GitFixture(["a": "1\n", "b": "1\n"])
        try repo.write("a", "work a\n")
        try repo.write("b", "work b\n")
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)
        let (_, undo) = await bench.discard(["a", "b"])
        try repo.write("b", "written since\n")

        guard case .failed = await bench.undo(try #require(undo)) else { Issue.record("undo replaced a newer file"); return }
        // Refused as a whole: neither file changes.
        #expect(repo.text("a") == "1\n")
        #expect(repo.text("b") == "written since\n")
        withExtendedLifetime(environment) {}
    }

    @Test func aDeletedFileComesBackAndItsUndoDeletesItAgain() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        try FileManager.default.removeItem(at: repo.url("a"))
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)

        let (_, undo) = await bench.discard(["a"])
        #expect(repo.text("a") == "1\n")
        #expect(await bench.undo(try #require(undo)) == .done)
        #expect(!FileManager.default.fileExists(atPath: repo.url("a").path))
        withExtendedLifetime(environment) {}
    }

    @Test func discardingOneHunkKeepsTheOther() async throws {
        let body = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let repo = try await GitFixture(["a": body])
        let changed = body.replacingOccurrences(of: "line 2\n", with: "LINE 2\n").replacingOccurrences(of: "line 15\n", with: "LINE 15\n")
        try repo.write("a", changed)
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)
        let file = try #require(await bench.load()?.unstaged.first)

        let (outcome, undo) = await bench.discard(file, hunk: 0)
        #expect(outcome == .done)
        #expect(repo.text("a") == body.replacingOccurrences(of: "line 15\n", with: "LINE 15\n"))
        #expect(await bench.undo(try #require(undo)) == .done)
        #expect(repo.text("a") == changed)
        withExtendedLifetime(environment) {}
    }

    @Test func discardIsRefusedUpFrontForWhatItCantSafelyTouch() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        try repo.write("a", "work\n")
        try repo.write("new", "untracked\n")
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)
        for paths in [["../outside"], ["/etc/hosts"], [".git/config"], ["sub/../../x"], [], ["new"], ["a", "new"]] {
            let (outcome, undo) = await bench.discard(paths)
            // Strata's own refusal answers, before git is asked anything.
            #expect(outcome == .failed(GitDiscard.refusal(paths, unstaged: ["a"]) ?? ""), "\(paths)")
            #expect(undo == nil)
        }
        #expect(repo.text("a") == "work\n" && repo.text("new") == "untracked\n")
        withExtendedLifetime(environment) {}
    }

    @Test func undoNeverWritesThroughAFolderReplacedByALink() async throws {
        let repo = try await GitFixture(["sub/a": "1\n"])
        try repo.write("sub/a", "work\n")
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)
        let (_, undo) = await bench.discard(["sub/a"])
        // The folder is swapped for a link to a look-alike outside the repository, holding what the discard left.
        let outside = repo.tree.url("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try "1\n".write(to: outside.appending(path: "a"), atomically: false, encoding: .utf8)
        try FileManager.default.moveItem(at: repo.url("sub"), to: repo.tree.url("parked"))
        try FileManager.default.createSymbolicLink(at: repo.url("sub"), withDestinationURL: outside)

        guard case .failed = await bench.undo(try #require(undo)) else { Issue.record("undo wrote through a link"); return }
        #expect(try String(contentsOf: outside.appending(path: "a"), encoding: .utf8) == "1\n")
        withExtendedLifetime(environment) {}
    }

    @Test func undoRecordsKeepTheirObjectsFromGarbageCollection() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        try repo.write("a", "precious\n")
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)
        let (_, undo) = await bench.discard(["a"])
        try await repo.git("gc", "-q", "--prune=now")
        #expect(try await repo.git("for-each-ref", "--format=%(refname)", "refs/strata/").contains("refs/strata/undo/"))
        #expect(await bench.undo(try #require(undo)) == .done)
        #expect(repo.text("a") == "precious\n")
        // Undone, its refs go.
        #expect(try await repo.git("for-each-ref", "refs/strata/") == "")
        withExtendedLifetime(environment) {}
    }

    // MARK: Reset

    private func threeCommits() async throws -> (GitFixture, [String]) {
        let repo = try await GitFixture(["a": "1\n"])
        for text in ["2\n", "3\n"] {
            try repo.write("a", text)
            try await repo.git("commit", "-q", "-am", text)
        }
        let ids = try await repo.git("log", "--format=%H").split(separator: "\n").map(String.init)
        return (repo, ids)
    }

    @Test func eachResetAndItsUndo() async throws {
        for mode in [GitResetMode.soft, .mixed, .hard] {
            let (repo, ids) = try await threeCommits()
            try repo.write("a", "uncommitted\n")
            try repo.write("b", "new\n")
            try await repo.git("add", "b")
            let environment = try IndependentEnvironment()
            let bench = await workbench(repo, environment)
            let before = try await status(repo)

            let (outcome, undo) = await bench.reset(to: ids[2], mode: mode)
            #expect(outcome == .done, "\(mode)")
            #expect(try await repo.git("rev-parse", "HEAD") == ids[2] + "\n")
            if mode == .hard { #expect(repo.text("a") == "1\n") } else { #expect(repo.text("a") == "uncommitted\n") }

            #expect(await bench.undo(try #require(undo)) == .done, "\(mode)")
            #expect(try await repo.git("rev-parse", "HEAD") == ids[0] + "\n")
            #expect(repo.text("a") == "uncommitted\n" && repo.text("b") == "new\n")
            #expect(try await status(repo) == before, "\(mode)")
            withExtendedLifetime(environment) {}
        }
    }

    @Test func undoingAResetIsRefusedOnceHistoryMovedOn() async throws {
        let (repo, ids) = try await threeCommits()
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)
        let (_, undo) = await bench.reset(to: ids[1], mode: .hard)
        try repo.write("a", "later\n")
        try await repo.git("commit", "-q", "-am", "later")
        let later = try await repo.git("rev-parse", "HEAD")

        guard case .failed = await bench.undo(try #require(undo)) else { Issue.record("undo dropped a later commit"); return }
        #expect(try await repo.git("rev-parse", "HEAD") == later)
        withExtendedLifetime(environment) {}
    }

    @Test func aHardResetUndoKeepsChangesMadeSince() async throws {
        let (repo, ids) = try await threeCommits()
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)
        let (_, undo) = await bench.reset(to: ids[1], mode: .hard)
        try repo.write("a", "edited after the reset\n")

        guard case .failed = await bench.undo(try #require(undo)) else { Issue.record("undo overwrote new work"); return }
        #expect(repo.text("a") == "edited after the reset\n")
        withExtendedLifetime(environment) {}
    }

    @Test func resetTargetsAreCommitsNeverOptions() async throws {
        let (repo, _) = try await threeCommits()
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)
        let head = try await repo.git("rev-parse", "HEAD")
        for target in ["--hard", "nope", ""] {
            guard case .failed = await bench.reset(to: target, mode: .hard).0 else { Issue.record("\(target) accepted"); continue }
        }
        #expect(try await repo.git("rev-parse", "HEAD") == head)
        withExtendedLifetime(environment) {}
    }

    // MARK: Stash

    @Test func stashingAndBringingItBack() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        try repo.write("a", "work\n")
        try repo.write("new", "untracked\n")
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)

        let (pushed, undo) = await bench.stashPush(includeUntracked: true, message: "wip")
        #expect(pushed == .done)
        #expect(repo.text("a") == "1\n" && repo.text("new") == nil)
        #expect(await bench.stashes().map(\.message).first?.hasSuffix("wip") == true)
        // Undoing the stash puts the work back and removes the stash.
        #expect(await bench.undo(try #require(undo)) == .done)
        #expect(repo.text("a") == "work\n" && repo.text("new") == "untracked\n")
        #expect(await bench.stashes().isEmpty)

        _ = await bench.stashPush(includeUntracked: false, message: nil)
        #expect(await bench.stashApply(0, pop: false) == .done)
        #expect(repo.text("a") == "work\n")
        #expect(await bench.stashes().count == 1)
        try await repo.git("checkout", "-q", "--", "a")
        #expect(await bench.stashApply(0, pop: true) == .done)
        #expect(repo.text("a") == "work\n")
        #expect(await bench.stashes().isEmpty)
        withExtendedLifetime(environment) {}
    }

    @Test func droppingAStashCanBeUndone() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        try repo.write("a", "first\n")
        try await repo.git("stash", "push", "-q", "-m", "one")
        try repo.write("a", "second\n")
        try await repo.git("stash", "push", "-q", "-m", "two")
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)
        let stashes = await bench.stashes()
        #expect(stashes.map(\.message).map { $0.hasSuffix("two") } == [true, false])

        let (dropped, undo) = await bench.stashDrop(1)
        #expect(dropped == .done)
        #expect(await bench.stashes().count == 1)
        #expect(await bench.undo(try #require(undo)) == .done)
        let restored = await bench.stashes()
        #expect(restored.count == 2)
        #expect(restored.contains { $0.commit == stashes[1].commit })
        // A stash index past the end changes nothing.
        guard case .failed = await bench.stashDrop(9).0 else { Issue.record("dropped a stash that isn't there"); return }
        #expect(await bench.stashes().count == 2)
        withExtendedLifetime(environment) {}
    }

    @Test func undoOfAStashIsRefusedWhenItsNoLongerOnTop() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        try repo.write("a", "work\n")
        let environment = try IndependentEnvironment()
        let bench = await workbench(repo, environment)
        let (_, undo) = await bench.stashPush(includeUntracked: false, message: "mine")
        try repo.write("a", "other\n")
        try await repo.git("stash", "push", "-q", "-m", "newer")

        guard case .failed = await bench.undo(try #require(undo)) else { Issue.record("undid the wrong stash"); return }
        #expect(await bench.stashes().count == 2)
        #expect(repo.text("a") == "1\n")
        withExtendedLifetime(environment) {}
    }
}
