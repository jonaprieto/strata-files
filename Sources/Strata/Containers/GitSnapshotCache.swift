import CryptoKit
import Foundation
import StrataSupport

/// Where past commits' files are kept for browsing: `Git Snapshots/<repository>/<commit>/<name>/…` in Strata's
/// caches. Everything here is a read-only copy (`ReadOnlyCopies`): no command of Strata's changes it.
package nonisolated enum GitSnapshotCache {
    package static let root: URL = {
        SecureStorage.Context.shared.caches.appending(path: "Git Snapshots", directoryHint: .isDirectory).lexicallyStandardized
    }()

    private static let rootPath = root.path

    package static func contains(_ url: URL) -> Bool {
        let path = PathSpelling.short(url)
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    /// A repository's folder of snapshots, named by a digest of where the repository is.
    package static func repositoryFolder(_ repositoryPath: String) -> URL {
        let digest = SHA256.hash(data: Data(repositoryPath.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: digest, directoryHint: .isDirectory)
    }

    /// The top of `commit`'s snapshot, named like the repository so the path bar and window title read naturally.
    package static func top(repositoryPath: String, commit: String, name: String) -> URL {
        repositoryFolder(repositoryPath).appending(path: commit, directoryHint: .isDirectory).appending(path: name, directoryHint: .isDirectory)
    }

    /// For a folder inside a snapshot: its commit and the snapshot's top.
    package static func commit(containing url: URL) -> (commit: String, top: URL)? {
        let path = PathSpelling.short(url)
        guard path.hasPrefix(rootPath + "/") else { return nil }
        let parts = path.dropFirst(rootPath.count + 1).split(separator: "/")
        guard parts.count >= 3, parts[1].count >= 40, parts[1].allSatisfy(\.isHexDigit) else { return nil }
        let top = root.appending(path: String(parts[0]), directoryHint: .isDirectory)
            .appending(path: String(parts[1]), directoryHint: .isDirectory).appending(path: String(parts[2]), directoryHint: .isDirectory)
        return (String(parts[1]), top)
    }
}
