import AppKit
import StrataDev

/// A pane's Copy, Cut, Paste and Copy Path, through its window's clipboard and transfers.
final class ClipboardCommands {
    private weak var context: (any BrowserCommandContext)?

    init(context: any BrowserCommandContext) {
        self.context = context
    }

    func copy(_ urls: [URL]) {
        guard let context else { return }
        let copies = context.services.copies
        let clipboard = context.services.clipboard
        // A container's or a server's items are read first (folders with all they hold, shown in Transfers), then go on
        // the clipboard as a staged copy: pasting anywhere (Finder too) gets all of them as ordinary files, never a
        // half-read copy or a link written by another machine.
        let fromContainers = urls.filter(copies.contains)
        guard fromContainers.isEmpty else {
            return context.services.transfers.add(CopyFetchJob(fromContainers, copies: copies) { [weak context] in
                let task = Task {
                    let staged = await Task.detached(priority: .userInitiated) { copies.stageForClipboard(urls) }.value
                    if !staged.isEmpty { clipboard.write(staged, cut: false) }
                }
                context?.commandWork = task
            })
        }
        clipboard.write(urls, cut: false)
    }

    func cut(_ urls: [URL]) {
        context?.services.clipboard.write(urls, cut: true)
    }

    /// What's on the clipboard, copied into `directory`, or moved with `forceMove` or after a Cut. Onto a server it's
    /// copied there (what's on this Mac stays, even after Cut; a Cut on that server moves it there).
    func paste(into directory: URL, forceMove: Bool) {
        guard let context else { return }
        let clipboard = context.services.clipboard
        let (urls, isCut) = clipboard.read()
        guard !urls.isEmpty else { return }
        let onServer = context.services.remote.copies.contains(directory)
        context.transfer(urls, into: directory, move: forceMove || isCut)
        if isCut, !onServer { clipboard.clearCut() }
    }

    /// The paths of `urls`: in a container's files, the path in the container ("/etc/hosts"); a container itself, its
    /// name. On a server, the server's address and path ("deploy@web-1:/srv/app"). Never the path of Strata's copy,
    /// which is gone when it quits.
    func copyPaths(_ urls: [URL]) {
        guard let context else { return }
        let paths = urls.compactMap(context.services.copies.clipboardPath)
        guard !paths.isEmpty else { return Sounds.beep() }
        Self.write(paths, to: context.services.clipboard.pasteboard)
    }

    func copyNames(_ urls: [URL]) {
        guard let context else { return }
        let names = urls.compactMap(context.services.copies.clipboardPath).map(Self.name(ofPath:))
        guard !names.isEmpty else { return Sounds.beep() }
        Self.write(names, to: context.services.clipboard.pasteboard)
    }

    /// Paths inside each item's repository, read off the main thread (finding a repository looks at the disk). A copy
    /// made meanwhile wins: the pasteboard is written only if nothing else wrote it first. Server and container items
    /// keep the path Copy Path gives them.
    func copyRelativePaths(_ urls: [URL], folder: URL) {
        guard let context else { return }
        let copies = context.services.copies
        let pasteboard = context.services.clipboard.pasteboard
        let start = pasteboard.changeCount
        let elsewhere = urls.filter(copies.isCopy)
        let local = urls.filter { !copies.isCopy($0) }
        let elsewherePaths = elsewhere.compactMap(copies.clipboardPath)
        context.commandWork = Task {
            let relative = await Self.relativePaths(local, folder: folder)
            guard pasteboard.changeCount == start else { return }
            let all = relative + elsewherePaths
            guard !all.isEmpty else { return Sounds.beep() }
            Self.write(all, to: pasteboard)
        }
    }

    @concurrent nonisolated private static func relativePaths(_ urls: [URL], folder: URL) async -> [String] {
        let folderPath = folder.lexicallyStandardized.path
        return urls.map { url in
            relativePath(url.lexicallyStandardized.path, repositoryRoot: GitRepository.locate(from: url)?.rootPath, folder: folderPath)
        }
    }

    /// The last part of what Copy Path copies: a file's name, a container's name, the last folder of a server path.
    nonisolated static func name(ofPath path: String) -> String {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? trimmed
    }

    /// `path` inside its repository, or inside the pane's folder outside one; "." for the base itself, and the
    /// absolute path when it is under neither.
    nonisolated static func relativePath(_ path: String, repositoryRoot: String?, folder: String) -> String {
        for base in [repositoryRoot, folder].compactMap({ $0 }) {
            if let relative = GitStatusSnapshot.relativePath(path, root: base) { return relative.isEmpty ? "." : relative }
        }
        return path
    }

    private static func write(_ lines: [String], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
