import Foundation

/// An interactive rebase's plan: each commit, oldest first, and what to do with it.
package nonisolated struct GitRebaseTodo: Sendable, Equatable {
    package enum Action: Sendable, Equatable {
        case pick
        /// Kept with a new message.
        case reword(String)
        /// Stops after it, to change it.
        case edit
        /// Folded into the commit before it, messages joined.
        case squash
        /// Folded into the commit before it, keeping that one's message.
        case fixup
        case drop

        package var word: String {
            switch self {
            case .pick, .reword: "pick"
            case .edit: "edit"
            case .squash: "squash"
            case .fixup: "fixup"
            case .drop: "drop"
            }
        }
    }

    package struct Step: Sendable, Equatable {
        package let commit: GitCommit
        package var action: Action
    }

    package var steps: [Step]

    package init(_ commits: [GitCommit]) {
        steps = commits.map { Step(commit: $0, action: .pick) }
    }

    package mutating func move(from: Int, to: Int) {
        guard steps.indices.contains(from), steps.indices.contains(to) else { return }
        steps.insert(steps.remove(at: from), at: to)
    }

    /// Why git would refuse this plan, before it's tried.
    package var problem: String? {
        let kept = steps.filter { $0.action != .drop }
        guard !kept.isEmpty else { return String(localized: "Every commit is dropped; keep at least one, or reset instead.") }
        if [.squash, .fixup].contains(kept[0].action) {
            return String(localized: "The first commit has nothing before it to fold into.")
        }
        return nil
    }

    /// The todo file git reads. A reword is a pick followed by an amend from a message file Strata wrote, so no
    /// editor opens. `messageFiles` holds one path per reword, in order.
    package func text(messageFiles: [String]) -> String {
        var lines: [String] = []
        var messages = messageFiles.makeIterator()
        for step in steps {
            lines.append("\(step.action.word) \(step.commit.id) \(step.commit.subject)")
            if case .reword = step.action, let file = messages.next() {
                lines.append("exec git commit --amend --quiet --no-edit --allow-empty --cleanup=strip -F \(Self.quote(file))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    package var rewordMessages: [String] {
        steps.compactMap { if case .reword(let message) = $0.action { message } else { nil } }
    }

    /// Single quotes for the shell that runs the todo's `exec` lines and the sequence editor.
    package static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

extension GitWorkbench {
    /// Rebases the commits after `base` (nil: from the first commit) by `todo`. The plan must name exactly the
    /// commits git would rebase, or a missing one would be dropped silently. Returns `.stopped` when git stops for an
    /// edit or a conflict; a rebase that finishes can be undone.
    package func rebase(_ todo: GitRebaseTodo, onto base: String?) async -> (GitOutcome, GitUndo?) {
        guard await writer.trust.isTrusted(repository) else { return (.refused(.untrusted), nil) }
        if let problem = todo.problem { return (.failed(problem), nil) }
        let resolvedBase: String?
        if let base {
            guard let commit = await resolveCommit(base) else { return (.failed(String(localized: "That isn’t a commit in this repository.")), nil) }
            resolvedBase = commit
        } else {
            resolvedBase = nil
        }
        guard await isClean() else { return (.failed(String(localized: "Commit or stash your changes before rebasing.")), nil) }
        let range = resolvedBase.map { "\($0)..HEAD" } ?? "HEAD"
        guard let listed = await readOutput(["rev-list", "--reverse", "--end-of-options", range]),
              let merges = await readOutput(["rev-list", "--merges", "--end-of-options", range]) else {
            return (.failed(String(localized: "Git couldn’t list the commits to rebase.")), nil)
        }
        guard merges.isEmpty else { return (.failed(String(localized: "Merges can’t be rebased here; rebase a range without them.")), nil) }
        let expected = Set(listed.split(separator: "\n").map(String.init))
        guard expected == Set(todo.steps.map(\.commit.id)), expected.count == todo.steps.count else {
            return (.failed(String(localized: "The plan doesn’t match the branch any more; open it again.")), nil)
        }
        guard let from = await resolveCommit("HEAD") else { return (.failed(String(localized: "The branch has no commits.")), nil) }

        var scratch: [URL] = []
        for message in todo.rewordMessages {
            guard let file = await GitScratch.write(message) else { return (.failed(String(localized: "Strata couldn’t write a temporary file for git.")), nil) }
            scratch.append(file)
        }
        guard let todoFile = await GitScratch.write(todo.text(messageFiles: scratch.map(\.path))) else {
            return (.failed(String(localized: "Strata couldn’t write a temporary file for git.")), nil)
        }
        scratch.append(todoFile)
        let undo = GitUndo(id: UUID().uuidString, kind: .rebase(from: from, to: from))
        _ = await run(["update-ref", "--no-deref", undo.refPrefix + "head", from])
        let outcome = await run(["rebase", "-i", "--no-autosquash", "--no-update-refs"] + (resolvedBase.map { ["--end-of-options", $0] } ?? ["--root"]),
                                options: GitWriter.Options(environment: Self.rebaseEnvironment(todo: todoFile.path), timeout: 600))
        rebaseScratch = scratch
        if await Self.operation(in: repository) != nil {
            return (.stopped, nil)
        }
        await removeScratch()
        guard outcome == .done, let to = await resolveCommit("HEAD") else {
            await removeRefs(undo)
            return (outcome == .done ? .failed(String(localized: "Git couldn’t finish the rebase.")) : outcome, nil)
        }
        return (.done, GitUndo(id: undo.id, kind: .rebase(from: from, to: to)))
    }

    package func rebaseContinue() async -> GitOutcome { await rebaseStep("--continue") }
    package func rebaseSkip() async -> GitOutcome { await rebaseStep("--skip") }

    package func rebaseAbort() async -> GitOutcome {
        let outcome = await run(["rebase", "--abort"])
        await removeScratch()
        return outcome
    }

    private func rebaseStep(_ step: String) async -> GitOutcome {
        let outcome = await run(["rebase", step], options: GitWriter.Options(environment: ["GIT_EDITOR": "true"], timeout: 600))
        if await Self.operation(in: repository) != nil { return outcome == .done ? .stopped : outcome }
        await removeScratch()
        return outcome
    }

    /// Git copies Strata's todo in place of its own; messages of squashed commits are taken as git proposes them.
    private static func rebaseEnvironment(todo: String) -> [String: String] {
        ["GIT_SEQUENCE_EDITOR": "cp " + GitRebaseTodo.quote(todo), "GIT_EDITOR": "true"]
    }

    private func removeScratch() async {
        for file in rebaseScratch { await GitScratch.remove(file) }
        rebaseScratch = []
    }
}
