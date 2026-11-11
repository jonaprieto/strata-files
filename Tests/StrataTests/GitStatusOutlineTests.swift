import Foundation
import Testing
@testable import Strata
@testable import StrataDev

/// The status view's rows, and what `s` and `u` do with the rows selected: exactly those changes.
@Suite struct GitStatusOutlineTests {
    private func file(_ path: String, hunks: [[GitDiffLine]] = [[.init(kind: .removed, text: "a"), .init(kind: .added, text: "b")]],
                      new: Bool = false) -> GitFileDiff {
        var file = GitFileDiff()
        file.oldPath = new ? nil : path
        file.newPath = path
        file.isNew = new
        file.header = ["diff --git a/\(path) b/\(path)", "--- a/\(path)", "+++ b/\(path)"]
        file.hunks = hunks.map { GitHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, section: "", lines: $0) }
        return file
    }

    private var status: GitWorkbenchStatus {
        var status = GitWorkbenchStatus()
        status.untracked = ["n1", "n2"]
        status.unstaged = [file("a"), file("ab")]
        status.staged = [file("s")]
        return status
    }

    @Test func sectionsListTheirFilesAndExpandedFilesTheirHunksAndLines() {
        let rows = GitStatusOutline.rows(status, expanded: [GitStatusOutline.FileKey(section: .unstaged, path: "a")])
        #expect(rows == [
            .section(.untracked, count: 2),
            .file(.untracked, path: "n1", diff: nil),
            .file(.untracked, path: "n2", diff: nil),
            .section(.unstaged, count: 2),
            .file(.unstaged, path: "a", diff: file("a")),
            .hunk(.unstaged, path: "a", hunk: 0),
            .line(.unstaged, path: "a", hunk: 0, line: 0),
            .line(.unstaged, path: "a", hunk: 0, line: 1),
            .file(.unstaged, path: "ab", diff: file("ab")),
            .section(.staged, count: 1),
            .file(.staged, path: "s", diff: file("s")),
        ])
        #expect(GitStatusOutline.rows(GitWorkbenchStatus(), expanded: []) == [.clean])
    }

    @Test func stageTakesExactlyTheSelectedFiles() {
        let rows = GitStatusOutline.rows(status, expanded: [])
        let picked = rows.filter { if case .file(_, let path, _) = $0 { ["n2", "a"].contains(path) } else { false } }
        #expect(GitStatusOutline.plan(.stage, picked, in: status) == .paths(["n2", "a"]))
        // Staged rows have nothing left to stage, and unstage leaves the unstaged ones alone.
        let staged = rows.filter { if case .file(.staged, _, _) = $0 { true } else { false } }
        #expect(GitStatusOutline.plan(.stage, staged, in: status) == nil)
        #expect(GitStatusOutline.plan(.unstage, picked, in: status) == nil)
        #expect(GitStatusOutline.plan(.unstage, staged, in: status) == .paths(["s"]))
    }

    @Test func aSectionRowTakesItsWholeSection() {
        #expect(GitStatusOutline.plan(.stage, [.section(.untracked, count: 2)], in: status) == .paths(["n1", "n2"]))
        #expect(GitStatusOutline.plan(.stage, [.section(.unstaged, count: 2)], in: status) == .paths(["a", "ab"]))
        #expect(GitStatusOutline.plan(.unstage, [.section(.staged, count: 1)], in: status) == .paths(["s"]))
    }

    @Test func aHunkOrLinesOfOneHunkStageOnlyThem() {
        let a = file("a", hunks: [[.init(kind: .added, text: "x")], [.init(kind: .removed, text: "y"), .init(kind: .added, text: "z")]])
        var status = status
        status.unstaged = [a]
        #expect(GitStatusOutline.plan(.stage, [.hunk(.unstaged, path: "a", hunk: 1)], in: status) == .hunk(a, hunk: 1, lines: nil))
        #expect(GitStatusOutline.plan(.stage, [.line(.unstaged, path: "a", hunk: 1, line: 1)], in: status) == .hunk(a, hunk: 1, lines: [1]))
        // Lines from two hunks can't make one patch.
        #expect(GitStatusOutline.plan(.stage, [.line(.unstaged, path: "a", hunk: 0, line: 0), .line(.unstaged, path: "a", hunk: 1, line: 1)], in: status) == nil)
        // A row that no longer matches the status (the file changed since) plans nothing.
        #expect(GitStatusOutline.plan(.stage, [.hunk(.unstaged, path: "a", hunk: 7)], in: status) == nil)
        #expect(GitStatusOutline.plan(.stage, [.hunk(.unstaged, path: "gone", hunk: 0)], in: status) == nil)
    }

    @Test func aRenameUnstagesBothItsNames() {
        var renamed = file("new")
        renamed.oldPath = "old"
        renamed.isRename = true
        var status = GitWorkbenchStatus()
        status.staged = [renamed]
        #expect(GitStatusOutline.plan(.unstage, [.file(.staged, path: "new", diff: renamed)], in: status) == .paths(["old", "new"]))
    }

    @Test func mixedRowsKeepToFiles() {
        // A file row and a hunk of another file: the whole file is chosen, so the hunk adds nothing new.
        let rows: [GitStatusRow] = [.file(.unstaged, path: "a", diff: file("a")), .hunk(.unstaged, path: "a", hunk: 0)]
        #expect(GitStatusOutline.plan(.stage, rows, in: status) == .paths(["a"]))
        let other: [GitStatusRow] = [.file(.unstaged, path: "a", diff: file("a")), .hunk(.unstaged, path: "ab", hunk: 0)]
        #expect(GitStatusOutline.plan(.stage, other, in: status) == .paths(["a", "ab"]))
    }
}
