import AppKit
import Testing
@testable import Strata
@testable import StrataDev

/// What the git status view costs on a large repository, against the git commands it runs (the floor). Off unless
/// STRATA_BENCHMARK is set; `scripts/benchmark-git.sh` runs it and prints the timings.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["STRATA_BENCHMARK"] != nil))
struct GitBenchmarks {
    /// 3,000 files in 30 folders; 300 changed in three places each; 100 new.
    private func largeRepository() async throws -> GitFixture {
        let body = (1...60).map { "line \($0)" }.joined(separator: "\n") + "\n"
        var files: [String: String] = [:]
        for index in 0..<3_000 { files["dir-\(index % 30)/file-\(index).txt"] = body }
        let repo = try await GitFixture(files)
        for index in stride(from: 0, to: 3_000, by: 10) {
            let changed = body.replacingOccurrences(of: "line 5\n", with: "LINE 5\n")
                .replacingOccurrences(of: "line 30\n", with: "LINE 30\n").replacingOccurrences(of: "line 55\n", with: "LINE 55\n")
            try repo.write("dir-\(index % 30)/file-\(index).txt", changed)
        }
        for index in 0..<100 { try repo.write("new/n-\(index).txt", "n\n") }
        return repo
    }

    private func time(_ runs: Int = 10, _ body: () async -> Void) async -> [Duration] {
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for _ in 0..<runs {
            let start = clock.now
            await body()
            samples.append(clock.now - start)
        }
        return samples
    }

    @Test func statusOfALargeRepository() async throws {
        let repo = try await largeRepository()
        let environment = try IndependentEnvironment()
        await environment.services.gitWriter.trust.trust(repo.repository)
        let bench = GitWorkbench(repository: repo.repository, writer: environment.services.gitWriter)
        let root = repo.root

        PaneBenchmarks.report("git.floor.commands", await time {
            async let status = GitRunner.run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"], in: root, timeout: 60)
            async let unstaged = GitRunner.run(GitCommands.diff, in: root, timeout: 60)
            async let staged = GitRunner.run(GitCommands.diff + ["--cached"], in: root, timeout: 60)
            _ = await (status, unstaged, staged)
        })
        PaneBenchmarks.report("git.workbench.load", await time { _ = await bench.load() })

        let diff = await GitRunner.run(GitCommands.diff, in: root, timeout: 60).output
        PaneBenchmarks.report("git.parse.diff", await time { _ = GitDiffParser.parse(diff) })

        let status = try #require(await bench.load())
        let all = Set(status.unstaged.map { GitStatusOutline.FileKey(section: .unstaged, path: $0.path) })
        PaneBenchmarks.report("git.rows.collapsed", await time { _ = GitStatusOutline.rows(status, expanded: []) })
        PaneBenchmarks.report("git.rows.expanded", await time { _ = GitStatusOutline.rows(status, expanded: all) })
        withExtendedLifetime(environment) {}
    }

    @Test func theStatusViewOnTheMainThread() async throws {
        let repo = try await largeRepository()
        let elsewhere = try TestTree("x")
        let environment = try IndependentEnvironment()
        let owner = BrowserWindowController(location: repo.root, secondPane: elsewhere.root, services: environment.services)
        owner.window?.setFrameAutosaveName("")
        owner.split.splitView.autosaveName = nil
        defer {
            owner.window?.contentViewController = nil
            owner.panes.forEach { $0.stopBackgroundWork() }
        }
        let browser = owner.panes[0].browser
        await browser.directoryReads.task?.value
        browser.toggleGitStatus(nil)
        await browser.gitStatusLookup?.value
        let status = try #require(browser.gitStatus)
        _ = status.view
        await status.loadTask?.value

        // Opening and closing every file's changes: all on the main thread, what the user waits for after Shift-Tab.
        PaneBenchmarks.report("git.view.expandAll", await time(6) {
            _ = status.handleKey("\u{19}")
            status.table.layoutSubtreeIfNeeded()
        })
        PaneBenchmarks.report("git.view.reload", await time(6) {
            status.reload()
            await status.loadTask?.value
        })
        withExtendedLifetime((environment, elsewhere)) {}
    }
}
