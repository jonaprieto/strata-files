import Foundation
import Testing
@testable import StrataDev

/// Patches for staging part of a file: applied with `git apply --cached`, they change exactly the chosen lines.
@Suite struct GitPatchTests {
    private static let ten = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"

    /// A repository whose `a.txt` has two separate changes, line 2 and line 9, not yet staged.
    private func twoChanges() async throws -> GitFixture {
        let repo = try await GitFixture(["a.txt": Self.ten])
        try repo.write("a.txt", Self.ten.replacingOccurrences(of: "line 2\n", with: "LINE 2\n")
            .replacingOccurrences(of: "line 9\n", with: "LINE 9\nextra\n"))
        return repo
    }

    private func diff(_ repo: GitFixture, cached: Bool = false) async throws -> GitFileDiff {
        let output = try await repo.git(["diff", "--no-color", "--no-ext-diff", "-U1"] + (cached ? ["--cached"] : []))
        return try #require(GitDiffParser.parse(Data(output.utf8)).first)
    }

    private func apply(_ patch: String?, _ repo: GitFixture, reverse: Bool = false) async throws {
        let patch = try #require(patch)
        let file = repo.tree.url("change.patch")
        try patch.write(to: file, atomically: false, encoding: .utf8)
        try await repo.git(["apply", "--cached"] + (reverse ? ["--reverse"] : []) + [file.path])
    }

    private func staged(_ repo: GitFixture) async throws -> String { try await repo.git("show", ":a.txt") }

    @Test func stagingOneHunkLeavesTheOther() async throws {
        let repo = try await twoChanges()
        let file = try await diff(repo)
        #expect(file.hunks.count == 2)

        try await apply(GitPatch.make(file, hunk: 0), repo)
        #expect(try await staged(repo) == Self.ten.replacingOccurrences(of: "line 2\n", with: "LINE 2\n"))
        // The working file is never touched.
        #expect(repo.text("a.txt")?.contains("extra") == true)
    }

    @Test func stagingChosenLinesOfAHunk() async throws {
        let repo = try await twoChanges()
        let file = try await diff(repo)
        let hunk = file.hunks[1]
        // Only "+extra", not the replacement of line 9.
        let extra = try #require(hunk.lines.firstIndex { $0.kind == .added && $0.text == "extra" })

        try await apply(GitPatch.make(file, hunk: 1, lines: [extra]), repo)
        #expect(try await staged(repo) == Self.ten.replacingOccurrences(of: "line 9\n", with: "line 9\nextra\n"))
    }

    @Test func unstagingOneHunkOrChosenLines() async throws {
        let repo = try await twoChanges()
        try await repo.git("add", "a.txt")
        let file = try await diff(repo, cached: true)

        try await apply(GitPatch.make(file, hunk: 0, reverse: true), repo, reverse: true)
        #expect(try await staged(repo) == Self.ten.replacingOccurrences(of: "line 9\n", with: "LINE 9\nextra\n"))

        let after = try await diff(repo, cached: true)
        let extra = try #require(after.hunks[0].lines.firstIndex { $0.kind == .added && $0.text == "extra" })
        try await apply(GitPatch.make(after, hunk: 0, lines: [extra], reverse: true), repo, reverse: true)
        #expect(try await staged(repo) == Self.ten.replacingOccurrences(of: "line 9\n", with: "LINE 9\n"))
    }

    @Test func choosingARemovedLineKeepsTheAddedOneOut() async throws {
        let repo = try await twoChanges()
        let file = try await diff(repo)
        let removed = try #require(file.hunks[0].lines.firstIndex { $0.kind == .removed })

        try await apply(GitPatch.make(file, hunk: 0, lines: [removed]), repo)
        #expect(try await staged(repo) == Self.ten.replacingOccurrences(of: "line 2\n", with: ""))
    }

    @Test func aFileWithoutATrailingNewline() async throws {
        let repo = try await GitFixture(["a.txt": "a\nb"])
        try repo.write("a.txt", "A\nb\nc")
        let file = try await diff(repo)
        try await apply(GitPatch.make(file, hunk: 0), repo)
        #expect(try await staged(repo) == "A\nb\nc")
    }

    @Test func partsOfFilesThatCanOnlyChangeWhole() {
        var file = GitFileDiff()
        file.newPath = "n"
        file.header = ["diff --git a/n b/n", "--- a/n", "+++ b/n"]
        #expect(!file.allowsPartialStaging)
        file.hunks = [GitHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, section: "",
                              lines: [.init(kind: .removed, text: "a"), .init(kind: .added, text: "b")])]
        #expect(file.allowsPartialStaging)
        file.isNew = true
        #expect(!file.allowsPartialStaging)
        file.isNew = false
        file.isBinary = true
        #expect(!file.allowsPartialStaging)
        // Choosing nothing in a hunk is no patch at all.
        file.isBinary = false
        #expect(GitPatch.make(file, hunk: 0) != nil)
        #expect(GitPatch.make(file, hunk: 0, lines: []) == nil)
        #expect(GitPatch.make(file, hunk: 5) == nil)
    }
}
