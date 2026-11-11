import Foundation

/// Fetch, pull and push: the only commands that may use a transport, with the user's own ssh agent and credential
/// helpers and never a prompt. Pull only fast-forwards unless asked to rebase, and push never forces except with a
/// lease on what was last fetched.
extension GitWorkbench {
    private static let network = GitWriter.Options(network: true, timeout: 300)

    package func remotes() async -> [String] {
        let run = await GitRunner.run(["remote"], in: repository.root, timeout: 10)
        return String(decoding: run.output, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// The current branch's remote (or origin), or every remote with `all`; branches gone from the remote go too.
    package func fetch(all: Bool) async -> GitOutcome {
        await run(["fetch", "--prune", "--no-recurse-submodules"] + (all ? ["--all"] : []), options: Self.network)
    }

    package func pull(rebase: Bool) async -> GitOutcome {
        await run(["pull", "--no-recurse-submodules"] + (rebase ? ["--rebase"] : ["--ff-only"]), options: Self.network)
    }

    /// Pushes the current branch to its upstream, or to `remote` and makes that its upstream. `force` replaces the
    /// remote branch only if it still is what this repository last fetched.
    package func push(force: Bool, settingUpstreamOn remote: String? = nil) async -> GitOutcome {
        var arguments = ["push"] + (force ? ["--force-with-lease"] : [])
        if let remote {
            guard GitBranchParser.isValidName(remote) else { return .invalidName }
            arguments += ["--set-upstream", remote, "HEAD"]
        }
        return await run(arguments, options: Self.network)
    }
}
