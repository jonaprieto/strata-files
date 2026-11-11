import Foundation
@testable import StrataDev

/// A throwaway repository driven by the system's git with none of the developer's own config: no global or system
/// settings, no signing, a fixed identity. Hooks are the repository's own, so tests can install them.
struct GitFixture {
    let tree: TestTree
    let root: URL

    /// `files` are written under `repo/` and committed as the first commit unless `commit` is false.
    init(_ files: [String: String] = ["README": "hello\n"], commit: Bool = true) async throws {
        tree = try TestTree("repo/")
        root = tree.url("repo")
        try await git("init", "-q", "-b", "main")
        for (path, text) in files { try write(path, text) }
        if commit, !files.isEmpty {
            try await git("add", "-A")
            try await git("commit", "-q", "-m", "first")
        }
    }

    var repository: GitRepository { GitRepository.locate(from: root)! }

    func url(_ path: String) -> URL { root.appending(path: path) }

    func write(_ path: String, _ text: String) throws {
        let file = url(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: false, encoding: .utf8)
    }

    func text(_ path: String) -> String? { try? String(contentsOf: url(path), encoding: .utf8) }

    @discardableResult
    func git(_ arguments: String...) async throws -> String { try await git(arguments) }

    /// Runs git on a Dispatch queue, never on the main thread, which other suites' work waits on.
    @discardableResult
    func git(_ arguments: [String], allowFailure: Bool = false) async throws -> String {
        let root = root
        return try await withCheckedThrowingContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(with: Result { try Self.run(arguments, in: root, allowFailure: allowFailure) })
            }
        }
    }

    nonisolated private static func run(_ arguments: [String], in root: URL, allowFailure: Bool) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: GitRunner.executable ?? "/usr/bin/git")
        process.arguments = ["-C", root.path, "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"] + arguments
        var environment = GitWriter.isolatedEnvironment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["GIT_EDITOR"] = "false"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if !allowFailure, process.terminationStatus != 0 {
            throw FixtureError.git(arguments.joined(separator: " "), process.terminationStatus)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The index as `git ls-files -s` lists it: mode, object and path of every staged entry.
    func index() async throws -> String { try await git("ls-files", "-s") }

    /// A hook that records it ran by creating `marker` next to the repository.
    func installHook(_ name: String, marker: String) throws -> URL {
        let markerURL = tree.url(marker)
        let hook = url(".git/hooks/\(name)")
        try "#!/bin/sh\ntouch '\(markerURL.path)'\n".write(to: hook, atomically: false, encoding: .utf8)
        chmod(hook.path, 0o755)
        return markerURL
    }

    nonisolated enum FixtureError: Error { case git(String, Int32) }
}
