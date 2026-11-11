import Foundation
import StrataDev

package enum GitStatusSection: Int, CaseIterable, Sendable {
    case conflicted, untracked, unstaged, staged

    var title: String {
        switch self {
        case .conflicted: String(localized: "Unmerged", comment: "Git status section: files with merge conflicts")
        case .untracked: String(localized: "Untracked", comment: "Git status section: files git doesn’t track")
        case .unstaged: String(localized: "Unstaged Changes", comment: "Git status section")
        case .staged: String(localized: "Staged Changes", comment: "Git status section")
        }
    }
}

/// One row of the status view.
package enum GitStatusRow: Equatable {
    case section(GitStatusSection, count: Int)
    /// `diff` is nil for untracked and unmerged files, which have none to show.
    case file(GitStatusSection, path: String, diff: GitFileDiff?)
    case hunk(GitStatusSection, path: String, hunk: Int)
    case line(GitStatusSection, path: String, hunk: Int, line: Int)
    /// Nothing to commit.
    case clean

    var section: GitStatusSection? {
        switch self {
        case .section(let section, _), .file(let section, _, _), .hunk(let section, _, _), .line(let section, _, _, _): section
        case .clean: nil
        }
    }

    var path: String? {
        switch self {
        case .file(_, let path, _), .hunk(_, let path, _), .line(_, let path, _, _): path
        case .section, .clean: nil
        }
    }

    /// The row without what a reload changes (a file's diff, a section's count), so a selection survives it.
    var identity: GitStatusRow {
        switch self {
        case .file(let section, let path, _): .file(section, path: path, diff: nil)
        case .section(let section, _): .section(section, count: 0)
        case .hunk, .line, .clean: self
        }
    }
}

/// What the status view shows and what its commands do with the selection, as plain functions.
enum GitStatusOutline {
    struct FileKey: Hashable {
        let section: GitStatusSection
        let path: String
    }

    enum Command { case stage, unstage }

    /// What a command does with the rows chosen.
    enum Plan: Equatable {
        case paths([String])
        /// One hunk, or only the chosen lines of it.
        case hunk(GitFileDiff, hunk: Int, lines: Set<Int>?)
    }

    static func rows(_ status: GitWorkbenchStatus, expanded: Set<FileKey>) -> [GitStatusRow] {
        guard !status.isClean else { return [.clean] }
        var rows: [GitStatusRow] = []
        func add(_ section: GitStatusSection, plain paths: [String]) {
            guard !paths.isEmpty else { return }
            rows.append(.section(section, count: paths.count))
            rows += paths.map { .file(section, path: $0, diff: nil) }
        }
        func add(_ section: GitStatusSection, diffs: [GitFileDiff]) {
            guard !diffs.isEmpty else { return }
            rows.append(.section(section, count: diffs.count))
            for diff in diffs {
                rows.append(.file(section, path: diff.path, diff: diff))
                guard expanded.contains(FileKey(section: section, path: diff.path)) else { continue }
                for (hunkIndex, hunk) in diff.hunks.enumerated() {
                    rows.append(.hunk(section, path: diff.path, hunk: hunkIndex))
                    rows += hunk.lines.indices.map { .line(section, path: diff.path, hunk: hunkIndex, line: $0) }
                }
            }
        }
        add(.conflicted, plain: status.conflicted)
        add(.untracked, plain: status.untracked)
        add(.unstaged, diffs: status.unstaged)
        add(.staged, diffs: status.staged)
        return rows
    }

    /// Staging takes untracked and unstaged rows; unstaging takes staged ones. Whole files win over parts of them;
    /// parts only when they all belong to one hunk of one file. Rows that no longer match `status` plan nothing.
    static func plan(_ command: Command, _ rows: [GitStatusRow], in status: GitWorkbenchStatus) -> Plan? {
        let sections: Set<GitStatusSection> = command == .stage ? [.untracked, .unstaged, .conflicted] : [.staged]
        let chosen = rows.filter { $0.section.map(sections.contains) ?? false }
        guard !chosen.isEmpty else { return nil }
        var paths: [String] = []
        func add(_ more: [String]) { for path in more where !paths.contains(path) { paths.append(path) } }
        var parts: [(path: String, section: GitStatusSection, hunk: Int, line: Int?)] = []
        for row in chosen {
            switch row {
            case .section(let section, _): add(files(in: section, of: status).flatMap(names))
            case .file(let section, let path, _):
                if let diff = diff(path, section, status) { add(names(diff)) } else if plain(section, status).contains(path) { add([path]) }
            case .hunk(let section, let path, let hunk): parts.append((path, section, hunk, nil))
            case .line(let section, let path, let hunk, let line): parts.append((path, section, hunk, line))
            case .clean: break
            }
        }
        // Parts of a file already chosen whole add nothing; parts of other files become those whole files.
        let loose = parts.filter { !paths.contains($0.path) }
        if !paths.isEmpty {
            for part in loose { if let diff = diff(part.path, part.section, status) { add(names(diff)) } }
            return .paths(paths)
        }
        guard let first = loose.first, loose.allSatisfy({ $0.path == first.path && $0.hunk == first.hunk && $0.section == first.section }),
              let diff = diff(first.path, first.section, status), diff.hunks.indices.contains(first.hunk) else { return nil }
        if loose.contains(where: { $0.line == nil }) { return .hunk(diff, hunk: first.hunk, lines: nil) }
        let lines = Set(loose.compactMap(\.line)).filter { diff.hunks[first.hunk].lines.indices.contains($0) }
        let changes = lines.filter { [.added, .removed].contains(diff.hunks[first.hunk].lines[$0].kind) }
        return changes.isEmpty ? nil : .hunk(diff, hunk: first.hunk, lines: changes)
    }

    private static func diff(_ path: String, _ section: GitStatusSection, _ status: GitWorkbenchStatus) -> GitFileDiff? {
        let diffs = section == .staged ? status.staged : section == .unstaged ? status.unstaged : []
        return diffs.first { $0.path == path }
    }

    private static func plain(_ section: GitStatusSection, _ status: GitWorkbenchStatus) -> [String] {
        section == .untracked ? status.untracked : section == .conflicted ? status.conflicted : []
    }

    private static func files(in section: GitStatusSection, of status: GitWorkbenchStatus) -> [GitFileDiff] {
        switch section {
        case .staged: status.staged
        case .unstaged: status.unstaged
        case .untracked, .conflicted:
            plain(section, status).map { path in
                var file = GitFileDiff()
                file.newPath = path
                return file
            }
        }
    }

    /// Both names of a rename, so it leaves the index as a whole.
    private static func names(_ diff: GitFileDiff) -> [String] {
        [diff.oldPath, diff.newPath].compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }
}
