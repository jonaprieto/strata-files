import AppKit
import StrataDev

/// Beside the files: the active pane's repository, its branch and changes, and its history with the graph. Clicking a
/// commit shows that commit's files in the pane, read only (a snapshot, `GitSnapshots`), at the same folder or the
/// nearest one that existed then; Working Files brings the pane back. The repository itself is never changed.
final class GitHistoryPanelController: NSViewController {
    private let services: BrowserServices
    /// The active pane's folder, and how to show another in it.
    var paneFolder: () -> URL? = { nil }
    var navigate: (URL) -> Void = { _ in }
    /// Shows a diff in the pane, which has room for it.
    var showDiff: (GitRepository, GitDiffKind, String) -> Void = { _, _, _ in }
    /// The commit a key moved to, shown once the keys rest.
    private(set) var pendingMove: Task<Void, Never>?

    private(set) var repository: GitRepository?
    private(set) var log: GitLogViewController?
    /// The commit the pane shows, or nil for the working files.
    private(set) var viewing: String?
    /// Which repository each snapshot shown here came from, so the panel keeps following it inside a snapshot.
    private var owners: [String: GitRepository] = [:]
    private var lookup: Task<Void, Never>?
    private var generation = 0

    private let titleLabel = NSTextField(labelWithString: String(localized: "Git History"))
    private let statusLabel = NSTextField(labelWithString: "")
    private let banner = NSStackView()
    private let bannerLabel = NSTextField(labelWithString: "")
    let workingFilesButton = NSButton(title: String(localized: "Working Files"), target: nil, action: nil)
    let emptyMessage = NSTextField(wrappingLabelWithString: String(localized: "The folder shown isn’t in a git repository."))
    private let logContainer = NSView()

    init(services: BrowserServices) {
        self.services = services
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        bannerLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        bannerLabel.lineBreakMode = .byTruncatingTail
        workingFilesButton.target = self
        workingFilesButton.action = #selector(workingFilesClicked)
        workingFilesButton.controlSize = .small
        workingFilesButton.image = NSImage(systemSymbolName: "arrow.uturn.backward.circle", accessibilityDescription: nil)
        workingFilesButton.imagePosition = .imageLeading
        workingFilesButton.toolTip = String(localized: "Show the repository’s current files again")
        banner.orientation = .horizontal
        banner.spacing = 6
        banner.addArrangedSubview(bannerLabel)
        banner.addArrangedSubview(workingFilesButton)
        banner.isHidden = true
        banner.setAccessibilityElement(true)
        banner.setAccessibilityRole(.group)
        emptyMessage.textColor = .secondaryLabelColor
        emptyMessage.isHidden = true
        let stack = NSStackView(views: [titleLabel, statusLabel, banner, emptyMessage])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 6, right: 12)
        for view in [stack, logContainer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            logContainer.topAnchor.constraint(equalTo: stack.bottomAnchor),
            logContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            logContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            logContainer.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor),
        ])
        ThemeStyle.bind(root, to: .content)
        root.setAccessibilityLabel(String(localized: "Git History"))
        view = root
    }

    // MARK: - Following the pane

    /// The pane moved or its repository's status changed: show its repository, or say there's none.
    func follow() {
        _ = view
        lookup?.cancel()
        guard let folder = paneFolder() else { return show(nil) }
        if let snapshot = GitSnapshotCache.commit(containing: folder), let owner = owners[snapshot.top.path] {
            viewing = snapshot.commit
            return show(owner)
        }
        viewing = nil
        if let found = services.git.repository(containing: folder) { return show(found) }
        lookup = Task { [weak self, git = services.git] in
            let found = await git.repositoryFound(containing: folder)
            guard let self, !Task.isCancelled, self.paneFolder() == folder else { return }
            self.show(found)
        }
    }

    private func show(_ found: GitRepository?) {
        if found != repository {
            log?.stop()
            log?.view.removeFromSuperview()
            log?.removeFromParent()
            log = nil
            repository = found
            if let found { install(log: found) }
        }
        emptyMessage.isHidden = found != nil
        statusLabel.isHidden = found == nil
        if let found {
            let summary = services.git.snapshot(for: found.root)?.statusBarText ?? ""
            statusLabel.stringValue = [found.root.lastPathComponent, summary].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        updateBanner()
    }

    private func install(log repository: GitRepository) {
        let log = GitLogViewController(all: false, workbench: GitWorkbench(repository: repository, writer: services.gitWriter))
        log.stacked = true
        log.onSelect = { [weak self] commit in
            self?.pendingMove?.cancel()
            self?.show(commit)
        }
        log.onMove = { [weak self] commit in self?.showSoon(commit) }
        log.onShowDiff = { [weak self] kind, title in
            guard let self, let repository = self.repository else { return }
            self.pendingMove?.cancel()
            self.showDiff(repository, kind, title)
        }
        log.onClose = {}
        addChild(log)
        log.view.translatesAutoresizingMaskIntoConstraints = false
        logContainer.addSubview(log.view)
        NSLayoutConstraint.activate([
            log.view.leadingAnchor.constraint(equalTo: logContainer.leadingAnchor),
            log.view.trailingAnchor.constraint(equalTo: logContainer.trailingAnchor),
            log.view.topAnchor.constraint(equalTo: logContainer.topAnchor),
            log.view.bottomAnchor.constraint(equalTo: logContainer.bottomAnchor),
        ])
        self.log = log
    }

    private func updateBanner() {
        guard let viewing, repository != nil else { banner.isHidden = true; return }
        let commit = log?.commits.first { $0.id == viewing }
        let short = String(viewing.prefix(7))
        bannerLabel.stringValue = commit.map { String(localized: "Viewing \(short): \($0.subject)") } ?? String(localized: "Viewing \(short)")
        banner.isHidden = false
        banner.setAccessibilityLabel(String(localized: "The pane shows commit \(short), read only"))
    }

    // MARK: - Showing a commit

    /// Shows `commit`'s files in the pane at the folder it shows now (or the nearest that existed then). A later
    /// choice wins: an earlier one still being made is dropped.
    @discardableResult
    func show(_ commit: GitCommit) -> Task<Void, Never> {
        guard let repository else { return Task {} }
        generation += 1
        let mine = generation
        let folder = paneFolder()
        statusLabel.stringValue = String(localized: "Opening \(commit.shortID)…")
        return Task { [weak self] in
            guard let top = await GitSnapshots.make(repository, commit: commit.id) else {
                self?.statusLabel.stringValue = String(localized: "Git couldn’t show \(commit.shortID).")
                return Sounds.beep()
            }
            let wanted = folder.map { folder in
                GitSnapshotCache.commit(containing: folder).map { GitSnapshots.path(of: folder, from: $0.top, to: top) }
                    ?? GitSnapshots.path(of: folder, from: repository.root, to: top)
            } ?? top
            let target = await Self.nearestFolder(wanted, within: top)
            guard let self, mine == self.generation else { return }
            self.owners[top.path] = repository
            self.viewing = commit.id
            self.navigate(target)
            self.show(repository)
            self.announce(String(localized: "Showing the files of commit \(commit.shortID), read only"))
        }
    }

    /// Back to the repository's own files, at the folder the pane shows in the commit (or the nearest that exists).
    @discardableResult
    func showWorkingFiles() -> Task<Void, Never> {
        guard let repository else { return Task {} }
        generation += 1
        let mine = generation
        let folder = paneFolder()
        return Task { [weak self] in
            let wanted = folder.flatMap { folder in
                GitSnapshotCache.commit(containing: folder).map { GitSnapshots.path(of: folder, from: $0.top, to: repository.root) }
            } ?? repository.root
            let target = await Self.nearestFolder(wanted, within: repository.root)
            guard let self, mine == self.generation else { return }
            self.viewing = nil
            self.navigate(target)
            self.show(repository)
            self.announce(String(localized: "Showing the working files"))
        }
    }

    /// Holding a key passes many commits; only the one it stops at is checked out.
    private func showSoon(_ commit: GitCommit) {
        pendingMove?.cancel()
        pendingMove = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            await self.show(commit).value
        }
    }

    @objc private func workingFilesClicked() { showWorkingFiles() }

    /// `url`, or the nearest folder above it that exists, never above `top`.
    @concurrent nonisolated private static func nearestFolder(_ url: URL, within top: URL) async -> URL {
        var candidate = url.lexicallyStandardized
        let topPath = top.lexicallyStandardized.path
        while candidate.path.hasPrefix(topPath + "/") {
            var info = stat()
            if lstat(candidate.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR { return candidate }
            candidate = candidate.deletingLastPathComponent()
        }
        return top
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: view, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func stop() {
        lookup?.cancel()
        pendingMove?.cancel()
        generation += 1
        log?.stop()
    }
}
