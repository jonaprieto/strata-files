import Foundation

/// How to take back a command that rewrote working files, and what it must still find to do so. Everything it needs
/// is kept in the repository under `refs/strata/undo/<id>/`, so git's garbage collection can't take it, and the refs
/// go when the undo runs.
package nonisolated struct GitUndo: Sendable, Equatable {
    package enum Kind: Sendable, Equatable {
        /// Files as they were (a saved blob and mode, or nothing for a file that wasn't there), and the object each
        /// had right after the discard: undo restores a file only while it's still exactly that.
        case files([SavedFile])
        /// HEAD moved from `from` to `to`. `index` and `work` hold the index and the uncommitted changes before.
        case reset(mode: GitResetMode, from: String, to: String, index: String, work: String?, indexAfter: String?)
        /// A stash made from the working files; undone by popping it while it's still on top.
        case stashPush(commit: String)
        /// A dropped stash, stored back.
        case stashDrop(commit: String, message: String)
        /// A finished rebase moved the branch from `from` to `to`.
        case rebase(from: String, to: String)
    }

    package struct SavedFile: Sendable, Equatable {
        package let path: String
        /// Nil when there was no file.
        package let blob: String?
        package let mode: mode_t
        package let isLink: Bool
        /// The object the discard left (nil when it left no file).
        package let after: String?
    }

    package let id: String
    package let kind: Kind

    package var refPrefix: String { "refs/strata/undo/\(id)/" }
}

package enum GitResetMode: String, Sendable, Equatable { case soft, mixed, hard }

package nonisolated struct GitStash: Sendable, Equatable {
    package let index: Int
    package let commit: String
    package let message: String
}

/// Whether paths chosen for a discard can be touched: inside the work tree, never git's own folder, only tracked
/// files with unstaged changes.
package nonisolated enum GitDiscard {
    package static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." || $0 == ".git" }
    }

    /// Nil when every path is safe and has an unstaged change; else why not.
    package static func refusal(_ paths: [String], unstaged: Set<String>) -> String? {
        guard !paths.isEmpty else { return String(localized: "Nothing chosen to discard.") }
        if let unsafe = paths.first(where: { !isSafe($0) }) { return String(localized: "“\(unsafe)” isn’t a file in this repository.") }
        if let other = paths.first(where: { !unstaged.contains($0) }) {
            return String(localized: "“\(other)” has no unstaged changes to discard.")
        }
        return nil
    }
}

extension GitWorkbench {
    // MARK: Discard

    /// Takes tracked files back to their staged version, saving what they were first.
    package func discard(_ paths: [String]) async -> (GitOutcome, GitUndo?) {
        guard let status = await load() else { return (.failed(String(localized: "Git couldn’t read this repository.")), nil) }
        if let refusal = GitDiscard.refusal(paths, unstaged: Set(status.unstaged.map(\.path))) { return (.failed(refusal), nil) }
        let id = UUID().uuidString
        guard let saved = await save(paths, undo: id) else { return (.failed(String(localized: "Strata couldn’t save the files before discarding them.")), nil) }
        let outcome = await run(["restore", "--worktree"] + GitCommands.literal(paths))
        return await finish(outcome, saved, id: id)
    }

    /// Discards one hunk, or the chosen lines of it, from the working file.
    package func discard(_ file: GitFileDiff, hunk: Int, lines: Set<Int>? = nil) async -> (GitOutcome, GitUndo?) {
        guard file.allowsPartialStaging, GitDiscard.isSafe(file.path),
              let patch = GitPatch.make(file, hunk: hunk, lines: lines, reverse: true) else {
            return (.failed(String(localized: "This change can only be discarded as a whole file.")), nil)
        }
        let id = UUID().uuidString
        guard let saved = await save([file.path], undo: id) else { return (.failed(String(localized: "Strata couldn’t save the files before discarding them.")), nil) }
        let outcome = await withScratch(patch) { path in await run(["apply", "--reverse", "--whitespace=nowarn", path]) }
        return await finish(outcome, saved, id: id)
    }

    /// Each file's bytes as an object kept under the undo's refs.
    private func save(_ paths: [String], undo id: String) async -> [(path: String, blob: String?, mode: mode_t, isLink: Bool)]? {
        var saved: [(String, String?, mode_t, Bool)] = []
        for (index, path) in paths.enumerated() {
            let url = repository.root.appending(path: path)
            guard let entry = await GitFileSnapshot.read(url) else { saved.append((path, nil, 0, false)); continue }
            guard let blob = await hashObject(entry.contents, write: true),
                  await run(["update-ref", "--no-deref", "\(GitUndo(id: id, kind: .files([])).refPrefix)\(index)", blob]) == .done else { return nil }
            saved.append((path, blob, entry.mode, entry.isLink))
        }
        return saved
    }

    private func finish(_ outcome: GitOutcome, _ saved: [(path: String, blob: String?, mode: mode_t, isLink: Bool)], id: String) async -> (GitOutcome, GitUndo?) {
        guard outcome == .done else {
            await removeRefs(GitUndo(id: id, kind: .files([])))
            return (outcome, nil)
        }
        var files: [GitUndo.SavedFile] = []
        for entry in saved {
            let after = await GitFileSnapshot.read(repository.root.appending(path: entry.path))
            let afterBlob: String? = if let after { await hashObject(after.contents, write: false) } else { nil }
            files.append(.init(path: entry.path, blob: entry.blob, mode: entry.mode, isLink: entry.isLink, after: afterBlob))
        }
        return (.done, GitUndo(id: id, kind: .files(files)))
    }

    // MARK: Reset

    package func reset(to target: String, mode: GitResetMode) async -> (GitOutcome, GitUndo?) {
        guard let to = await resolveCommit(target), let from = await resolveCommit("HEAD") else {
            return (.failed(String(localized: "That isn’t a commit in this repository.")), nil)
        }
        guard let index = await readOutput(["write-tree"]) else { return (.failed(String(localized: "Git couldn’t record the index first.")), nil) }
        let work = await readOutput(["stash", "create"])
        let undo = GitUndo(id: UUID().uuidString, kind: .reset(mode: mode, from: from, to: to, index: index, work: work, indexAfter: nil))
        for (name, object) in [("head", from), ("work", work)] {
            guard let object, !object.isEmpty else { continue }
            guard await run(["update-ref", "--no-deref", undo.refPrefix + name, object]) == .done else {
                await removeRefs(undo)
                return (.failed(String(localized: "Strata couldn’t keep the current state before resetting.")), nil)
            }
        }
        let outcome = await run(["reset", "--\(mode.rawValue)", "-q", "--end-of-options", to])
        guard outcome == .done else { await removeRefs(undo); return (outcome, nil) }
        let after = mode == .mixed ? await readOutput(["write-tree"]) : nil
        return (.done, GitUndo(id: undo.id, kind: .reset(mode: mode, from: from, to: to, index: index, work: work, indexAfter: after)))
    }

    // MARK: Stash

    package func stashes() async -> [GitStash] {
        let run = await GitRunner.run(["stash", "list", "--format=%H%x1f%gs"], in: repository.root, timeout: 10)
        guard run.succeeded else { return [] }
        return String(decoding: run.output, as: UTF8.self).split(separator: "\n").enumerated().compactMap { index, line in
            let fields = line.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            return fields.count == 2 ? GitStash(index: index, commit: fields[0], message: fields[1]) : nil
        }
    }

    package func stashPush(includeUntracked: Bool, message: String?) async -> (GitOutcome, GitUndo?) {
        let before = await stashes().first?.commit
        var arguments = ["stash", "push", "-q"] + (includeUntracked ? ["--include-untracked"] : [])
        if let message, !message.isEmpty { arguments += ["-m", message] }
        let outcome = await run(arguments)
        guard outcome == .done, let made = await stashes().first?.commit, made != before else {
            return (outcome == .done ? .failed(String(localized: "There were no changes to stash.")) : outcome, nil)
        }
        return (.done, GitUndo(id: UUID().uuidString, kind: .stashPush(commit: made)))
    }

    package func stashApply(_ index: Int, pop: Bool) async -> GitOutcome {
        guard await stashes().indices.contains(index) else { return .failed(String(localized: "That stash isn’t there.")) }
        return await run(["stash", pop ? "pop" : "apply", "--index", "-q", "stash@{\(index)}"])
    }

    package func stashDrop(_ index: Int) async -> (GitOutcome, GitUndo?) {
        let list = await stashes()
        guard let stash = list.first(where: { $0.index == index }) else { return (.failed(String(localized: "That stash isn’t there.")), nil) }
        let undo = GitUndo(id: UUID().uuidString, kind: .stashDrop(commit: stash.commit, message: stash.message))
        guard await run(["update-ref", "--no-deref", undo.refPrefix + "stash", stash.commit]) == .done else {
            return (.failed(String(localized: "Strata couldn’t keep the stash before dropping it.")), nil)
        }
        // Dropped by its commit's place, rechecked: a stash pushed meanwhile would shift the index.
        guard await stashes().first(where: { $0.index == index })?.commit == stash.commit else {
            await removeRefs(undo)
            return (.failed(String(localized: "The stashes changed; nothing was dropped.")), nil)
        }
        let outcome = await run(["stash", "drop", "-q", "stash@{\(index)}"])
        guard outcome == .done else { await removeRefs(undo); return (outcome, nil) }
        return (.done, undo)
    }

    // MARK: Undo

    /// Checks everything first and changes nothing unless all of it can be taken back.
    package func undo(_ undo: GitUndo) async -> GitOutcome {
        let outcome: GitOutcome
        switch undo.kind {
        case .files(let files): outcome = await undoFiles(files)
        case .reset(let mode, let from, let to, let index, let work, let indexAfter):
            outcome = await undoReset(mode, from: from, to: to, index: index, work: work, indexAfter: indexAfter)
        case .stashPush(let commit):
            guard await stashes().first?.commit == commit else {
                return .failed(String(localized: "That stash is no longer the newest; nothing was changed."))
            }
            guard await isClean() else { return .failed(String(localized: "Files changed since the stash; nothing was changed.")) }
            outcome = await run(["stash", "pop", "--index", "-q"])
        case .stashDrop(let commit, let message):
            outcome = await run(["stash", "store", "-q", "-m", message, commit])
        case .rebase(let from, let to):
            guard await resolveCommit("HEAD") == to else {
                return .failed(String(localized: "The branch has moved since the rebase; nothing was changed."))
            }
            guard await isClean() else { return .failed(String(localized: "Files changed since the rebase; nothing was changed.")) }
            outcome = await run(["reset", "--hard", "-q", "--end-of-options", from])
        }
        if outcome == .done { await removeRefs(undo) }
        return outcome
    }

    private func undoFiles(_ files: [GitUndo.SavedFile]) async -> GitOutcome {
        for file in files {
            guard GitDiscard.isSafe(file.path) else { return .failed(String(localized: "“\(file.path)” isn’t a file in this repository.")) }
            let current = await GitFileSnapshot.read(repository.root.appending(path: file.path))
            let currentBlob: String? = if let current { await hashObject(current.contents, write: false) } else { nil }
            guard currentBlob == file.after else {
                return .failed(String(localized: "“\(file.path)” changed since it was discarded; nothing was changed."))
            }
        }
        var contents: [(GitUndo.SavedFile, Data?)] = []
        for file in files {
            guard let blob = file.blob else { contents.append((file, nil)); continue }
            let run = await GitRunner.run(["cat-file", "blob", blob], in: repository.root, timeout: 30)
            guard run.succeeded else { return .failed(String(localized: "The saved copy of “\(file.path)” is gone.")) }
            contents.append((file, run.output))
        }
        for (file, data) in contents {
            guard await GitFileSnapshot.restore(repository.root, path: file.path, contents: data, mode: file.mode, isLink: file.isLink) else {
                return .failed(String(localized: "“\(file.path)” couldn’t be restored."))
            }
        }
        didChangeFiles()
        return .done
    }

    private func undoReset(_ mode: GitResetMode, from: String, to: String, index: String, work: String?, indexAfter: String?) async -> GitOutcome {
        guard await resolveCommit("HEAD") == to else {
            return .failed(String(localized: "The branch has moved since the reset; nothing was changed."))
        }
        switch mode {
        case .soft:
            return await run(["reset", "--soft", "-q", "--end-of-options", from])
        case .mixed:
            guard await readOutput(["write-tree"]) == indexAfter else {
                return .failed(String(localized: "The index changed since the reset; nothing was changed."))
            }
            let moved = await run(["reset", "--soft", "-q", "--end-of-options", from])
            guard moved == .done else { return moved }
            return await run(["read-tree", index])
        case .hard:
            guard await isClean() else { return .failed(String(localized: "Files changed since the reset; nothing was changed.")) }
            let moved = await run(["reset", "--hard", "-q", "--end-of-options", from])
            guard moved == .done, let work, !work.isEmpty else { return moved }
            return await run(["stash", "apply", "--index", "-q", work])
        }
    }

    // MARK: Helpers

    /// No staged or unstaged changes to tracked files (untracked files don't count: nothing here touches them).
    func isClean() async -> Bool {
        let run = await GitRunner.run(["status", "--porcelain", "--untracked-files=no", "--ignore-submodules=dirty"], in: repository.root, timeout: 30)
        return run.succeeded && run.output.isEmpty
    }

    func resolveCommit(_ name: String) async -> String? {
        guard !name.isEmpty, !name.hasPrefix("-") else { return nil }
        return await readOutput(["rev-parse", "--verify", "--quiet", "--end-of-options", name + "^{commit}"])
    }

    func readOutput(_ arguments: [String]) async -> String? {
        let run = await GitRunner.run(arguments, in: repository.root, timeout: 30)
        let text = String(decoding: run.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return run.succeeded ? text : nil
    }

    /// Git's object id for `contents`, stored with `write`. Never through filters: the bytes are the file's own.
    private func hashObject(_ contents: Data, write: Bool) async -> String? {
        guard let file = await GitScratch.write(contents) else { return nil }
        defer { Task { await GitScratch.remove(file) } }
        let run = await GitRunner.run(["hash-object", "--no-filters"] + (write ? ["-w"] : []) + ["--", file.path], in: repository.root, timeout: 30)
        let id = String(decoding: run.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return run.succeeded && !id.isEmpty ? id : nil
    }

    func removeRefs(_ undo: GitUndo) async {
        let run = await GitRunner.run(["for-each-ref", "--format=%(refname)", undo.refPrefix], in: repository.root, timeout: 10)
        for ref in String(decoding: run.output, as: UTF8.self).split(separator: "\n") where ref.hasPrefix(undo.refPrefix) {
            _ = await self.run(["update-ref", "-d", "--no-deref", String(ref)])
        }
    }

    private func withScratch(_ text: String, _ body: (String) async -> GitOutcome) async -> GitOutcome {
        guard let file = await GitScratch.write(Data(text.utf8)) else { return .failed(String(localized: "Strata couldn’t write a temporary file for git.")) }
        let outcome = await body(file.path)
        await GitScratch.remove(file)
        return outcome
    }

    /// Files Strata wrote itself: the status refreshes as after a git command.
    private func didChangeFiles() { writer.noteChanged(repository) }
}

/// A working file's bytes and mode, read and restored without following links.
package nonisolated enum GitFileSnapshot {
    package struct Entry: Sendable {
        package let contents: Data
        package let mode: mode_t
        package let isLink: Bool
    }

    /// Nil when nothing is there. A link's contents are its target, as git stores it.
    @concurrent
    package static func read(_ url: URL) async -> Entry? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        if (info.st_mode & S_IFMT) == S_IFLNK {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = readlink(url.path, &buffer, buffer.count - 1)
            guard count >= 0 else { return nil }
            return Entry(contents: Data(buffer[0..<count].map { UInt8(bitPattern: $0) }), mode: info.st_mode, isLink: true)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard let data = try? handle.readToEnd() else { return nil }
        return Entry(contents: data ?? Data(), mode: info.st_mode, isLink: false)
    }

    /// Puts `contents` back at `path` (nil removes the file git restored there): written beside it, then renamed over,
    /// so the path never holds a half-written file. Never writes through a link or outside `root`.
    @concurrent
    package static func restore(_ root: URL, path: String, contents: Data?, mode: mode_t, isLink: Bool) async -> Bool {
        guard GitDiscard.isSafe(path) else { return false }
        let target = root.appending(path: path)
        let folder = target.deletingLastPathComponent()
        // Every folder on the way is a real folder inside the work tree, not a link out of it.
        var info = stat()
        guard lstat(folder.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              folder.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path) else { return false }
        guard let contents else {
            // Only a regular file or link that git put there is removed.
            guard lstat(target.path, &info) == 0, [S_IFREG, S_IFLNK].contains(info.st_mode & S_IFMT) else { return lstat(target.path, &info) != 0 }
            return unlink(target.path) == 0
        }
        let temporary = folder.appending(path: ".strata-restore-\(UUID().uuidString)")
        if isLink {
            guard symlink(String(decoding: contents, as: UTF8.self), temporary.path) == 0 else { return false }
        } else {
            let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode & 0o7777)
            guard descriptor >= 0 else { return false }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do { try handle.write(contentsOf: contents) } catch { unlink(temporary.path); return false }
            fchmod(descriptor, mode & 0o7777)
        }
        guard rename(temporary.path, target.path) == 0 else { unlink(temporary.path); return false }
        return true
    }
}

extension GitScratch {
    @concurrent
    package static func write(_ data: Data) async -> URL? {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Strata-git", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = folder.appending(path: UUID().uuidString)
            try data.write(to: file, options: [.withoutOverwriting])
            return file
        } catch {
            return nil
        }
    }
}
