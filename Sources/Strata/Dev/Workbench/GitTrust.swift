import Foundation

/// Repositories whose own hooks, filters and config the user agreed to run. Strata only reads a repository it isn't
/// trusted with, and refuses every git command that would change it. A repository is trusted by its folder's
/// identity as well as its path, so a different repository moved to the same path is a stranger.
package final class GitTrust {
    package struct Entry: Equatable, Sendable {
        package let path: String
        package let identity: String
    }

    private static let key = "gitTrustedRepositories"
    private let defaults: UserDefaults
    package let notifications: NotificationCenter

    package init(defaults: UserDefaults, notifications: NotificationCenter) {
        self.defaults = defaults
        self.notifications = notifications
    }

    package var entries: [Entry] {
        (defaults.array(forKey: Self.key) as? [[String: String]] ?? []).compactMap { record in
            guard let path = record["path"], let identity = record["identity"], !path.isEmpty, !identity.isEmpty else { return nil }
            return Entry(path: path, identity: identity)
        }
    }

    /// Whether `repository` is the one the user trusted at its path. Reads the folder's identity off the main thread.
    package func isTrusted(_ repository: GitRepository) async -> Bool {
        let path = repository.rootPath
        guard let entry = entries.first(where: { $0.path == path }) else { return false }
        return await Self.identity(of: path) == entry.identity
    }

    /// Trusts `repository` as it is now. False when its folder can't be read.
    @discardableResult
    package func trust(_ repository: GitRepository) async -> Bool {
        let path = repository.rootPath
        guard let identity = await Self.identity(of: path) else { return false }
        save(entries.filter { $0.path != path } + [Entry(path: path, identity: identity)])
        return true
    }

    package func revoke(path: String) {
        save(entries.filter { $0.path != path })
    }

    private func save(_ entries: [Entry]) {
        defaults.set(entries.map { ["path": $0.path, "identity": $0.identity] }, forKey: Self.key)
        notifications.post(name: .gitTrustChanged, object: self)
    }

    @concurrent nonisolated private static func identity(of path: String) async -> String? {
        FileIdentity.historyKey(at: path)
    }
}

package extension Notification.Name {
    static let gitTrustChanged = Notification.Name("StrataGitTrustChanged")
}

/// What a repository makes git run on its own: the hooks it would call and the filter drivers and file monitor its
/// config names. Shown before the user trusts it.
package nonisolated struct GitAutomation: Equatable, Sendable {
    package var hooks: [String] = []
    package var filters: [String] = []
    package var fileMonitor: String?

    package var isEmpty: Bool { hooks.isEmpty && filters.isEmpty && fileMonitor == nil }

    /// Reads it with the hardened runner, which runs none of it.
    @concurrent
    package static func read(_ repository: GitRepository, timeout: TimeInterval = 10) async -> GitAutomation {
        let run = await GitRunner.run(["config", "--includes", "--show-scope", "-z", "--get-regexp",
                                       #"^(filter\..*\.(clean|smudge|process)|core\.(hookspath|fsmonitor))$"#],
                                      in: repository.root, timeout: timeout)
        var automation = parse(config: run.succeeded ? run.output : Data())
        let hooksFolder = automation.hooksPath.map { path -> URL in
            path.hasPrefix("/") ? URL(fileURLWithPath: path) : repository.root.appending(path: path)
        } ?? repository.gitDirectory.appending(path: "hooks")
        automation.parsed.hooks = hooks(in: hooksFolder)
        return automation.parsed
    }

    /// `git config --show-scope -z --get-regexp` output: `scope\0key\nvalue\0` pairs. The runner's own `-c` settings
    /// (scope `command`) are its hardening, not the repository's.
    package static func parse(config: Data) -> (parsed: GitAutomation, hooksPath: String?) {
        var automation = GitAutomation()
        var hooksPath: String?
        var drivers = Set<String>()
        let fields = config.split(separator: 0, omittingEmptySubsequences: false)
        for index in stride(from: 0, to: fields.count - 1, by: 2) {
            guard String(decoding: fields[index], as: UTF8.self) != "command" else { continue }
            let text = String(decoding: fields[index + 1], as: UTF8.self)
            let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts.first.map(String.init) ?? ""
            let value = parts.count > 1 ? String(parts[1]) : ""
            switch key.lowercased() {
            case "core.hookspath": hooksPath = value
            case "core.fsmonitor":
                let off = ["", "false", "0", "no", "off"].contains(value.lowercased())
                automation.fileMonitor = off ? nil : value
            default:
                guard key.hasPrefix("filter."), let dot = key.lastIndex(of: "."), !value.isEmpty else { continue }
                drivers.insert(String(key[key.index(key.startIndex, offsetBy: "filter.".count)..<dot]))
            }
        }
        automation.filters = drivers.sorted()
        return (automation, hooksPath)
    }

    /// Executable files in `folder`, not git's `.sample` examples.
    package static func hooks(in folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { name in
            guard !name.hasSuffix(".sample"), !name.hasPrefix(".") else { return false }
            var info = stat()
            let path = folder.appending(path: name).path
            return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && access(path, X_OK) == 0
        }.sorted()
    }
}
