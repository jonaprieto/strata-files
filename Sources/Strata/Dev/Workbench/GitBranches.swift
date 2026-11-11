import Foundation

package nonisolated struct GitBranch: Sendable, Equatable, Hashable {
    /// `main`, or `origin/main` for a remote one.
    package let name: String
    package let isRemote: Bool
    package let isCurrent: Bool
    package let commit: String
    package let upstream: String?

    /// For a remote branch, the local branch switching to it makes: `origin/feature/x` gives `feature/x`.
    package var localName: String {
        guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }
}

/// `git for-each-ref` with `GitBranchParser.format`, one branch a line.
package nonisolated enum GitBranchParser {
    package static let format = "--format=%(refname)%1f%(refname:short)%1f%(objectname)%1f%(upstream:short)%1f%(HEAD)"

    package static func parse(_ data: Data) -> [GitBranch] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5 else { return nil }
            let isRemote = fields[0].hasPrefix("refs/remotes/")
            // A remote's HEAD only names its default branch.
            guard !(isRemote && fields[0].hasSuffix("/HEAD")), fields[0].hasPrefix("refs/heads/") || isRemote else { return nil }
            return GitBranch(name: fields[1], isRemote: isRemote, isCurrent: fields[4] == "*", commit: fields[2],
                             upstream: fields[3].isEmpty ? nil : fields[3])
        }
    }

    /// Git's own rules for a branch name (`git check-ref-format --branch`), checked before git runs so that no name
    /// can ever be read as an option.
    package static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"), !name.hasSuffix("."),
              !name.hasSuffix(".lock"), name != "@", !name.contains(".."), !name.contains("@{"), !name.contains("//") else { return false }
        let forbidden = CharacterSet(charactersIn: " ~^:?*[\\").union(.controlCharacters)
        guard name.unicodeScalars.allSatisfy({ !forbidden.contains($0) && $0 != "\u{7f}" }) else { return false }
        return name.split(separator: "/").allSatisfy { !$0.hasPrefix(".") && !$0.hasSuffix(".lock") }
    }
}

package extension GitOutcome {
    static let invalidName = GitOutcome.failed(String(localized: "That isn’t a name git allows for a branch."))
}

extension GitWorkbench {
    package func branches() async -> [GitBranch]? {
        let run = await GitRunner.run(["for-each-ref", GitBranchParser.format, "--sort=refname", "refs/heads", "refs/remotes"],
                                      in: repository.root, timeout: 10)
        guard run.succeeded else { return nil }
        // Local branches first, each group by name.
        return GitBranchParser.parse(run.output).sorted { ($0.isRemote ? 1 : 0, $0.name) < ($1.isRemote ? 1 : 0, $1.name) }
    }

    /// A branch at HEAD, switched to with `checkout`.
    package func createBranch(_ name: String, checkout: Bool) async -> GitOutcome {
        guard GitBranchParser.isValidName(name) else { return .invalidName }
        return await run(checkout ? ["switch", "-c", name] : ["branch", "--", name])
    }

    /// Switches to a local branch. Git refuses when local changes would be overwritten, and Strata never forces it.
    package func switchBranch(_ name: String) async -> GitOutcome {
        guard GitBranchParser.isValidName(name) else { return .invalidName }
        return await run(["switch", "--no-guess", name])
    }

    /// A remote branch makes a local one of the same name that tracks it; a local branch is switched to.
    package func switchBranch(_ branch: GitBranch) async -> GitOutcome {
        guard branch.isRemote else { return await switchBranch(branch.name) }
        guard GitBranchParser.isValidName(branch.localName), GitBranchParser.isValidName(branch.name) else { return .invalidName }
        return await run(["switch", "-c", branch.localName, "--track", branch.name])
    }

    package func renameBranch(_ name: String, to newName: String) async -> GitOutcome {
        guard GitBranchParser.isValidName(name), GitBranchParser.isValidName(newName) else { return .invalidName }
        return await run(["branch", "-m", "--", name, newName])
    }

    /// Deletes a merged branch; `force` deletes one whose commits are nowhere else (they stay in the reflog). The
    /// current branch is never deleted.
    package func deleteBranch(_ name: String, force: Bool) async -> GitOutcome {
        guard GitBranchParser.isValidName(name) else { return .invalidName }
        if await currentBranch() == name {
            return .failed(String(localized: "“\(name)” is the current branch; switch to another first."))
        }
        return await run(["branch", force ? "-D" : "-d", "--", name])
    }
}
