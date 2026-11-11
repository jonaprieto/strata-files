import AppKit
import StrataDev

/// Beside the files: the active pane's repository, its branch and changes, and its history with the graph. Clicking a
/// commit shows that commit's files in the pane, read only (a snapshot, `GitSnapshots`), at the same folder or the
/// nearest one that existed then; Working Files brings the pane back. The repository itself is never changed.
final class GitHistoryPanelController: NSViewController {
    private let services: BrowserServices
    /// The active pane's folder, and how to show another in it (selecting an item there).
    var paneFolder: () -> URL? = { nil }
    var navigate: (URL, URL?) -> Void = { _, _ in }
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
    /// The files the selected commit changed, under the history.
    private(set) var files: [GitFileDiff] = []
    private(set) var filesCommit: GitCommit?
    private(set) var filesTask: Task<Void, Never>?
    let filesTable = FilesTable()
    private let filesHeading = NSTextField(labelWithString: "")
    private let filesView = NSView()

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
        // Longer than the panel, a line ends in an ellipsis; holding its full width, it pushed the header past the edge.
        for label in [titleLabel, statusLabel, bannerLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        emptyMessage.textColor = .secondaryLabelColor
        emptyMessage.isHidden = true
        let stack = NSStackView(views: [titleLabel, statusLabel, banner, emptyMessage])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 6, right: 12)
        // The header takes only its lines; the history and the files below take the rest.
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        // The history above, the selected commit's files below in a third of the panel.
        let line = NSBox()
        line.boxType = .separator
        for view in [stack, logContainer, line, makeFilesView()] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let third = filesView.heightAnchor.constraint(equalTo: root.heightAnchor, multiplier: 1.0 / 3)
        third.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            logContainer.topAnchor.constraint(equalTo: stack.bottomAnchor),
            logContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            logContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            line.topAnchor.constraint(equalTo: logContainer.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            filesView.topAnchor.constraint(equalTo: line.bottomAnchor),
            filesView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            filesView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            filesView.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor),
            third,
            filesView.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            logContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
        ThemeStyle.bind(root, to: .content)
        root.setAccessibilityLabel(String(localized: "Git History"))
        view = root
    }

    private func makeFilesView() -> NSView {
        filesHeading.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        filesHeading.textColor = .secondaryLabelColor
        filesHeading.lineBreakMode = .byTruncatingTail
        filesHeading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filesTable.addTableColumn(NSTableColumn(identifier: .init("file")))
        filesTable.headerView = nil
        filesTable.rowSizeStyle = .custom
        filesTable.rowHeight = 22
        filesTable.style = .plain
        filesTable.intercellSpacing = .zero
        filesTable.dataSource = self
        filesTable.delegate = self
        filesTable.target = self
        filesTable.action = #selector(fileClicked)
        filesTable.onReturn = { [weak self] in
            guard let self, self.filesTable.selectedRow >= 0 else { return Sounds.beep() }
            self.open(fileAt: self.filesTable.selectedRow)
        }
        filesTable.setAccessibilityLabel(String(localized: "Files changed in the selected commit"))
        let scroll = NSScrollView()
        scroll.documentView = filesTable
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        ThemeStyle.bind(scroll, to: .content)
        for view in [filesHeading, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            filesView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            filesHeading.topAnchor.constraint(equalTo: filesView.topAnchor, constant: 6),
            filesHeading.leadingAnchor.constraint(equalTo: filesView.leadingAnchor, constant: 12),
            filesHeading.trailingAnchor.constraint(lessThanOrEqualTo: filesView.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: filesHeading.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: filesView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: filesView.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: filesView.bottomAnchor),
        ])
        return filesView
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
            listFiles(of: nil)
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
        log.onSelectionChange = { [weak self] commits in self?.listFiles(of: commits.count == 1 ? commits.first : nil) }
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

    /// Shows `commit`'s files in the pane at the folder it shows now (or the nearest that existed then), or at the
    /// folder of `path` with it selected. A later choice wins: an earlier one still being made is dropped.
    @discardableResult
    func show(_ commit: GitCommit, selecting path: String? = nil) -> Task<Void, Never> {
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
            let item = path.map { top.appending(path: $0) }
            let wanted = item?.deletingLastPathComponent() ?? folder.map { folder in
                GitSnapshotCache.commit(containing: folder).map { GitSnapshots.path(of: folder, from: $0.top, to: top) }
                    ?? GitSnapshots.path(of: folder, from: repository.root, to: top)
            } ?? top
            let target = await Self.nearestFolder(wanted, within: top)
            guard let self, mine == self.generation else { return }
            self.owners[top.path] = repository
            self.viewing = commit.id
            self.navigate(target, item)
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
            self.navigate(target, nil)
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

    // MARK: - The selected commit's files

    /// Lists what `commit` changed; nil (none or several selected) clears the list. A later selection wins.
    private func listFiles(of commit: GitCommit?) {
        filesTask?.cancel()
        filesCommit = commit
        guard let commit, let repository else {
            files = []
            filesTable.reloadData()
            filesHeading.stringValue = String(localized: "Select a commit to see its files")
            return
        }
        let workbench = GitWorkbench(repository: repository, writer: services.gitWriter)
        filesTask = Task { [weak self] in
            let found = await workbench.files(of: commit.id)
            guard let self, !Task.isCancelled, self.filesCommit == commit else { return }
            self.files = found ?? []
            self.filesTable.reloadData()
            self.filesHeading.stringValue = found == nil ? String(localized: "Git couldn’t list \(commit.shortID)’s files.")
                : String(localized: "\(self.files.count) files changed in \(commit.shortID)", comment: "plural")
        }
    }

    @objc private func fileClicked() {
        guard filesTable.clickedRow >= 0 else { return }
        open(fileAt: filesTable.clickedRow)
    }

    /// Shows the file in the pane, among its commit's files; a file the commit deleted isn't there, so the commit's
    /// changes show instead.
    @discardableResult
    func open(fileAt row: Int) -> Task<Void, Never>? {
        guard let commit = filesCommit, let file = files[safe: row], let repository else { return nil }
        pendingMove?.cancel()
        if file.isDeleted {
            showDiff(repository, .commit(commit.id), String(localized: "Commit \(commit.shortID): \(commit.subject)"))
            return nil
        }
        return show(commit, selecting: file.path)
    }

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
        filesTask?.cancel()
        generation += 1
        log?.stop()
    }
}

extension GitHistoryPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GitRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let file = files[safe: row] else { return nil }
        let cell = tableView.makeView(withIdentifier: GitStatusCell.identifier, owner: nil) as? GitStatusCell ?? GitStatusCell()
        var content = GitStatusCell.Content.file(file.path, diff: file, section: .staged, expanded: nil)
        // No disclosure here: the letter lines up near the heading's margin.
        content.indent = 0
        cell.show(content)
        return cell
    }

    /// Return opens the selected file, as a click does.
    final class FilesTable: NSTableView {
        var onReturn: () -> Void = {}
        override func keyDown(with event: NSEvent) {
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty, event.characters == "\r" { return onReturn() }
            super.keyDown(with: event)
        }
    }
}
