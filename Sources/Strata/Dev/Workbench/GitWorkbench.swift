import Foundation

/// What the git status view shows for a repository.
package nonisolated struct GitWorkbenchStatus: Sendable, Equatable {
    package var branch = GitBranchInfo()
    package var operation: GitOperation?
    package var stashCount = 0
    package var untracked: [String] = []
    package var conflicted: [String] = []
    package var unstaged: [GitFileDiff] = []
    package var staged: [GitFileDiff] = []

    package init() {}

    package var isClean: Bool { untracked.isEmpty && conflicted.isEmpty && unstaged.isEmpty && staged.isEmpty }
}

/// How a git command the user asked for ended.
package enum GitOutcome: Equatable, Sendable {
    case done
    case refused(GitWriter.Refusal)
    /// Git's own message.
    case failed(String)
    case emptyMessage
    case nothingStaged
    /// A rebase stopped to let the user edit or resolve a conflict.
    case stopped
}

/// The arguments for each command, kept apart so tests can read them. Paths are always literal: a file named `*` or
/// `:(glob)x` is that file, never a pattern.
package nonisolated enum GitCommands {
    package static func literal(_ paths: [String]) -> [String] { ["--"] + paths.map { ":(literal)" + $0 } }

    package static func stage(_ paths: [String]) -> [String] { ["add", "-A"] + literal(paths) }

    package static func unstage(_ paths: [String], hasHead: Bool) -> [String] {
        // Before the first commit there's nothing to restore from: the paths leave the index.
        hasHead ? ["restore", "--staged"] + literal(paths) : ["rm", "--cached", "-r", "-q"] + literal(paths)
    }

    package static func applyToIndex(patch: String, reverse: Bool) -> [String] {
        ["apply", "--cached", "--whitespace=nowarn"] + (reverse ? ["--reverse"] : []) + [patch]
    }

    package static func commit(messageFile: String, amend: Bool) -> [String] {
        ["commit", "--cleanup=strip", "-F", messageFile] + (amend ? ["--amend"] : [])
    }

    /// What `--cleanup=strip` would leave nothing of: blank lines and `#` comments.
    package static func isEmptyMessage(_ message: String) -> Bool {
        message.split(whereSeparator: \.isNewline).allSatisfy { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed.hasPrefix("#")
        }
    }

    static let diff = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "-M", "--src-prefix=a/", "--dst-prefix=b/"]
}

/// What a diff view compares.
package nonisolated enum GitDiffKind: Equatable, Sendable {
    /// The working files against the index.
    case unstaged
    /// The index against the last commit.
    case staged
    /// The working files against the last commit: everything not yet committed.
    case uncommitted
    /// One commit against its first parent.
    case commit(String)
    /// From one commit to another.
    case range(String, String)

    /// The whole command. `--end-of-options` keeps a name that starts with a dash from being read as an option.
    package var arguments: [String] {
        switch self {
        case .unstaged: GitCommands.diff
        case .staged: GitCommands.diff + ["--cached"]
        case .uncommitted: GitCommands.diff + ["HEAD"]
        // `show` also works for the first commit, which has no parent to diff against.
        case .commit(let id): ["show", "--format=", "--first-parent"] + Array(GitCommands.diff.dropFirst()) + ["--end-of-options", id]
        case .range(let from, let to): GitCommands.diff + ["--end-of-options", from, to]
        }
    }
}

/// A repository's status and the commands that stage, unstage and commit, for one window's environment.
package final class GitWorkbench {
    package let repository: GitRepository
    package let writer: GitWriter
    /// The todo and message files of a rebase that stopped, removed when it finishes or is aborted.
    var rebaseScratch: [URL] = []

    package init(repository: GitRepository, writer: GitWriter) {
        self.repository = repository
        self.writer = writer
    }

    /// Reads status and both diffs. A trusted repository is read with its own filters, so a git-lfs file's diff is
    /// what staging it would record; others with the hardened runner. Nil when git can't read it.
    package func load() async -> GitWorkbenchStatus? {
        let interval = gitSignposts.beginInterval("git status load")
        defer { gitSignposts.endInterval("git status load", interval) }
        let trusted = await writer.trust.isTrusted(repository)
        let environment = writer.readEnvironment
        let root = repository.root
        func read(_ arguments: [String]) async -> GitRunResult {
            trusted ? await GitRunner.runConfigured(arguments, in: root, environment: environment, timeout: 30, readOnly: true)
                    : await GitRunner.run(arguments, in: root, timeout: 30)
        }
        async let status = read(["status", "--porcelain=v2", "-z", "--branch", "--show-stash", "--untracked-files=all",
                                 "--ignore-submodules=dirty"])
        async let unstaged = read(GitCommands.diff)
        async let staged = read(GitCommands.diff + ["--cached"])
        let (statusRun, unstagedRun, stagedRun) = await (status, unstaged, staged)
        guard statusRun.succeeded, unstagedRun.succeeded, stagedRun.succeeded else { return nil }
        let parsed = GitStatusParser.parse(statusRun.output)
        var result = GitWorkbenchStatus()
        result.branch = parsed.branch
        result.stashCount = parsed.stashCount
        result.operation = await Self.operation(in: repository)
        let entries = parsed.entries.values.sorted { $0.path < $1.path }
        result.untracked = entries.filter { $0.kind == .untracked }.map(\.path)
        result.conflicted = entries.filter { $0.kind == .conflicted }.map(\.path)
        let conflicted = Set(result.conflicted)
        result.unstaged = GitDiffParser.parse(unstagedRun.output).filter { !conflicted.contains($0.path) }
        result.staged = GitDiffParser.parse(stagedRun.output)
        return result
    }

    package func stage(_ paths: [String]) async -> GitOutcome {
        guard !paths.isEmpty else { return .done }
        return await run(GitCommands.stage(paths))
    }

    package func unstage(_ paths: [String]) async -> GitOutcome {
        guard !paths.isEmpty else { return .done }
        let hasHead = await hasHead()
        return await run(GitCommands.unstage(paths, hasHead: hasHead))
    }

    /// Stages one hunk of `file`'s unstaged diff, or only the chosen lines of it.
    package func stage(_ file: GitFileDiff, hunk: Int, lines: Set<Int>? = nil) async -> GitOutcome {
        await apply(file, hunk: hunk, lines: lines, reverse: false)
    }

    /// Unstages one hunk of `file`'s staged diff, or only the chosen lines of it.
    package func unstage(_ file: GitFileDiff, hunk: Int, lines: Set<Int>? = nil) async -> GitOutcome {
        await apply(file, hunk: hunk, lines: lines, reverse: true)
    }

    /// The last commit's message, for amending or rewording it.
    package func headMessage() async -> String? {
        let run = await GitRunner.run(["log", "-1", "--format=%B"], in: repository.root, timeout: 10)
        return run.succeeded ? String(decoding: run.output, as: UTF8.self) : nil
    }

    /// What's staged, as `git diff --cached --stat` sums it up, for the commit editor.
    package func stagedSummary() async -> String {
        let run = await GitRunner.run(["diff", "--cached", "--stat", "--no-color", "--ignore-submodules=dirty"], in: repository.root, timeout: 10)
        return run.succeeded ? String(decoding: run.output, as: UTF8.self) : ""
    }

    /// Adds what's staged to the last commit, keeping its message.
    package func extend() async -> GitOutcome {
        await run(["commit", "--amend", "--no-edit"])
    }

    /// A commit, or with `amend` a replacement for the last one; `onlyMessage` rewords it without taking what's staged.
    package func commit(message: String, amend: Bool, onlyMessage: Bool) async -> GitOutcome {
        guard onlyMessage else { return await commit(message: message, amend: amend) }
        guard !GitCommands.isEmptyMessage(message) else { return .emptyMessage }
        return await withScratchFile(message) { file in
            await run(GitCommands.commit(messageFile: file, amend: true) + ["--only"])
        }
    }

    /// A full diff for the diff view: what `kind` compares, with every hunk.
    package func diff(_ kind: GitDiffKind) async -> [GitFileDiff]? {
        let run = await GitRunner.run(kind.arguments, in: repository.root, timeout: 30)
        return run.succeeded ? GitDiffParser.parse(run.output) : nil
    }

    /// A page of history in topological order: the current branch, or every branch with `all`.
    package func log(all: Bool, skip: Int = 0, limit: Int = 500) async -> [GitCommit]? {
        let arguments = ["log", GitLogParser.format, "--topo-order", "--no-color", "-n", String(limit), "--skip", String(skip)]
            + (all ? ["--all"] : [])
        let run = await GitRunner.run(arguments, in: repository.root, timeout: 30)
        // A repository without commits has no log yet, which isn't an error.
        if !run.succeeded, run.errorOutput.contains("does not have any commits") { return [] }
        return run.succeeded ? GitLogParser.parse(run.output) : nil
    }

    /// A commit's author, date and whole message, for its diff view.
    package func describe(commit id: String) async -> String? {
        let run = await GitRunner.run(["show", "-s", "--no-color", "--format=%an <%ae>%n%ad%n%n%B", "--date=local", "--end-of-options", id],
                                      in: repository.root, timeout: 10)
        return run.succeeded ? String(decoding: run.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    package func commit(message: String, amend: Bool) async -> GitOutcome {
        guard !GitCommands.isEmptyMessage(message) else { return .emptyMessage }
        // Refused before asking anything else, so the reason given is the one that matters.
        guard await writer.trust.isTrusted(repository) else { return .refused(.untrusted) }
        if !amend {
            let nothing = await GitRunner.run(["diff", "--cached", "--quiet", "--ignore-submodules=dirty"], in: repository.root, timeout: 30)
            if nothing.exitCode == 0, !nothing.timedOut { return .nothingStaged }
        }
        return await withScratchFile(message) { file in await run(GitCommands.commit(messageFile: file, amend: amend)) }
    }

    private func apply(_ file: GitFileDiff, hunk: Int, lines: Set<Int>?, reverse: Bool) async -> GitOutcome {
        guard file.allowsPartialStaging, let patch = GitPatch.make(file, hunk: hunk, lines: lines, reverse: reverse) else {
            return .failed(String(localized: "This change can only be staged as a whole file.",
                                  comment: "Git status: a hunk of a new, deleted or binary file was chosen"))
        }
        return await withScratchFile(patch) { path in await run(GitCommands.applyToIndex(patch: path, reverse: reverse)) }
    }

    func run(_ arguments: [String], options: GitWriter.Options = GitWriter.Options()) async -> GitOutcome {
        switch await writer.run(arguments, in: repository, options: options) {
        case .failure(let refusal): return .refused(refusal)
        case .success(let result) where result.succeeded: return .done
        case .success(let result):
            let message = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(result.timedOut ? String(localized: "Git took too long and was stopped.") : message)
        }
    }

    /// Reads marker files in the git directory, so never on the main thread.
    @concurrent nonisolated static func operation(in repository: GitRepository) async -> GitOperation? {
        repository.operationInProgress()
    }

    /// The branch HEAD names, or nil when detached.
    package func currentBranch() async -> String? {
        let run = await GitRunner.run(["symbolic-ref", "--short", "-q", "HEAD"], in: repository.root, timeout: 10)
        let name = String(decoding: run.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return run.succeeded && !name.isEmpty ? name : nil
    }

    private func hasHead() async -> Bool {
        await GitRunner.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: repository.root, timeout: 10).succeeded
    }

    /// `text` in a file of Strata's own for git to read (a patch, a commit message), removed afterwards.
    private func withScratchFile(_ text: String, _ body: (String) async -> GitOutcome) async -> GitOutcome {
        guard let file = await GitScratch.write(text) else {
            return .failed(String(localized: "Strata couldn’t write a temporary file for git."))
        }
        let outcome = await body(file.path)
        await GitScratch.remove(file)
        return outcome
    }
}

/// Strata's own temporary files for git, in a folder only Strata writes to.
package nonisolated enum GitScratch {
    package static func write(_ text: String) async -> URL? { await write(Data(text.utf8)) }

    @concurrent
    package static func remove(_ file: URL) async {
        // Only a regular file Strata made, never through a link.
        var info = stat()
        guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return }
        unlink(file.path)
    }
}
