import Foundation

/// Past commits' files for browsing, made from the repository's objects with a temporary index of their own: the
/// repository's index, working files and branch are never touched, and with the hardened runner its hooks and filters
/// don't run (a git-lfs file shows as its pointer). Each is built aside and moved into place whole.
package nonisolated enum GitSnapshots {
    /// Snapshots kept per repository; older ones go as new ones are made.
    package static let kept = 8

    /// The top of `commit`'s snapshot, made if it isn't yet. Nil when `commit` isn't a commit of the repository or the
    /// copy can't be made.
    @concurrent
    package static func make(_ repository: GitRepository, commit: String) async -> URL? {
        guard !commit.isEmpty, !commit.hasPrefix("-") else { return nil }
        let resolved = await GitRunner.run(["rev-parse", "--verify", "--quiet", "--end-of-options", commit + "^{commit}"],
                                           in: repository.root, timeout: 10)
        let id = String(decoding: resolved.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolved.succeeded, id.count >= 40, id.allSatisfy(\.isHexDigit) else { return nil }
        let top = GitSnapshotCache.top(repositoryPath: repository.rootPath, commit: id, name: repository.root.lastPathComponent)
        let commitFolder = top.deletingLastPathComponent()
        let fm = FileManager.default
        if isFolder(top) {
            touch(commitFolder)
            return top
        }
        do {
            try fm.createDirectory(at: commitFolder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let staging = commitFolder.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        let index = commitFolder.appending(path: ".index-\(UUID().uuidString)")
        defer {
            if isFolder(staging) { Archiver.removeTree(staging) }
            unlink(index.path)
        }
        let environment = ["GIT_INDEX_FILE": index.path]
        guard await GitRunner.run(["read-tree", "--end-of-options", id], in: repository.root, timeout: 60, environment: environment).succeeded,
              await GitRunner.run(["checkout-index", "-a", "-f", "--prefix=" + staging.path + "/"], in: repository.root,
                                  timeout: 300, environment: environment).succeeded,
              (try? fm.moveItem(at: isFolder(staging) ? staging : emptyFolder(staging), to: top)) != nil else { return nil }
        touch(commitFolder)
        evict(beside: commitFolder)
        return top
    }

    /// `url` inside the repository at `root`, at the same place under `top`; `top` itself when it's elsewhere.
    package static func path(of url: URL, from root: URL, to top: URL) -> URL {
        guard let relative = GitStatusSnapshot.relativePath(url.lexicallyStandardized.path, root: root.lexicallyStandardized.path),
              !relative.isEmpty else { return top }
        return top.appending(path: relative)
    }

    private static func isFolder(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// A commit with no files checks out nothing; its snapshot is an empty folder.
    private static func emptyFolder(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Marks a snapshot as just used, for keeping the newest.
    private static func touch(_ folder: URL) {
        utimes(folder.path, nil)
    }

    /// Removes all but the `kept` most recently used snapshots of the repository, only ever inside the cache.
    private static func evict(beside current: URL) {
        let repositoryFolder = current.deletingLastPathComponent()
        guard GitSnapshotCache.contains(repositoryFolder), repositoryFolder != GitSnapshotCache.root else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: repositoryFolder.path)) ?? []
        let snapshots = names.filter { $0.count >= 40 && $0.allSatisfy(\.isHexDigit) }.compactMap { name -> (URL, Double)? in
            let url = repositoryFolder.appending(path: name, directoryHint: .isDirectory)
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
            return (url, Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
        }
        for (url, _) in snapshots.sorted(by: { $0.1 > $1.1 }).dropFirst(kept) where url != current {
            Archiver.removeTree(url)
        }
    }
}
