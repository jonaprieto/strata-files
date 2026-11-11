import Foundation
import Testing
@testable import StrataDev

/// `git diff` output, read into files, hunks and lines without trusting its shape.
@Suite struct GitDiffParserTests {
    private func parse(_ text: String) -> [GitFileDiff] { GitDiffParser.parse(Data(text.utf8)) }

    @Test func aModifiedFileWithTwoHunks() throws {
        let files = parse("""
            diff --git a/a.txt b/a.txt
            index 1111111..2222222 100644
            --- a/a.txt
            +++ b/a.txt
            @@ -1,3 +1,3 @@ first
             one
            -two
            +TWO
             three
            @@ -10 +10,2 @@
             ten
            +eleven

            """)
        let file = try #require(files.first)
        #expect(files.count == 1)
        #expect(file.oldPath == "a.txt" && file.newPath == "a.txt" && file.path == "a.txt")
        #expect(!file.isBinary && !file.isNew && !file.isDeleted)
        #expect(file.hunks.count == 2)
        let first = file.hunks[0]
        #expect((first.oldStart, first.oldCount, first.newStart, first.newCount) == (1, 3, 1, 3))
        #expect(first.section == "first")
        #expect(first.lines.map(\.kind) == [.context, .removed, .added, .context])
        #expect(first.lines.map(\.text) == ["one", "two", "TWO", "three"])
        // A count left out means one line.
        let second = file.hunks[1]
        #expect((second.oldStart, second.oldCount, second.newStart, second.newCount) == (10, 1, 10, 2))
        #expect(file.header.first == "diff --git a/a.txt b/a.txt" && file.header.last == "+++ b/a.txt")
    }

    @Test func newDeletedRenamedAndModeChangedFiles() {
        let files = parse("""
            diff --git a/new.txt b/new.txt
            new file mode 100644
            index 0000000..3333333
            --- /dev/null
            +++ b/new.txt
            @@ -0,0 +1 @@
            +hi
            diff --git a/gone.txt b/gone.txt
            deleted file mode 100644
            index 4444444..0000000
            --- a/gone.txt
            +++ /dev/null
            @@ -1 +0,0 @@
            -bye
            diff --git a/old name.txt b/new name.txt
            similarity index 100%
            rename from old name.txt
            rename to new name.txt
            diff --git a/run.sh b/run.sh
            old mode 100644
            new mode 100755

            """)
        #expect(files.count == 4)
        #expect(files[0].isNew && files[0].oldPath == nil && files[0].newPath == "new.txt")
        #expect(files[1].isDeleted && files[1].newPath == nil && files[1].path == "gone.txt")
        #expect(files[2].oldPath == "old name.txt" && files[2].newPath == "new name.txt" && files[2].isRename)
        #expect(files[2].hunks.isEmpty)
        #expect(files[3].oldMode == "100644" && files[3].newMode == "100755" && files[3].hunks.isEmpty)
    }

    @Test func binaryFilesAndMissingTrailingNewlines() {
        let files = parse("""
            diff --git a/i.png b/i.png
            index 5555555..6666666 100644
            Binary files a/i.png and b/i.png differ
            diff --git a/n.txt b/n.txt
            index 7777777..8888888 100644
            --- a/n.txt
            +++ b/n.txt
            @@ -1 +1 @@
            -a
            \\ No newline at end of file
            +b
            \\ No newline at end of file

            """)
        #expect(files.count == 2)
        #expect(files[0].isBinary && files[0].path == "i.png" && files[0].hunks.isEmpty)
        #expect(files[1].hunks[0].lines.map(\.kind) == [.removed, .noNewline, .added, .noNewline])
    }

    @Test func quotedPathsAreUnquoted() {
        let files = parse("""
            diff --git "a/tab\\there.txt" "b/tab\\there.txt"
            index 1111111..2222222 100644
            --- "a/tab\\there.txt"
            +++ "b/tab\\there.txt"
            @@ -1 +1 @@
            -x
            +y

            """)
        #expect(files.first?.path == "tab\there.txt")
    }

    @Test func malformedAndTruncatedInputNeverMisreadsLines() {
        // A hunk header that doesn't parse ends the file: its lines aren't attached to a guess.
        let bad = parse("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ nonsense @@\n+x\n")
        #expect(bad.first?.hunks.isEmpty == true)
        // Fewer lines than the header promises: the hunk is dropped, since a patch built from it would be wrong.
        let short = parse("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,3 +1,3 @@\n one\n")
        #expect(short.first?.hunks.isEmpty == true)
        #expect(parse("").isEmpty)
        #expect(parse("garbage\n\0\u{1}").isEmpty)
        // Huge counts are refused rather than trusted.
        let huge = parse("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,99999999999999999999 +1 @@\n x\n")
        #expect(huge.first?.hunks.isEmpty == true)
    }
}
