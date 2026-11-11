import Foundation
import Testing
@testable import Strata
@testable import StrataDev

/// Fetch, pull and push against a bare repository on this Mac: no test reaches the network.
@Suite struct GitRemoteTests {
    /// A bare remote with one commit, and a clone of it tracking `main`.
    private func remoteAndClone() async throws -> (remote: GitFixture, clone: GitFixture) {
        let seed = try await GitFixture(["a": "1\n"])
        let remote = try await GitFixture([:], commit: false)
        try await remote.git("config", "core.bare", "true")
        try await seed.git("remote", "add", "origin", remote.url(".git").path)
        try await seed.git(["-c", "protocol.file.allow=always", "push", "-q", "origin", "main"])
        let clone = try await GitFixture([:], commit: false)
        try await clone.git("remote", "add", "origin", remote.url(".git").path)
        try await clone.git(["-c", "protocol.file.allow=always", "fetch", "-q", "origin"])
        try await clone.git("switch", "-q", "-c", "main", "--track", "origin/main")
        withExtendedLifetime(seed) {}
        return (remote, clone)
    }

    /// Another clone's commit on the remote.
    private func commitElsewhere(_ remote: GitFixture, _ text: String) async throws {
        let other = try await GitFixture([:], commit: false)
        try await other.git("remote", "add", "origin", remote.url(".git").path)
        try await other.git(["-c", "protocol.file.allow=always", "fetch", "-q", "origin"])
        try await other.git("switch", "-q", "-c", "main", "--track", "origin/main")
        try other.write("a", text)
        try await other.git("commit", "-q", "-am", "elsewhere")
        try await other.git(["-c", "protocol.file.allow=always", "push", "-q", "origin", "main"])
    }

    private func workbench(_ repo: GitFixture, _ environment: IndependentEnvironment) async -> GitWorkbench {
        await environment.services.gitWriter.trust.trust(repo.repository)
        return GitWorkbench(repository: repo.repository, writer: environment.services.gitWriter)
    }

    private func rev(_ repo: GitFixture, _ name: String) async throws -> String {
        try await repo.git("rev-parse", name).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func fetchUpdatesTheRemoteBranchAndNothingElse() async throws {
        let (remote, clone) = try await remoteAndClone()
        try await commitElsewhere(remote, "2\n")
        let environment = try IndependentEnvironment()
        let bench = await workbench(clone, environment)
        let head = try await rev(clone, "HEAD")

        #expect(await bench.fetch(all: false) == .done)
        #expect(try await rev(clone, "origin/main") != head)
        #expect(try await rev(clone, "HEAD") == head)
        #expect(clone.text("a") == "1\n")
        withExtendedLifetime(environment) {}
    }

    @Test func pullFastForwardsAndRefusesToMergeDivergedWork() async throws {
        let (remote, clone) = try await remoteAndClone()
        try await commitElsewhere(remote, "2\n")
        let environment = try IndependentEnvironment()
        let bench = await workbench(clone, environment)

        #expect(await bench.pull(rebase: false) == .done)
        #expect(clone.text("a") == "2\n")

        try await commitElsewhere(remote, "3\n")
        try clone.write("b", "mine\n")
        try await clone.git("add", "b")
        try await clone.git("commit", "-q", "-m", "mine")
        let mine = try await rev(clone, "HEAD")
        guard case .failed = await bench.pull(rebase: false) else { Issue.record("merged diverged work"); return }
        #expect(try await rev(clone, "HEAD") == mine)
        #expect(clone.text("a") == "2\n")

        #expect(await bench.pull(rebase: true) == .done)
        #expect(clone.text("a") == "3\n" && clone.text("b") == "mine\n")
        #expect(try await clone.git("log", "--format=%s", "-3") == "mine\nelsewhere\nelsewhere\n")
        withExtendedLifetime(environment) {}
    }

    @Test func pushSendsCommitsAndNeverForcesUnlessAsked() async throws {
        let (remote, clone) = try await remoteAndClone()
        let environment = try IndependentEnvironment()
        let bench = await workbench(clone, environment)
        try clone.write("a", "mine\n")
        try await clone.git("commit", "-q", "-am", "mine")

        #expect(await bench.push(force: false) == .done)
        #expect(try await rev(remote, "main") == (try await rev(clone, "HEAD")))

        // Someone else pushed; a plain push is refused and the remote keeps their work.
        try await commitElsewhere(remote, "theirs\n")
        let theirs = try await rev(remote, "main")
        try await clone.git("commit", "-q", "--amend", "-m", "mine, again")
        guard case .failed = await bench.push(force: false) else { Issue.record("pushed over someone’s work"); return }
        #expect(try await rev(remote, "main") == theirs)
        // With a lease on what was last fetched, it's still refused: their commit was never seen here.
        guard case .failed = await bench.push(force: true) else { Issue.record("forced over unseen work"); return }
        #expect(try await rev(remote, "main") == theirs)
        withExtendedLifetime(environment) {}
    }

    @Test func pushingANewBranchSetsItsUpstream() async throws {
        let (remote, clone) = try await remoteAndClone()
        try await clone.git("switch", "-q", "-c", "topic")
        let environment = try IndependentEnvironment()
        let bench = await workbench(clone, environment)

        #expect(await bench.remotes() == ["origin"])
        #expect(await bench.push(force: false, settingUpstreamOn: "origin") == .done)
        #expect(try await clone.git("rev-parse", "--abbrev-ref", "topic@{upstream}") == "origin/topic\n")
        #expect(try await rev(remote, "topic") == (try await rev(clone, "HEAD")))
        withExtendedLifetime(environment) {}
    }

    @Test func onlyRemoteCommandsMayUseATransport() async throws {
        let (remote, clone) = try await remoteAndClone()
        try await commitElsewhere(remote, "2\n")
        let environment = try IndependentEnvironment()
        let writer = environment.services.gitWriter
        await writer.trust.trust(clone.repository)
        let before = try await rev(clone, "origin/main")

        // The same fetch, run as an ordinary write: no protocol is allowed.
        let result = await writer.run(["fetch", "-q", "origin"], in: clone.repository)
        #expect(result.output?.succeeded == false)
        #expect(try await rev(clone, "origin/main") == before)
        withExtendedLifetime(environment) {}
    }

    @Test func remoteNamesAreNeverOptions() async throws {
        let (_, clone) = try await remoteAndClone()
        let environment = try IndependentEnvironment()
        let bench = await workbench(clone, environment)
        #expect(await bench.push(force: false, settingUpstreamOn: "--mirror") == .invalidName)
        withExtendedLifetime(environment) {}
    }
}
