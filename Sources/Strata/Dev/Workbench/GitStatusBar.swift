import Foundation

extension GitStatusSnapshot {
    /// The status bar's part for a repository: "main ↑1 ↓2 · 2 staged · 3 modified · 1 untracked", or
    /// "main · No changes". From what was read already, so drawing it never waits on git.
    package var statusBarText: String { Self.statusBarText(branch: branch, operation: operation, counts: counts) }

    package static func statusBarText(branch: GitBranchInfo, operation: GitOperation?, counts: GitStatusCounts) -> String {
        var head = branch.displayName
        if branch.upstream != nil {
            if branch.ahead > 0 { head += " ↑\(branch.ahead)" }
            if branch.behind > 0 { head += " ↓\(branch.behind)" }
        }
        var parts = [head]
        if let operation { parts.append(operation.title) }
        if counts.staged > 0 { parts.append(String(localized: "\(counts.staged) staged", comment: "plural")) }
        parts.append(counts.summary)
        return parts.joined(separator: " · ")
    }
}
