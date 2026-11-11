import Foundation
import Testing
@testable import Strata
@testable import StrataDev

/// Git commands that change a repository run only where the user trusts it, one at a time, with its own hooks.
@Suite struct GitWriterTests {
    @Test func anUntrustedRepositoryRefusesEveryWriteAndRunsNoHook() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        let marker = try repo.installHook("pre-commit", marker: "ran")
        try repo.write("a", "2\n")
        let environment = try IndependentEnvironment()
        let writer = environment.services.gitWriter
        let before = try await repo.index()

        for arguments in [["add", "--", "a"], ["commit", "-q", "-am", "x"], ["reset", "--hard"]] {
            let result = await writer.run(arguments, in: repo.repository)
            #expect(result.refusal == .untrusted)
        }
        #expect(try await repo.index() == before)
        #expect(repo.text("a") == "2\n")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        withExtendedLifetime(environment) {}
    }

    @Test func aTrustedRepositoryRunsItsOwnHooks() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        let marker = try repo.installHook("pre-commit", marker: "ran")
        try repo.write("a", "2\n")
        let environment = try IndependentEnvironment()
        let writer = environment.services.gitWriter
        #expect(await writer.trust.trust(repo.repository))

        let result = await writer.run(["commit", "-q", "-am", "second"], in: repo.repository)
        #expect(result.output?.succeeded == true, Comment(rawValue: result.output?.errorOutput ?? ""))
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(try await repo.git("log", "--format=%s") == "second\nfirst\n")
        withExtendedLifetime(environment) {}
    }

    @Test func anotherRepositoryAtATrustedPathIsAStranger() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        let environment = try IndependentEnvironment()
        let trust = environment.services.gitWriter.trust
        #expect(await trust.trust(repo.repository))
        #expect(await trust.isTrusted(repo.repository))

        try FileManager.default.moveItem(at: repo.root, to: repo.tree.url("moved"))
        try FileManager.default.createDirectory(at: repo.root, withIntermediateDirectories: false)
        try await repo.git("init", "-q")
        #expect(!(await trust.isTrusted(repo.repository)))
        withExtendedLifetime(environment) {}
    }

    @Test func revokingTrustRefusesAgain() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        let environment = try IndependentEnvironment()
        let writer = environment.services.gitWriter
        await writer.trust.trust(repo.repository)
        writer.trust.revoke(path: repo.repository.rootPath)
        #expect(await writer.run(["add", "-A"], in: repo.repository).refusal == .untrusted)
        #expect(writer.trust.entries.isEmpty)
        withExtendedLifetime(environment) {}
    }

    @Test func trustBelongsToItsEnvironment() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        let first = try IndependentEnvironment()
        let second = try IndependentEnvironment()
        await first.services.gitWriter.trust.trust(repo.repository)
        #expect(await first.services.gitWriter.trust.isTrusted(repo.repository))
        #expect(!(await second.services.gitWriter.trust.isTrusted(repo.repository)))
        withExtendedLifetime((first, second)) {}
    }

    @Test func aSecondCommandWhileOneRunsIsRefused() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        let go = repo.tree.url("go")
        // The hook waits until the test lets it finish, so the first commit is certainly running.
        try "#!/bin/sh\nwhile [ ! -e '\(go.path)' ]; do sleep 0.01; done\n"
            .write(to: repo.url(".git/hooks/pre-commit"), atomically: false, encoding: .utf8)
        chmod(repo.url(".git/hooks/pre-commit").path, 0o755)
        try repo.write("a", "2\n")
        let environment = try IndependentEnvironment()
        let writer = environment.services.gitWriter
        await writer.trust.trust(repo.repository)

        let first = Task { await writer.run(["commit", "-q", "-am", "second"], in: repo.repository) }
        for _ in 0..<1_000 where !writer.isRunning(in: repo.repository) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(writer.isRunning(in: repo.repository))
        #expect(await writer.run(["reset", "--hard", "HEAD"], in: repo.repository).refusal == .busy)
        FileManager.default.createFile(atPath: go.path, contents: nil)
        #expect(await first.value.output?.succeeded == true)
        #expect(!writer.isRunning(in: repo.repository))
        #expect(repo.text("a") == "2\n")
        withExtendedLifetime(environment) {}
    }

    @Test func automationListsHooksFiltersAndTheFileMonitor() async throws {
        let repo = try await GitFixture(["a": "1\n"])
        _ = try repo.installHook("pre-push", marker: "x")
        try "#!/bin/sh\n".write(to: repo.url(".git/hooks/not-executable"), atomically: false, encoding: .utf8)
        try await repo.git("config", "filter.lfs.clean", "git-lfs clean -- %f")
        try await repo.git("config", "filter.lfs.smudge", "git-lfs smudge -- %f")
        try await repo.git("config", "core.fsmonitor", "/bin/echo")

        let automation = await GitAutomation.read(repo.repository)
        // git init writes only .sample hooks, which never run.
        #expect(automation.hooks == ["pre-push"])
        #expect(automation.filters == ["lfs"])
        #expect(automation.fileMonitor == "/bin/echo")
    }

    @Test func automationParsesConfigRecords() {
        let records = "local\0core.hookspath\n.githooks\0global\0filter.a.b.clean\nx\0local\0core.fsmonitor\nfalse\0"
            + "local\0filter.empty.clean\n\0command\0filter.cmd.clean\nx\0command\0core.hookspath\n/dev/null\0"
        let (parsed, hooksPath) = GitAutomation.parse(config: Data(records.utf8))
        #expect(hooksPath == ".githooks")
        #expect(parsed.filters == ["a.b"])
        #expect(parsed.fileMonitor == nil)
        #expect(GitAutomation.parse(config: Data()).parsed.isEmpty)
    }
}

extension Result where Success == GitRunResult, Failure == GitWriter.Refusal {
    var refusal: GitWriter.Refusal? { if case .failure(let refusal) = self { refusal } else { nil } }
    var output: GitRunResult? { try? get() }
}
