import Foundation

/// One file's part of a `git diff`: the header lines git wrote, and its hunks.
package nonisolated struct GitFileDiff: Sendable, Equatable {
    /// Nil for a new file.
    package var oldPath: String?
    /// Nil for a deleted file.
    package var newPath: String?
    package var oldMode: String?
    package var newMode: String?
    package var isNew = false
    package var isDeleted = false
    package var isRename = false
    package var isBinary = false
    /// From `diff --git` through `+++`, verbatim: a patch repeats them.
    package var header: [String] = []
    package var hunks: [GitHunk] = []

    package init() {}

    package var path: String { newPath ?? oldPath ?? "" }

    /// Hunks and lines can be staged on their own only in a file that exists on both sides as text: a new or deleted
    /// file, or a binary one, changes as a whole.
    package var allowsPartialStaging: Bool { !isNew && !isDeleted && !isBinary && !hunks.isEmpty }
}

package nonisolated struct GitHunk: Sendable, Equatable {
    package var oldStart: Int
    package var oldCount: Int
    package var newStart: Int
    package var newCount: Int
    /// What git shows after the second `@@`: usually the enclosing function.
    package var section: String
    package var lines: [GitDiffLine]

    package init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String, lines: [GitDiffLine]) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.section = section
        self.lines = lines
    }
}

package nonisolated struct GitDiffLine: Sendable, Equatable {
    package enum Kind: Sendable, Equatable { case context, added, removed, noNewline }
    package var kind: Kind
    /// Without its leading `+`, `-` or space.
    package var text: String

    package init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Reads `git diff --no-color --no-ext-diff` output. Anything it can't read exactly is left out rather than guessed:
/// a hunk whose lines don't add up to its header would build a wrong patch.
package nonisolated enum GitDiffParser {
    /// Larger hunks are refused: no real diff has them, and counts beyond this are a malformed or hostile header.
    static let maximumCount = 10_000_000

    package static func parse(_ data: Data) -> [GitFileDiff] {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        var files: [GitFileDiff] = []
        var index = 0
        while index < lines.count {
            guard lines[index].hasPrefix("diff --git ") else { index += 1; continue }
            var file = GitFileDiff()
            file.header.append(lines[index])
            index += 1
            readHeader(&file, lines, &index)
            readHunks(&file, lines, &index)
            files.append(file)
        }
        return files
    }

    private static func readHeader(_ file: inout GitFileDiff, _ lines: [String], _ index: inout Int) {
        while index < lines.count, !lines[index].hasPrefix("diff --git "), !lines[index].hasPrefix("@@") {
            let line = lines[index]
            file.header.append(line)
            index += 1
            if line.hasPrefix("new file mode ") {
                file.isNew = true
                file.newMode = String(line.dropFirst("new file mode ".count))
            } else if line.hasPrefix("deleted file mode ") {
                file.isDeleted = true
                file.oldMode = String(line.dropFirst("deleted file mode ".count))
            } else if line.hasPrefix("old mode ") {
                file.oldMode = String(line.dropFirst("old mode ".count))
            } else if line.hasPrefix("new mode ") {
                file.newMode = String(line.dropFirst("new mode ".count))
            } else if line.hasPrefix("rename from ") {
                file.isRename = true
                file.oldPath = unquote(String(line.dropFirst("rename from ".count)))
            } else if line.hasPrefix("rename to ") {
                file.newPath = unquote(String(line.dropFirst("rename to ".count)))
            } else if line.hasPrefix("--- ") {
                file.oldPath = side(String(line.dropFirst(4)), prefix: "a/")
            } else if line.hasPrefix("+++ ") {
                file.newPath = side(String(line.dropFirst(4)), prefix: "b/")
            } else if line.hasPrefix("Binary files ") {
                file.isBinary = true
            }
        }
        // A diff with no ---/+++ (binary, a mode or a pure rename) names its paths only on its first line.
        if file.oldPath == nil, file.newPath == nil, let paths = gitLinePaths(file.header[0]) {
            file.oldPath = file.isNew ? nil : paths.old
            file.newPath = file.isDeleted ? nil : paths.new
        }
        if file.isNew { file.oldPath = nil }
        if file.isDeleted { file.newPath = nil }
    }

    private static func readHunks(_ file: inout GitFileDiff, _ lines: [String], _ index: inout Int) {
        while index < lines.count, lines[index].hasPrefix("@@") {
            guard var hunk = hunkHeader(lines[index]) else {
                // Skip to the next file: nothing after a header that doesn't parse can be placed.
                file.hunks = []
                while index < lines.count, !lines[index].hasPrefix("diff --git ") { index += 1 }
                return
            }
            index += 1
            var old = 0, new = 0
            while index < lines.count, old < hunk.oldCount || new < hunk.newCount || lines[index].hasPrefix("\\") {
                let line = lines[index]
                guard let first = line.first, " -+\\".contains(first) else { break }
                let rest = String(line.dropFirst())
                switch first {
                case " ": hunk.lines.append(.init(kind: .context, text: rest)); old += 1; new += 1
                case "-": hunk.lines.append(.init(kind: .removed, text: rest)); old += 1
                case "+": hunk.lines.append(.init(kind: .added, text: rest)); new += 1
                default: hunk.lines.append(.init(kind: .noNewline, text: rest))
                }
                index += 1
            }
            guard old == hunk.oldCount, new == hunk.newCount else {
                file.hunks = []
                while index < lines.count, !lines[index].hasPrefix("diff --git ") { index += 1 }
                return
            }
            file.hunks.append(hunk)
        }
    }

    /// `@@ -a,b +c,d @@ section`; a count left out is one.
    static func hunkHeader(_ line: String) -> GitHunk? {
        let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[0] == "@@", parts[3] == "@@",
              parts[1].hasPrefix("-"), parts[2].hasPrefix("+"),
              let old = range(parts[1].dropFirst()), let new = range(parts[2].dropFirst()) else { return nil }
        let section = parts.count > 4 ? String(parts[4]) : ""
        return GitHunk(oldStart: old.start, oldCount: old.count, newStart: new.start, newCount: new.count,
                       section: section, lines: [])
    }

    private static func range(_ text: Substring) -> (start: Int, count: Int)? {
        let numbers = text.split(separator: ",", omittingEmptySubsequences: false)
        guard numbers.count == 1 || numbers.count == 2,
              let start = Int(numbers[0]), start >= 0, start <= maximumCount else { return nil }
        guard numbers.count == 2 else { return (start, 1) }
        guard let count = Int(numbers[1]), count >= 0, count <= maximumCount else { return nil }
        return (start, count)
    }

    /// `a/path`, `"a/quoted"` or `/dev/null`.
    private static func side(_ text: String, prefix: String) -> String? {
        guard text != "/dev/null" else { return nil }
        let path = unquote(text)
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// The paths in `diff --git a/x b/x`. Unquoted names with spaces are ambiguous; git writes both sides alike
    /// unless the file was renamed, which also names them in `rename from/to`.
    private static func gitLinePaths(_ line: String) -> (old: String, new: String)? {
        let rest = String(line.dropFirst("diff --git ".count))
        if rest.hasPrefix("\"") {
            let parts = quotedParts(rest)
            guard parts.count == 2 else { return nil }
            return (String(parts[0].dropFirst(2)), String(parts[1].dropFirst(2)))
        }
        // Equal halves: "a/x b/x".
        let half = (rest.count - 1) / 2
        let old = String(rest.prefix(half)), new = String(rest.suffix(half))
        guard old.hasPrefix("a/"), new.hasPrefix("b/"), old.dropFirst(2) == new.dropFirst(2) else { return nil }
        return (String(old.dropFirst(2)), String(new.dropFirst(2)))
    }

    private static func quotedParts(_ text: String) -> [String] {
        var parts: [String] = []
        var rest = Substring(text)
        while let start = rest.firstIndex(of: "\"") {
            var end = rest.index(after: start)
            var escaped = false
            while end < rest.endIndex {
                if escaped { escaped = false } else if rest[end] == "\\" { escaped = true } else if rest[end] == "\"" { break }
                end = rest.index(after: end)
            }
            guard end < rest.endIndex else { break }
            parts.append(unquote(String(rest[start...end])))
            rest = rest[rest.index(after: end)...]
        }
        return parts
    }

    /// Git's C-style quoting of unusual names: `"tab\there"`, octal escapes for other bytes.
    package static func unquote(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        var bytes: [UInt8] = []
        let inner = Array(text.utf8.dropFirst().dropLast())
        var index = 0
        while index < inner.count {
            let byte = inner[index]
            guard byte == UInt8(ascii: "\\"), index + 1 < inner.count else { bytes.append(byte); index += 1; continue }
            let next = inner[index + 1]
            switch next {
            case UInt8(ascii: "n"): bytes.append(10); index += 2
            case UInt8(ascii: "t"): bytes.append(9); index += 2
            case UInt8(ascii: "r"): bytes.append(13); index += 2
            case UInt8(ascii: "a"): bytes.append(7); index += 2
            case UInt8(ascii: "b"): bytes.append(8); index += 2
            case UInt8(ascii: "f"): bytes.append(12); index += 2
            case UInt8(ascii: "v"): bytes.append(11); index += 2
            case UInt8(ascii: "0")...UInt8(ascii: "7") where index + 3 < inner.count:
                let digits = inner[(index + 1)...(index + 3)]
                if digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "7")).contains($0) }),
                   let value = UInt8(String(decoding: digits, as: UTF8.self), radix: 8) {
                    bytes.append(value)
                    index += 4
                } else {
                    bytes.append(next)
                    index += 2
                }
            default: bytes.append(next); index += 2
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Patches that stage or unstage part of a file with `git apply --cached` (unstaging adds `--reverse`).
package nonisolated enum GitPatch {
    /// The file's header and one hunk, or only the chosen `lines` of it (indexes into `hunk.lines`). Lines left out
    /// stay as they are on the side being changed: when staging, a left-out removal becomes context and a left-out
    /// addition is dropped; when unstaging (`reverse`), the other way round. Nil when nothing would change.
    package static func make(_ file: GitFileDiff, hunk index: Int, lines chosen: Set<Int>? = nil,
                             reverse: Bool = false) -> String? {
        guard file.hunks.indices.contains(index), !file.header.isEmpty else { return nil }
        let hunk = file.hunks[index]
        var body: [String] = []
        var old = 0, new = 0, changes = 0
        var keptPrevious = true
        for (position, line) in hunk.lines.enumerated() {
            let isChosen = chosen?.contains(position) ?? true
            switch line.kind {
            case .context:
                body.append(" " + line.text); old += 1; new += 1; keptPrevious = true
            case .added where isChosen:
                body.append("+" + line.text); new += 1; changes += 1; keptPrevious = true
            case .removed where isChosen:
                body.append("-" + line.text); old += 1; changes += 1; keptPrevious = true
            case .added:
                // Staging: not in the index yet, so it isn't there. Unstaging: still in the index, so it's context.
                if reverse { body.append(" " + line.text); old += 1; new += 1; keptPrevious = true } else { keptPrevious = false }
            case .removed:
                if reverse { keptPrevious = false } else { body.append(" " + line.text); old += 1; new += 1; keptPrevious = true }
            case .noNewline:
                // Belongs to the line before it, and goes only where that line went.
                if keptPrevious { body.append("\\" + line.text) }
            }
        }
        guard changes > 0 else { return nil }
        // The patch is applied to the index: the old side when staging, the new side when reversed to unstage.
        let start = reverse ? hunk.newStart : hunk.oldStart
        let header = "@@ -\(start),\(old) +\(start),\(new) @@"
        return (file.header + [header] + body).joined(separator: "\n") + "\n"
    }
}
