import Foundation
import Testing
@testable import StrataDev

/// The log, read from git's output, and the lanes its graph is drawn in.
@Suite struct GitLogTests {
    private func commit(_ id: String, _ parents: String...) -> GitCommit {
        GitCommit(id: id, parents: parents, author: "A", email: "a@a", date: Date(timeIntervalSince1970: 0), refs: [], subject: id)
    }

    /// A commit's files from `--name-status -z`: one path, or two for a rename or copy; names with spaces and
    /// newlines are read whole, and a truncated record is dropped.
    @Test func aCommitsFilesAreReadWithHowTheyChanged() {
        let output = ["M", "a", "A", "new file", "D", "gone\nline", "R087", "old", "sub/renamed", "C100", "src", "copy", "R100", "cut"]
            .joined(separator: "\0") + "\0"
        let files = GitNameStatus.parse(Data(output.utf8))
        #expect(files.map(\.path) == ["a", "new file", "gone\nline", "sub/renamed", "copy"])
        #expect(files.map(\.isNew) == [false, true, false, false, false])
        #expect(files.map(\.isDeleted) == [false, false, true, false, false])
        #expect(files.map(\.isRename) == [false, false, false, true, false])
        #expect(files[3].oldPath == "old" && files[1].oldPath == nil && files[2].newPath == nil)
        #expect(GitNameStatus.parse(Data()).isEmpty)
    }

    @Test func recordsAreReadFieldByField() {
        let record = ["1111", "2222 3333", "Ana", "ana@x", "1700000000", "HEAD -> main, origin/main, tag: v1", "Fix it"]
            .joined(separator: "\u{1f}") + "\u{1e}\n"
        let bad = "only\u{1f}two\u{1e}\n"
        let commits = GitLogParser.parse(Data((record + bad).utf8))
        #expect(commits.count == 1)
        let first = commits[0]
        #expect(first.id == "1111" && first.parents == ["2222", "3333"] && first.isMerge)
        #expect(first.author == "Ana" && first.subject == "Fix it")
        #expect(first.date == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(first.refs == ["HEAD -> main", "origin/main", "tag: v1"])
        #expect(first.shortID == "1111")
        #expect(GitLogParser.parse(Data()).isEmpty)
    }

    @Test func aLinearHistoryIsOneLane() {
        let rows = GitGraph.layout([commit("c", "b"), commit("b", "a"), commit("a")])
        #expect(rows.map(\.node) == [0, 0, 0])
        #expect(rows.map(\.width) == [1, 1, 1])
        #expect(rows[0].incoming == [] && rows[0].outgoing == [0])
        #expect(rows[1].incoming == [0] && rows[1].outgoing == [0])
        #expect(rows[2].incoming == [0] && rows[2].outgoing == [])
    }

    @Test func aBranchAndItsMerge() {
        let rows = GitGraph.layout([commit("m", "b", "c"), commit("b", "a"), commit("c", "a"), commit("a")])
        #expect(rows[0] == GitGraphRow(node: 0, incoming: [], outgoing: [0, 1], passing: [], width: 2))
        #expect(rows[1] == GitGraphRow(node: 0, incoming: [0], outgoing: [0], passing: [1], width: 2))
        #expect(rows[2] == GitGraphRow(node: 1, incoming: [1], outgoing: [1], passing: [0], width: 2))
        // Both lanes end at the commit they share.
        #expect(rows[3] == GitGraphRow(node: 0, incoming: [0, 1], outgoing: [], passing: [], width: 2))
    }

    @Test func anOctopusMergeOpensALanePerParent() {
        let rows = GitGraph.layout([commit("m", "a", "b", "c"), commit("a"), commit("b"), commit("c")])
        #expect(rows[0].outgoing == [0, 1, 2])
        #expect(rows.map(\.node) == [0, 0, 1, 2])
        #expect(rows[3].passing == [])
    }

    @Test func twoTipsStartTwoLanes() {
        // `git log --all`: a second branch's tip appears with no lane waiting for it.
        let rows = GitGraph.layout([commit("x", "a"), commit("y", "a"), commit("a")])
        #expect(rows.map(\.node) == [0, 1, 0])
        #expect(rows[1].passing == [0])
        #expect(rows[2].incoming == [0, 1])
    }

    @Test func aParentMissingFromThePageLeavesItsLaneOpen() {
        // A page of 2 commits whose last has a parent further down: the lane runs off the bottom.
        let rows = GitGraph.layout([commit("b", "a"), commit("a", "z")])
        #expect(rows[1].outgoing == [0])
        #expect(rows.count == 2)
    }
}
