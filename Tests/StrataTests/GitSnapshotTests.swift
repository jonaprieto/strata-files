import Foundation
import Testing
@testable import Strata
@testable import StrataDev

/// A past commit's files, as Strata shows them: a read-only copy made without touching the repository's index or
/// working files, and refused to every command that would change it.
@Suite struct GitSnapshotTests {
    /// "a" at 1, then 2; "gone" only in the first commit; "later" only in the second.
    private func history() async throws -> (GitFixture, first: String, second: String) {
        let repo = try await GitFixture(["a": "1\n", "gone": "x\n", "sub/b": "b\n"])
        let first = try await repo.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        try repo.write("a", "2\n")
        try FileManager.default.removeItem(at: repo.url("gone"))
        try repo.write("later", "l\n")
        try await repo.git("add", "-A")
        try await repo.git("commit", "-q", "-m", "second")
        let second = try await repo.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        return (repo, first, second)
    }

    @Test func aPastCommitsFilesAsTheyWere() async throws {
        let (repo, first, _) = try await history()
        try repo.write("a", "uncommitted\n")
        let index = try await repo.index()
        let status = try await repo.git("status", "--porcelain")

        let top = try #require(await GitSnapshots.make(repo.repository, commit: first))
        #expect(GitSnapshotCache.contains(top))
        #expect(try String(contentsOf: top.appending(path: "a"), encoding: .utf8) == "1\n")
        #expect(try String(contentsOf: top.appending(path: "gone"), encoding: .utf8) == "x\n")
        #expect(try String(contentsOf: top.appending(path: "sub/b"), encoding: .utf8) == "b\n")
        #expect(!FileManager.default.fileExists(atPath: top.appending(path: "later").path))
        #expect(!FileManager.default.fileExists(atPath: top.appending(path: ".git").path))
        #expect(top.lastPathComponent == repo.root.lastPathComponent)
        #expect(GitSnapshotCache.commit(containing: top.appending(path: "sub"))?.commit == first)

        // The repository is as it was: its index, its status and the uncommitted change.
        #expect(try await repo.index() == index)
        #expect(try await repo.git("status", "--porcelain") == status)
        #expect(repo.text("a") == "uncommitted\n")
    }

    /// Checked-out files would all read as made just now; they carry the commit's date, as the log shows it, and a
    /// link's own date changes, never what it points to.
    @Test func aSnapshotsFilesAreDatedByTheirCommit() async throws {
        let outside = try TestTree("target")
        let before = try Self.modified(outside.url("target"))
        let repo = try await GitFixture(["a": "1\n", "sub/b": "b\n"])
        try FileManager.default.createSymbolicLink(atPath: repo.url("link").path, withDestinationPath: outside.url("target").path)
        try await repo.git("add", "-A")
        try await repo.git("commit", "-q", "-m", "dated", "--date=@1000000000")
        let id = try await repo.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)

        let top = try #require(await GitSnapshots.make(repo.repository, commit: id))
        let dated = Date(timeIntervalSince1970: 1_000_000_000)
        for path in ["a", "sub", "sub/b", "link"] { #expect(try Self.modified(top.appending(path: path)) == dated, "\(path)") }
        #expect(try Self.modified(outside.url("target")) == before)
        withExtendedLifetime(outside) {}
    }

    /// The item's own date, without following a link.
    private static func modified(_ url: URL) throws -> Date {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    }

    @Test func snapshotsAreReadOnlyToEveryCommand() async throws {
        let (repo, first, _) = try await history()
        let top = try #require(await GitSnapshots.make(repo.repository, commit: first))
        let environment = try IndependentEnvironment()
        let copies = environment.services.copies
        #expect(ReadOnlyCopies.contains(top.appending(path: "a"), copies: copies))
        #expect(!FileOps.canTrash(top.appending(path: "a"), copies: copies))
        #expect(throws: (any Error).self) { _ = try FileOps.newFolder(in: top, undo: nil, copies: copies, history: environment.services.transfers.history) }
        #expect(try String(contentsOf: top.appending(path: "a"), encoding: .utf8) == "1\n")
        withExtendedLifetime(environment) {}
    }

    @Test func theSameCommitIsMadeOnceAndBadNamesNever() async throws {
        let (repo, first, second) = try await history()
        let one = try #require(await GitSnapshots.make(repo.repository, commit: first))
        let again = try #require(await GitSnapshots.make(repo.repository, commit: first))
        #expect(one == again)
        let other = try #require(await GitSnapshots.make(repo.repository, commit: second))
        #expect(other != one)
        for name in ["--output=/tmp/x", "nope", "", "../../etc"] {
            #expect(await GitSnapshots.make(repo.repository, commit: name) == nil, "\(name)")
        }
    }

    @Test func onlyTheNewestSnapshotsOfARepositoryAreKept() async throws {
        let repo = try await GitFixture(["a": "0\n"])
        var made: [URL] = []
        for index in 1...(GitSnapshots.kept + 2) {
            try repo.write("a", "\(index)\n")
            try await repo.git("commit", "-q", "-am", "\(index)")
            let id = try await repo.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
            made.append(try #require(await GitSnapshots.make(repo.repository, commit: id)))
        }
        let kept = made.filter { FileManager.default.fileExists(atPath: $0.path) }
        #expect(kept == Array(made.suffix(GitSnapshots.kept)))
        // The repository's own files are never part of it.
        #expect(repo.text("a") == "\(GitSnapshots.kept + 2)\n")
    }

    @Test func pathsMapBetweenTheRepositoryAndItsSnapshots() {
        let root = URL(fileURLWithPath: "/r/repo")
        let top = URL(fileURLWithPath: "/cache/k/abc/repo")
        #expect(GitSnapshots.path(of: URL(fileURLWithPath: "/r/repo/sub/x"), from: root, to: top).path == "/cache/k/abc/repo/sub/x")
        #expect(GitSnapshots.path(of: root, from: root, to: top).path == top.path)
        #expect(GitSnapshots.path(of: URL(fileURLWithPath: "/r/repository/x"), from: root, to: top).path == top.path)
    }
}
