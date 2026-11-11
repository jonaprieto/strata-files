import Foundation
import os

/// Intervals Instruments shows for git work (Points of Interest: subsystem dev.strata.app, category git).
package nonisolated let gitSignposts = OSSignposter(subsystem: "dev.strata.app", category: "git")

/// Runs the git commands that change a repository, for one window's environment. Only in repositories the user
/// trusts, one command at a time per repository, never prompting and never opening an editor Strata didn't name.
/// Every command that ran, succeeded or not, refreshes the repository's status.
package final class GitWriter {
    package enum Refusal: Error, Equatable {
        case gitMissing
        case untrusted
        case busy
    }

    package struct Options: Sendable {
        /// Fetch, pull and push: transports git may use.
        package var network = false
        package var environment: [String: String] = [:]
        package var timeout: TimeInterval = 120

        package init(network: Bool = false, environment: [String: String] = [:], timeout: TimeInterval = 120) {
            self.network = network
            self.environment = environment
            self.timeout = timeout
        }
    }

    package let trust: GitTrust
    package let notifications: NotificationCenter
    /// Laid over every command's environment: tests use it to keep the user's own git config out.
    private let baseEnvironment: [String: String]
    private let didRun: (GitRepository) -> Void
    private var running: Set<String> = []

    package init(trust: GitTrust, notifications: NotificationCenter, environment: [String: String] = [:],
                 didRun: @escaping (GitRepository) -> Void) {
        self.trust = trust
        self.notifications = notifications
        baseEnvironment = environment
        self.didRun = didRun
    }

    package func isRunning(in repository: GitRepository) -> Bool { running.contains(repository.rootPath) }

    /// For reading a trusted repository with its own config (its filters), as writes see it.
    package var readEnvironment: [String: String] { environment(for: Options()) }

    package func run(_ arguments: [String], in repository: GitRepository,
                     options: Options = Options()) async -> Result<GitRunResult, Refusal> {
        guard GitRunner.isAvailable else { return .failure(.gitMissing) }
        let root = repository.rootPath
        guard !running.contains(root) else { return .failure(.busy) }
        // Claimed before the trust check suspends, so a second command can't slip in meanwhile.
        running.insert(root)
        notifications.post(name: .gitWriteStateChanged, object: self, userInfo: ["root": root])
        defer {
            running.remove(root)
            notifications.post(name: .gitWriteStateChanged, object: self, userInfo: ["root": root])
        }
        guard await trust.isTrusted(repository) else { return .failure(.untrusted) }
        let interval = gitSignposts.beginInterval("git write", "\(arguments.first ?? "")")
        defer { gitSignposts.endInterval("git write", interval) }
        let result = await GitRunner.runConfigured(arguments, in: repository.root,
                                                   environment: environment(for: options), timeout: options.timeout)
        didRun(repository)
        return .success(result)
    }

    /// Strata changed working files itself (an Undo): status refreshes as after a git command.
    package func noteChanged(_ repository: GitRepository) { didRun(repository) }

    private func environment(for options: Options) -> [String: String] {
        var environment = [
            // A command that unexpectedly wants an editor fails instead of waiting for one nobody sees.
            "GIT_EDITOR": "false",
            "GIT_SEQUENCE_EDITOR": "false",
            "GIT_MERGE_AUTOEDIT": "no",
            // Hooks and filters (git-lfs, pre-commit) are usually installed by Homebrew, which a Finder launch omits.
            "PATH": (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin") + ":/opt/homebrew/bin:/usr/local/bin",
        ]
        if options.network {
            // ssh without a terminal can't ask for a passphrase or a host key: it uses the agent or fails.
            environment["GIT_ALLOW_PROTOCOL"] = "ssh:https:http:git:file"
        }
        environment.merge(baseEnvironment) { $1 }
        environment.merge(options.environment) { $1 }
        return environment
    }
}

package extension Notification.Name {
    static let gitWriteStateChanged = Notification.Name("StrataGitWriteStateChanged")
}

package extension GitWriter {
    /// Keeps a developer's own git config, signing and identity out of a test's repositories.
    nonisolated static let isolatedEnvironment: [String: String] = [
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "Strata Tests",
        "GIT_AUTHOR_EMAIL": "tests@strata.invalid",
        "GIT_COMMITTER_NAME": "Strata Tests",
        "GIT_COMMITTER_EMAIL": "tests@strata.invalid",
    ]
}
