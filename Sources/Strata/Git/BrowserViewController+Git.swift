import AppKit
import StrataDev

/// The git status view over a pane's files. While it shows, the pane's file commands are off: the files under it
/// aren't what the user sees, so nothing may act on them.
extension BrowserViewController {
    @objc func toggleGitStatus(_ sender: Any?) {
        if gitStatus != nil { return closeGitStatus(selecting: nil) }
        guard canShowGitStatus, let folder = directory else { return Sounds.beep() }
        if let repository = services.git.repository(containing: folder) { return showGitStatus(repository) }
        let revision = navigationRevision
        gitStatusLookup = Task { [weak self, git = services.git] in
            let repository = await git.repositoryFound(containing: folder)
            guard let self, self.navigationRevision == revision, self.directory == folder, !Task.isCancelled else { return }
            guard let repository else { return Sounds.beep() }
            self.showGitStatus(repository)
        }
    }

    /// A local folder: not a server's, a container's or an archive's copy, and not search results.
    var canShowGitStatus: Bool {
        guard let directory, GitRunner.isAvailable else { return false }
        return !isOnServer && !isInsideArchive && !isInContainerCopy && !isShowingResults && !services.copies.isCopy(directory)
    }

    func showGitStatus(_ repository: GitRepository) {
        guard gitStatus == nil else { return }
        // The files under the status view are out of reach of every command.
        select([])
        let status = GitStatusViewController(workbench: GitWorkbench(repository: repository, writer: services.gitWriter), services: services)
        status.onClose = { [weak self] file in self?.closeGitStatus(selecting: file) }
        addChild(status)
        // The files are hidden, not just covered: nothing shows through the status, and VoiceOver doesn't read them.
        gitStatusHidden = view.subviews.filter { !$0.isHidden }
        gitStatusHidden.forEach { $0.isHidden = true }
        status.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status.view)
        NSLayoutConstraint.activate([
            status.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            status.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            status.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            status.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        gitStatus = status
        view.window?.makeFirstResponder(status.table)
    }

    /// Back to the files, selecting `file` when it's in the folder shown or revealing it in its own folder.
    func closeGitStatus(selecting file: URL?) {
        guard let status = gitStatus else { return }
        status.stop()
        status.view.removeFromSuperview()
        status.removeFromParent()
        gitStatusHidden.forEach { $0.isHidden = false }
        gitStatusHidden = []
        gitStatus = nil
        view.window?.makeFirstResponder(activeView?.focusView ?? outlineView)
        guard let file else { return }
        let parent = file.deletingLastPathComponent()
        if parent.lexicallyStandardized == directory?.lexicallyStandardized { select([file]) } else { load(parent, select: file) }
    }

    /// Leaving the repository leaves its status; moving within it keeps the status view.
    func gitStatusNavigated(to url: URL) {
        gitStatusLookup?.cancel()
        guard let status = gitStatus else { return }
        let root = status.repository.rootPath
        let path = url.lexicallyStandardized.path
        if path != root, !path.hasPrefix(root == "/" ? "/" : root + "/") { closeGitStatus(selecting: nil) }
    }

    func stopGitStatus() {
        gitStatusLookup?.cancel()
        closeGitStatus(selecting: nil)
    }

    /// Menu answers while the status view shows: only leaving it, reloading and window commands.
    func validateGitItem(_ item: NSMenuItem) -> Bool? {
        guard let action = item.action else { return nil }
        if action == #selector(toggleGitStatus(_:)) {
            item.title = gitStatus == nil ? String(localized: "Show Git Status") : String(localized: "Hide Git Status")
            return gitStatus != nil || canShowGitStatus
        }
        guard gitStatus != nil else { return nil }
        return [#selector(reloadFolder(_:)), #selector(copyPath(_:)), #selector(copyName(_:)), #selector(copyRelativePath(_:))].contains(action)
            ? nil : false
    }
}
