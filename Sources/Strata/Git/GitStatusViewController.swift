import AppKit
import StrataDev

/// A repository's status in a pane, as Magit shows it: sections of files, their diffs a Tab away, and single keys
/// that stage, unstage and commit exactly the rows selected.
final class GitStatusViewController: NSViewController {
    let workbench: GitWorkbench
    private let services: BrowserServices
    /// Leaves the status view, optionally selecting a file in the pane's files.
    var onClose: (URL?) -> Void = { _ in }
    /// Asks whether to trust the repository; headless or closed windows answer no, which changes nothing.
    var askToTrust: (GitAutomation, NSWindow?) async -> Bool = GitStatusViewController.askToTrustInWindow
    /// Opens the commit message editor; headless windows open nothing.
    var editCommitMessage: (GitCommitEditor.Request, NSWindow?) async -> String? = GitCommitEditor.edit(_:in:)
    var prompts = GitPrompts()

    private(set) var status: GitWorkbenchStatus?
    private(set) var rows: [GitStatusRow] = []
    private(set) var expanded: Set<GitStatusOutline.FileKey> = []
    private(set) var isTrusted = false
    /// The last thing a command said, shown under the list.
    private(set) var message: (text: String, isError: Bool)?
    private(set) var loadTask: Task<Void, Never>?
    private(set) var commandTask: Task<Void, Never>?
    private var generation = 0

    let table = GitStatusTableView()
    private let scrollView = NSScrollView()
    let header = GitStatusHeader()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let messageIcon = NSImageView()
    /// The symbol beside the message, so it doesn't read by color alone.
    private(set) var messageSymbol: String?
    private lazy var messageRow = NSStackView(views: [messageIcon, messageLabel])
    let hintLabel = NSTextField(labelWithString: String(localized: "s stage · u unstage · k discard · c commit · Tab changes · ? all keys · q back",
                                                         comment: "Git status: the keys shown under the list"))
    private lazy var footer = NSStackView(views: [messageRow, hintLabel])
    /// What each item of the right-click menu runs.
    private var menuActions: [() -> Void] = []

    init(workbench: GitWorkbench, services: BrowserServices) {
        self.workbench = workbench
        self.services = services
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var repository: GitRepository { workbench.repository }

    override func loadView() {
        let root = NSView()
        let column = NSTableColumn(identifier: .init("git"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.allowsMultipleSelection = true
        table.usesAutomaticRowHeights = false
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = self
        table.delegate = self
        table.owner = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.setAccessibilityLabel(String(localized: "Git status", comment: "Accessibility: the list of a repository’s changes"))
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        ThemeStyle.bind(scrollView, to: .content)
        header.trustButton.target = self
        header.trustButton.action = #selector(trustClicked)
        header.helpButton.target = self
        header.helpButton.action = #selector(helpClicked)
        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.isHidden = true
        messageLabel.setAccessibilityRole(.staticText)
        messageIcon.setContentHuggingPriority(.required, for: .horizontal)
        messageRow.orientation = .horizontal
        messageRow.alignment = .firstBaseline
        messageRow.spacing = 4
        messageRow.isHidden = true
        hintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 2
        table.menu = NSMenu()
        table.menu?.delegate = self
        for subview in [header, scrollView, footer] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 4),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
        view = root
        services.preferences.notifications.addObserver(self, selector: #selector(writerChanged), name: .gitWriteStateChanged, object: services.gitWriter)
        services.preferences.notifications.addObserver(self, selector: #selector(trustChanged), name: .gitTrustChanged, object: services.gitWriter.trust)
        NotificationCenter.default.addObserver(self, selector: #selector(statusChanged(_:)), name: .gitStatusDidChange, object: services.git)
        reload()
    }

    /// Stops reading and running; a pending command's result is dropped.
    private(set) var isStopped = false

    func stop() {
        isStopped = true
        closeAllOverlays()
        generation += 1
        loadTask?.cancel()
        commandTask?.cancel()
        services.preferences.notifications.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Loading

    func reload() {
        generation += 1
        let mine = generation
        reloadAgain = false
        isLoading = true
        updateHeader()
        loadTask = Task { [weak self, workbench] in
            let status = await workbench.load()
            let trusted = await workbench.writer.trust.isTrusted(workbench.repository)
            guard let self, mine == self.generation, !Task.isCancelled else { return }
            self.isLoading = false
            self.apply(status, trusted: trusted)
            if self.reloadAgain { self.reload() }
        }
    }

    private var isLoading = false
    /// A change arrived while reading: read once more when this read lands, not once per change.
    private var reloadAgain = false

    private func apply(_ status: GitWorkbenchStatus?, trusted: Bool) {
        // On the main thread: the part of a reload the user can feel.
        let interval = gitSignposts.beginInterval("git status apply")
        defer { gitSignposts.endInterval("git status apply", interval) }
        let previous = table.selectedRowIndexes
        let selectedKeys = previous.compactMap { rows.indices.contains($0) ? rows[$0].identity : nil }
        self.status = status
        isTrusted = trusted
        if status == nil { show(String(localized: "Git couldn’t read this repository."), isError: true) }
        rows = status.map { GitStatusOutline.rows($0, expanded: expanded) } ?? []
        table.reloadData()
        // The same rows stay selected when they're still there; otherwise the file now in their place, so staging
        // one file after another moves on to the next, as in Magit.
        let kept = IndexSet(rows.indices.filter { selectedKeys.contains(rows[$0].identity) })
        let next = Self.nearestFile(to: previous.first ?? 0, in: rows)
        table.selectRowIndexes(kept.isEmpty ? IndexSet(next.map { [$0] } ?? []) : kept, byExtendingSelection: false)
        updateHeader()
    }

    /// The first file at or after `index`, else the last one before it.
    static func nearestFile(to index: Int, in rows: [GitStatusRow]) -> Int? {
        let isFile: (Int) -> Bool = { if case .file = rows[$0] { true } else { false } }
        return rows.indices.first { $0 >= index && isFile($0) } ?? rows.indices.last { $0 < index && isFile($0) }
    }

    /// The spinner runs while git does, and while the status is first read.
    private func updateHeader() {
        header.show(repository: repository, status: status, trusted: isTrusted,
                    busy: workbench.writer.isRunning(in: repository) || (isLoading && status == nil))
    }

    @objc private func statusChanged(_ notification: Notification) {
        guard let root = notification.userInfo?["root"] as? URL, root.lexicallyStandardized.path == repository.rootPath else { return }
        guard commandTask == nil else { return }
        if isLoading { reloadAgain = true } else { reload() }
    }

    @objc private func writerChanged() { updateHeader() }

    @objc private func trustChanged() { reload() }

    // MARK: - Keys

    /// Single keys, as in Magit. Returns false for keys the list should handle itself (arrows, Return to open).
    func handleKey(_ characters: String, keyCode: UInt16 = 0) -> Bool {
        switch characters {
        case "s": run(.stage)
        case "u": run(.unstage)
        case "S": stageAll()
        case "U": unstageAll()
        case "\t": toggleExpansion()
        case "\u{19}": cycleAllExpansion()
        case "d": showDiffTransient()
        case "l": showLogTransient()
        case "b": showBranchTransient()
        case "f": showFetchTransient()
        case "k": discardSelection()
        case "z": showStashTransient()
        case "r": showRebaseTransient()
        case "F": showPullTransient()
        case "P": showPushTransient()
        case "g": reload()
        case "c": showCommitTransient()
        case "?": helpClicked()
        case "q", "\u{1b}": onClose(nil)
        // `k` discards here, so neither it nor `j` moves, unlike in the log and diff.
        case "n": moveSelection(by: 1)
        case "p": moveSelection(by: -1)
        case "\r": visitSelectedFile()
        default: return false
        }
        return true
    }

    private func moveSelection(by step: Int) {
        guard !rows.isEmpty else { return }
        let current = table.selectedRowIndexes.last ?? (step > 0 ? -1 : rows.count)
        let next = min(max(current + step, 0), rows.count - 1)
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    var selectedRows: [GitStatusRow] { table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil } }

    /// The files whose changes Tab shows or hides: the selected files, or every file of a selected section.
    private var expandableSelection: [GitStatusOutline.FileKey] {
        var keys: [GitStatusOutline.FileKey] = []
        for row in selectedRows {
            switch row {
            case .section(let section, _) where section == .staged || section == .unstaged:
                let diffs = section == .staged ? status?.staged ?? [] : status?.unstaged ?? []
                keys += diffs.map { .init(section: section, path: $0.path) }
            case .file(let section, let path, _), .hunk(let section, let path, _), .line(let section, let path, _, _):
                if section == .staged || section == .unstaged { keys.append(.init(section: section, path: path)) }
            default: break
            }
        }
        return keys.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// Shift-Tab: every file's changes, or none.
    func cycleAllExpansion() {
        guard let status else { return }
        let all = Set(status.unstaged.map { GitStatusOutline.FileKey(section: .unstaged, path: $0.path) }
                      + status.staged.map { GitStatusOutline.FileKey(section: .staged, path: $0.path) })
        let opening = !all.isSubset(of: expanded)
        expanded = opening ? all : []
        apply(status, trusted: isTrusted)
        announce(opening ? String(localized: "Showing every file’s changes") : String(localized: "Hiding every file’s changes"))
    }

    func toggleExpansion() {
        let files = expandableSelection
        guard !files.isEmpty else { return }
        let opening = !files.allSatisfy(expanded.contains)
        for key in files { if opening { expanded.insert(key) } else { expanded.remove(key) } }
        if let status { apply(status, trusted: isTrusted) }
        let names = files.map(\.path).joined(separator: ", ")
        announce(opening ? String(localized: "Showing changes in \(names)") : String(localized: "Hiding changes in \(names)"))
    }

    @objc private func doubleClicked() {
        guard let row = selectedRows.first, case .file = row else { return }
        toggleExpansion()
    }

    private func visitSelectedFile() {
        guard let path = selectedRows.first?.path else { return Sounds.beep() }
        onClose(repository.root.appending(path: path))
    }

    // MARK: - Commands

    func run(_ command: GitStatusOutline.Command) {
        guard let status, let plan = GitStatusOutline.plan(command, selectedRows, in: status) else {
            show(command == .stage ? String(localized: "Nothing selected to stage.") : String(localized: "Nothing selected to unstage."), isError: true)
            return Sounds.beep()
        }
        perform { [workbench] in
            switch (command, plan) {
            case (.stage, .paths(let paths)): await workbench.stage(paths)
            case (.unstage, .paths(let paths)): await workbench.unstage(paths)
            case (.stage, .hunk(let file, let hunk, let lines)): await workbench.stage(file, hunk: hunk, lines: lines)
            case (.unstage, .hunk(let file, let hunk, let lines)): await workbench.unstage(file, hunk: hunk, lines: lines)
            }
        } done: { [weak self] in
            self?.describe(command, plan)
        }
    }

    func stageAll() {
        guard let status else { return }
        let paths = status.untracked + status.unstaged.flatMap { [$0.oldPath, $0.newPath].compactMap { $0 } } + status.conflicted
        guard !paths.isEmpty else { return show(String(localized: "Nothing to stage."), isError: true) }
        perform { [workbench] in await workbench.stage(paths) } done: { String(localized: "Staged all changes.") }
    }

    func unstageAll() {
        guard let status else { return }
        let paths = status.staged.flatMap { [$0.oldPath, $0.newPath].compactMap { $0 } }
        guard !paths.isEmpty else { return show(String(localized: "Nothing to unstage."), isError: true) }
        perform { [workbench] in await workbench.unstage(paths) } done: { String(localized: "Unstaged all changes.") }
    }

    enum CommitKind { case commit, amend, extend, reword }

    func commit(_ kind: CommitKind) {
        let window = view.window
        perform { [workbench, weak self] in
            if kind == .extend { return await workbench.extend() }
            let previous = kind == .commit ? "" : await workbench.headMessage() ?? ""
            let staged = await workbench.stagedSummary()
            let request = GitCommitEditor.Request(amend: kind != .commit, message: previous, staged: staged)
            guard let editor = self?.editCommitMessage, let message = await editor(request, window) else { return nil }
            return await workbench.commit(message: message, amend: kind != .commit, onlyMessage: kind == .reword)
        } done: {
            switch kind {
            case .commit: String(localized: "Committed.", comment: "Git status: a commit was made")
            case .amend, .reword: String(localized: "Amended the last commit.")
            case .extend: String(localized: "Added the staged changes to the last commit.")
            }
        }
    }

    /// Runs one command at a time: a key pressed meanwhile is refused with a beep. An untrusted repository is asked
    /// about first; the command runs only once it's trusted.
    private func perform(_ body: @escaping () async -> GitOutcome?, done: @escaping () -> String?) {
        guard commandTask == nil, !isStopped else {
            if !isStopped { show(String(localized: "Git is still running a command here."), isError: true) }
            return Sounds.beep()
        }
        commandTask = Task { [weak self, workbench] in
            // Asked before the command's own questions, so none of them is asked twice.
            var outcome: GitOutcome?
            if await workbench.writer.trust.isTrusted(workbench.repository) {
                outcome = await body()
            } else if let self, await self.requestTrust() {
                outcome = await body()
            } else {
                outcome = .refused(.untrusted)
            }
            // Only stopping drops the result; a reload meanwhile (trust changed, files changed) doesn't.
            guard let self, !self.isStopped else { return }
            self.commandTask = nil
            switch outcome {
            case nil: break
            case .done?: done().map { self.show($0, isError: false, done: true) }
            case .refused(.untrusted)?: self.show(String(localized: "Read only: this repository isn’t trusted."), isError: true)
            case .refused(.busy)?: self.show(String(localized: "Git is still running a command here."), isError: true)
            case .refused(.gitMissing)?: self.show(String(localized: "Git isn’t installed."), isError: true)
            case .failed(let text)?: self.show(text.isEmpty ? String(localized: "Git refused.") : text, isError: true)
            case .emptyMessage?: self.show(String(localized: "A commit needs a message."), isError: true)
            case .nothingStaged?: self.show(String(localized: "Nothing is staged to commit."), isError: true)
            case .stopped?: self.show(String(localized: "The rebase stopped: change or resolve the files, stage them, then press r and r to continue."), isError: false)
            }
            self.reload()
        }
    }

    private func describe(_ command: GitStatusOutline.Command, _ plan: GitStatusOutline.Plan) -> String {
        switch (command, plan) {
        case (.stage, .paths(let paths)): String(localized: "Staged \(paths.count) files", comment: "plural")
        case (.unstage, .paths(let paths)): String(localized: "Unstaged \(paths.count) files", comment: "plural")
        case (.stage, .hunk(_, _, let lines)): lines == nil ? String(localized: "Staged a hunk.") : String(localized: "Staged the chosen lines.")
        case (.unstage, .hunk(_, _, let lines)): lines == nil ? String(localized: "Unstaged a hunk.") : String(localized: "Unstaged the chosen lines.")
        }
    }

    // MARK: - Trust

    @objc private func trustClicked() {
        Task { _ = await requestTrust() }
    }

    /// Shows what the repository would run and trusts it if the user agrees.
    private func requestTrust() async -> Bool {
        let automation = await GitAutomation.read(repository)
        guard await askToTrust(automation, view.window) else { return false }
        return await workbench.writer.trust.trust(repository)
    }

    static func askToTrustInWindow(_ automation: GitAutomation, _ window: NSWindow?) async -> Bool {
        guard let window, window.isVisible, window.attachedSheet == nil else { return false }
        let alert = NSAlert()
        alert.messageText = String(localized: "Trust this repository?")
        var lines = [String(localized: "Strata will run git here with the repository’s own settings, so these can run on your Mac:")]
        lines += automation.hooks.map { String(localized: "Hook: \($0)") }
        lines += automation.filters.map { String(localized: "Filter: \($0)") }
        if let monitor = automation.fileMonitor { lines.append(String(localized: "File monitor: \(monitor)")) }
        if automation.isEmpty { lines.append(String(localized: "It names no hooks, filters or file monitor.")) }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "Trust"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return await withCheckedContinuation { done in
            alert.beginSheetModal(for: window) { done.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }

    // MARK: - Transients and help

    func showCommitTransient() {
        GitTransient.show(String(localized: "Commit"), [
            .init(key: "c", title: String(localized: "Commit", comment: "Git: make a commit")) { [weak self] in self?.commit(.commit) },
            .init(key: "a", title: String(localized: "Amend", comment: "Git: change the last commit’s changes and message")) { [weak self] in self?.commit(.amend) },
            .init(key: "e", title: String(localized: "Extend", comment: "Git: add the staged changes to the last commit, same message")) { [weak self] in self?.commit(.extend) },
            .init(key: "w", title: String(localized: "Reword", comment: "Git: change only the last commit’s message")) { [weak self] in self?.commit(.reword) },
        ], from: table, owner: self)
    }

    func showDiffTransient() {
        GitTransient.show(String(localized: "Diff"), diffItems, from: table, owner: self)
    }

    var diffItems: [GitTransient.Item] {
        [
            .init(key: "u", title: String(localized: "Unstaged changes")) { [weak self] in self?.showDiff(.unstaged) },
            .init(key: "s", title: String(localized: "Staged changes")) { [weak self] in self?.showDiff(.staged) },
            .init(key: "w", title: String(localized: "Everything not committed")) { [weak self] in self?.showDiff(.uncommitted) },
        ]
    }

    /// Views over the status list, newest last: a log, a diff opened from it. `q` closes the top one.
    private(set) var overlays: [NSViewController] = []
    /// Opened only to show a diff (from the history panel): closing the diff closes the status too.
    var closesWithItsLastView = false
    var diffView: GitDiffViewController? { overlays.last as? GitDiffViewController }
    var logView: GitLogViewController? { overlays.last as? GitLogViewController }

    /// A whole diff over the status list (or over the log it came from), opened on `focus` when given.
    func showDiff(_ kind: GitDiffKind, title: String? = nil, focusing focus: String? = nil) {
        let heading = title ?? {
            switch kind {
            case .unstaged: String(localized: "Unstaged changes")
            case .staged: String(localized: "Staged changes")
            case .uncommitted: String(localized: "Everything not committed")
            case .commit(let id): String(localized: "Commit \(String(id.prefix(7)))")
            case .range(let from, let to): "\(String(from.prefix(7)))..\(String(to.prefix(7)))"
            }
        }()
        let diff = GitDiffViewController(kind: kind, title: heading, workbench: workbench)
        diff.focus = focus
        diff.onClose = { [weak self] in self?.closeOverlay() }
        push(diff, focus: diff.table, announcing: heading)
    }

    func showLogTransient() {
        GitTransient.show(String(localized: "Log"), logItems, from: table, owner: self)
    }

    var logItems: [GitTransient.Item] {
        [
            .init(key: "l", title: String(localized: "Current branch")) { [weak self] in self?.showLog(all: false) },
            .init(key: "a", title: String(localized: "All branches")) { [weak self] in self?.showLog(all: true) },
        ]
    }

    func showLog(all: Bool) {
        let log = GitLogViewController(all: all, workbench: workbench)
        log.hint = String(localized: "Return changes · d compare two · x reset · r rebase · q back", comment: "Git log: the keys shown under it")
        log.onClose = { [weak self] in self?.closeOverlay() }
        log.onRebase = { [weak self, weak log] commit in
            guard let self, let log, !log.all, let index = log.commits.firstIndex(of: commit) else { return Sounds.beep() }
            self.editRebase(Array(log.commits[0...index].reversed()), onto: commit.parents.first)
        }
        log.onReset = { [weak self, weak log] commit in
            guard let self, let log else { return }
            GitTransient.show(String(localized: "Reset to \(commit.shortID)"), [
                .init(key: "s", title: String(localized: "Soft: keep the index and files")) { [weak self] in self?.reset(to: commit, mode: .soft) },
                .init(key: "m", title: String(localized: "Mixed: keep the files")) { [weak self] in self?.reset(to: commit, mode: .mixed) },
                .init(key: "h", title: String(localized: "Hard: the files too…")) { [weak self] in self?.reset(to: commit, mode: .hard) },
            ], from: log.table, owner: self)
        }
        log.onShowDiff = { [weak self] kind, title in self?.showDiff(kind, title: title) }
        push(log, focus: log.table, announcing: log.heading)
    }

    /// What each overlay hid beneath it, shown again when it closes.
    private var covered: [[NSView]] = []

    private func push(_ controller: NSViewController, focus: NSView, announcing heading: String) {
        let beneath = overlays.last.map { [$0.view] } ?? [header, scrollView, footer]
        covered.append(beneath.filter { !$0.isHidden })
        covered.last?.forEach { $0.isHidden = true }
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        overlays.append(controller)
        view.window?.makeFirstResponder(focus)
        announce(heading)
    }

    func closeOverlay() {
        guard let top = overlays.popLast() else { return }
        (top as? GitDiffViewController)?.stop()
        (top as? GitLogViewController)?.stop()
        top.view.removeFromSuperview()
        top.removeFromParent()
        covered.popLast()?.forEach { $0.isHidden = false }
        if overlays.isEmpty, closesWithItsLastView { return onClose(nil) }
        let focus: NSView = (overlays.last as? GitLogViewController)?.table ?? (overlays.last as? GitDiffViewController)?.table
            ?? (overlays.last as? GitRebaseEditor)?.table ?? table
        view.window?.makeFirstResponder(focus)
    }

    private func closeAllOverlays() {
        while !overlays.isEmpty { closeOverlay() }
    }

    // MARK: - Branches

    func showBranchTransient() {
        GitTransient.show(String(localized: "Branch"), branchItems, from: table, owner: self)
    }

    var branchItems: [GitTransient.Item] {
        [
            .init(key: "b", title: String(localized: "Switch to…")) { [weak self] in self?.branch(.switchTo) },
            .init(key: "c", title: String(localized: "New branch and switch…")) { [weak self] in self?.branch(.createAndSwitch) },
            .init(key: "n", title: String(localized: "New branch…")) { [weak self] in self?.branch(.create) },
            .init(key: "m", title: String(localized: "Rename the current branch…")) { [weak self] in self?.branch(.rename) },
            .init(key: "k", title: String(localized: "Delete a branch…")) { [weak self] in self?.branch(.delete) },
        ]
    }

    enum BranchCommand { case switchTo, createAndSwitch, create, rename, delete }

    func branch(_ command: BranchCommand) {
        let window = view.window
        let prompts = prompts
        perform { [workbench] in
            switch command {
            case .switchTo:
                guard let branches = await workbench.branches() else { return .failed(String(localized: "Git couldn’t list the branches.")) }
                let options = branches.filter { !$0.isCurrent }
                guard let name = await prompts.choose(String(localized: "Switch to which branch?"), options.map(\.name), window),
                      let chosen = options.first(where: { $0.name == name }) else { return nil }
                return await workbench.switchBranch(chosen)
            case .createAndSwitch, .create:
                guard let name = await prompts.name(String(localized: "Name of the new branch"), "", window) else { return nil }
                return await workbench.createBranch(name, checkout: command == .createAndSwitch)
            case .rename:
                guard let current = await workbench.currentBranch() else {
                    return .failed(String(localized: "No branch is checked out to rename."))
                }
                guard let name = await prompts.name(String(localized: "New name for “\(current)”"), current, window), name != current else { return nil }
                return await workbench.renameBranch(current, to: name)
            case .delete:
                guard let branches = await workbench.branches() else { return .failed(String(localized: "Git couldn’t list the branches.")) }
                let options = branches.filter { !$0.isCurrent && !$0.isRemote }.map(\.name)
                guard let name = await prompts.choose(String(localized: "Delete which branch?"), options, window) else { return nil }
                let outcome = await workbench.deleteBranch(name, force: false)
                guard case .failed(let message) = outcome, message.contains("not fully merged") else { return outcome }
                // Its commits are on no other branch: deleting it anyway is a second, explicit choice.
                guard await prompts.confirm(String(localized: "“\(name)” has commits no other branch has."),
                                            String(localized: "Deleting it anyway leaves those commits reachable only through git’s reflog."),
                                            String(localized: "Delete Anyway"), window) else { return nil }
                return await workbench.deleteBranch(name, force: true)
            }
        } done: {
            switch command {
            case .switchTo: String(localized: "Switched branch.")
            case .createAndSwitch: String(localized: "Made the branch and switched to it.")
            case .create: String(localized: "Made the branch.")
            case .rename: String(localized: "Renamed the branch.")
            case .delete: String(localized: "Deleted the branch.")
            }
        }
    }

    // MARK: - Discard, reset and stash

    /// The last command that can be taken back, also registered with the window's ⌘Z.
    private(set) var lastUndo: (undo: GitUndo, name: String)?

    /// Runs `body`, and registers what takes it back.
    private func performUndoable(_ name: String, _ body: @escaping () async -> (GitOutcome, GitUndo?)?, done: @escaping () -> String?) {
        perform { [weak self] in
            guard let result = await body() else { return nil }
            if let undo = result.1 { self?.register(undo, name: name) }
            return result.0
        } done: { done() }
    }

    private func register(_ undo: GitUndo, name: String) {
        lastUndo = (undo, name)
        guard let manager = view.window?.undoManager else { return }
        let step = manager.beginStep()
        defer { manager.endStep(step) }
        manager.registerUndo(withTarget: self) { target in target.runUndo(undo) }
        manager.setActionName(name)
    }

    /// Takes back a discard, reset or stash, if nothing has changed since.
    func runUndo(_ undo: GitUndo) {
        if lastUndo?.undo == undo { lastUndo = nil }
        perform { [workbench] in await workbench.undo(undo) } done: { String(localized: "Undone.") }
    }

    /// `k`: unstaged changes of tracked files go back to their staged version; untracked files go to the Trash.
    /// Both after a confirmation that names them.
    func discardSelection() {
        guard let status else { return }
        let window = view.window
        let prompts = prompts
        let rows = selectedRows
        let untracked = rows.compactMap { row -> String? in if case .file(.untracked, let path, _) = row { path } else { nil } }
            + (rows.contains(.section(.untracked, count: status.untracked.count)) ? status.untracked : [])
        let tracked = GitStatusOutline.plan(.stage, rows.filter { $0.section == .unstaged }, in: status)
        guard !untracked.isEmpty || tracked != nil else {
            show(String(localized: "Only unstaged changes and untracked files can be discarded; unstage first."), isError: true)
            return Sounds.beep()
        }
        let names = (untracked + {
            switch tracked {
            case .paths(let paths)?: paths
            case .hunk(let file, _, _)?: [file.path]
            case nil: []
            }
        }()).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let listed = names.prefix(5).joined(separator: "\n") + (names.count > 5 ? "\n" + String(localized: "and \(names.count - 5) more", comment: "plural") : "")
        let root = repository.root
        let files = services.files
        let undoManager = window?.undoManager
        performUndoable(String(localized: "Discard")) { [workbench] in
            guard await prompts.confirm(String(localized: "Discard these changes?"),
                                        listed + "\n\n" + String(localized: "Untracked files go to the Trash. Edit ▸ Undo brings the rest back."),
                                        String(localized: "Discard"), window) else { return nil }
            if !untracked.isEmpty {
                do { try await files.trash(untracked.map { root.appending(path: $0) }, undo: undoManager) }
                catch { return (.failed(error.localizedDescription), nil) }
            }
            switch tracked {
            case .paths(let paths)?: return await workbench.discard(paths)
            case .hunk(let file, let hunk, let lines)?: return await workbench.discard(file, hunk: hunk, lines: lines)
            case nil: return (.done, nil)
            }
        } done: {
            String(localized: "Discarded \(names.count) files", comment: "plural")
        }
    }

    func showStashTransient() {
        GitTransient.show(String(localized: "Stash"), stashItems, from: table, owner: self)
    }

    var stashItems: [GitTransient.Item] {
        [
            .init(key: "z", title: String(localized: "Stash everything, new files too")) { [weak self] in self?.stash(.push(untracked: true)) },
            .init(key: "w", title: String(localized: "Stash changes to tracked files")) { [weak self] in self?.stash(.push(untracked: false)) },
            .init(key: "a", title: String(localized: "Apply a stash…")) { [weak self] in self?.stash(.apply) },
            .init(key: "p", title: String(localized: "Pop a stash…")) { [weak self] in self?.stash(.pop) },
            .init(key: "k", title: String(localized: "Drop a stash…")) { [weak self] in self?.stash(.drop) },
        ]
    }

    enum StashCommand: Equatable { case push(untracked: Bool), apply, pop, drop }

    func stash(_ command: StashCommand) {
        let window = view.window
        let prompts = prompts
        performUndoable(String(localized: "Stash")) { [workbench] in
            switch command {
            case .push(let untracked):
                let message = await prompts.name(String(localized: "Stash message (optional)"), "", window)
                return await workbench.stashPush(includeUntracked: untracked, message: message)
            case .apply, .pop, .drop:
                let stashes = await workbench.stashes()
                guard !stashes.isEmpty else { return (.failed(String(localized: "There are no stashes.")), nil) }
                let titles = stashes.map { "stash@{\($0.index)}: \($0.message)" }
                guard let chosen = await prompts.choose(String(localized: "Which stash?"), titles, window),
                      let index = titles.firstIndex(of: chosen) else { return nil }
                switch command {
                case .apply: return (await workbench.stashApply(index, pop: false), nil)
                case .pop: return (await workbench.stashApply(index, pop: true), nil)
                default:
                    guard await prompts.confirm(String(localized: "Drop \(chosen)?"), String(localized: "Edit ▸ Undo stores it again."),
                                                String(localized: "Drop"), window) else { return nil }
                    return await workbench.stashDrop(index)
                }
            }
        } done: {
            switch command {
            case .push: String(localized: "Stashed.")
            case .apply: String(localized: "Applied the stash.")
            case .pop: String(localized: "Popped the stash.")
            case .drop: String(localized: "Dropped the stash.")
            }
        }
    }

    /// Moves the branch to `commit`: soft keeps the index and files, mixed keeps the files, hard resets them too
    /// (after a confirmation). Each can be undone while nothing has moved since.
    func reset(to commit: GitCommit, mode: GitResetMode) {
        let window = view.window
        let prompts = prompts
        performUndoable(String(localized: "Reset")) { [workbench] in
            if mode == .hard {
                guard await prompts.confirm(String(localized: "Reset the branch and every file to \(commit.shortID)?"),
                                            String(localized: "Uncommitted changes to tracked files are replaced. Edit ▸ Undo brings them and the branch back while nothing changes meanwhile."),
                                            String(localized: "Reset"), window) else { return nil }
            }
            return await workbench.reset(to: commit.id, mode: mode)
        } done: {
            String(localized: "Reset to \(commit.shortID).")
        }
    }

    // MARK: - Rebase

    func showRebaseTransient() {
        let rebasing: Bool = if case .rebasing = status?.operation { true } else { false }
        let items: [GitTransient.Item] = rebasing ? [
            .init(key: "r", title: String(localized: "Continue")) { [weak self] in self?.rebaseStep(.continue) },
            .init(key: "s", title: String(localized: "Skip this commit")) { [weak self] in self?.rebaseStep(.skip) },
            .init(key: "a", title: String(localized: "Abort, back to where it started")) { [weak self] in self?.rebaseStep(.abort) },
        ] : [
            .init(key: "i", title: String(localized: "Interactively, from a commit in the log…")) { [weak self] in
                self?.showLog(all: false)
                self?.show(String(localized: "Select the oldest commit to change and press r."), isError: false)
            },
        ]
        GitTransient.show(String(localized: "Rebase"), items, from: table, owner: self)
    }

    enum RebaseStep { case `continue`, skip, abort }

    func rebaseStep(_ step: RebaseStep) {
        perform { [workbench] in
            switch step {
            case .continue: await workbench.rebaseContinue()
            case .skip: await workbench.rebaseSkip()
            case .abort: await workbench.rebaseAbort()
            }
        } done: {
            switch step {
            case .continue, .skip: String(localized: "The rebase finished.")
            case .abort: String(localized: "The rebase was aborted; the branch is as it was.")
            }
        }
    }

    /// The plan for rebasing `commits` (oldest first) onto `base`.
    func editRebase(_ commits: [GitCommit], onto base: String?) {
        let editor = GitRebaseEditor(todo: GitRebaseTodo(commits), base: base)
        editor.onCancel = { [weak self] in self?.closeOverlay() }
        editor.onStart = { [weak self] todo, base in
            self?.closeAllOverlays()
            self?.rebase(todo, onto: base)
        }
        push(editor, focus: editor.table, announcing: String(localized: "Rebase plan, oldest commit first"))
    }

    func rebase(_ todo: GitRebaseTodo, onto base: String?) {
        performUndoable(String(localized: "Rebase")) { [workbench] in
            await workbench.rebase(todo, onto: base)
        } done: {
            String(localized: "Rebased.")
        }
    }

    // MARK: - Remotes

    func showFetchTransient() {
        GitTransient.show(String(localized: "Fetch"), [
            .init(key: "f", title: String(localized: "From the branch’s remote")) { [weak self] in self?.remote(.fetch) },
            .init(key: "a", title: String(localized: "From every remote")) { [weak self] in self?.remote(.fetchAll) },
        ], from: table, owner: self)
    }

    func showPullTransient() {
        GitTransient.show(String(localized: "Pull"), [
            .init(key: "F", title: String(localized: "Fast-forward only")) { [weak self] in self?.remote(.pull) },
            .init(key: "r", title: String(localized: "Rebase my commits on top")) { [weak self] in self?.remote(.pullRebase) },
        ], from: table, owner: self)
    }

    func showPushTransient() {
        GitTransient.show(String(localized: "Push"), [
            .init(key: "P", title: String(localized: "Push the current branch")) { [weak self] in self?.remote(.push) },
            .init(key: "f", title: String(localized: "Force, if nobody else pushed…")) { [weak self] in self?.remote(.forcePush) },
        ], from: table, owner: self)
    }

    enum RemoteCommand { case fetch, fetchAll, pull, pullRebase, push, forcePush }

    func remote(_ command: RemoteCommand) {
        let window = view.window
        let prompts = prompts
        let hasUpstream = status?.branch.upstream != nil
        show(String(localized: "Talking to the remote…"), isError: false)
        perform { [workbench] in
            switch command {
            case .fetch: return await workbench.fetch(all: false)
            case .fetchAll: return await workbench.fetch(all: true)
            case .pull: return await workbench.pull(rebase: false)
            case .pullRebase: return await workbench.pull(rebase: true)
            case .push, .forcePush:
                if command == .forcePush {
                    guard await prompts.confirm(String(localized: "Replace the remote branch with yours?"),
                                                String(localized: "Strata pushes with a lease: if anyone pushed since you last fetched, nothing is replaced."),
                                                String(localized: "Force Push"), window) else { return nil }
                }
                guard !hasUpstream else { return await workbench.push(force: command == .forcePush) }
                let remotes = await workbench.remotes()
                let remote = remotes.count == 1 ? remotes.first : await prompts.choose(String(localized: "Push to which remote?"), remotes, window)
                guard let remote else { return remotes.isEmpty ? .failed(String(localized: "This repository has no remote.")) : nil }
                return await workbench.push(force: command == .forcePush, settingUpstreamOn: remote)
            }
        } done: {
            switch command {
            case .fetch, .fetchAll: String(localized: "Fetched.")
            case .pull, .pullRebase: String(localized: "Pulled.")
            case .push, .forcePush: String(localized: "Pushed.")
            }
        }
    }

    @objc private func helpClicked() {
        GitTransient.show(String(localized: "Git keys"), helpItems, from: table, owner: self)
    }

    var helpItems: [GitTransient.Item] {
        [
            .init(key: "s", title: String(localized: "Stage the selection")) { [weak self] in self?.run(.stage) },
            .init(key: "u", title: String(localized: "Unstage the selection")) { [weak self] in self?.run(.unstage) },
            .init(key: "S", title: String(localized: "Stage everything")) { [weak self] in self?.stageAll() },
            .init(key: "U", title: String(localized: "Unstage everything")) { [weak self] in self?.unstageAll() },
            .init(key: "⇥", title: String(localized: "Show or hide a file’s changes")) { [weak self] in self?.toggleExpansion() },
            .init(key: "⇧⇥", title: String(localized: "Show or hide every file’s changes")) { [weak self] in self?.cycleAllExpansion() },
            .init(key: "d", title: String(localized: "Diff…")) { [weak self] in self?.showDiffTransient() },
            .init(key: "l", title: String(localized: "Log…")) { [weak self] in self?.showLogTransient() },
            .init(key: "b", title: String(localized: "Branches…")) { [weak self] in self?.showBranchTransient() },
            .init(key: "k", title: String(localized: "Discard the selection…")) { [weak self] in self?.discardSelection() },
            .init(key: "z", title: String(localized: "Stash…")) { [weak self] in self?.showStashTransient() },
            .init(key: "r", title: String(localized: "Rebase…")) { [weak self] in self?.showRebaseTransient() },
            .init(key: "f", title: String(localized: "Fetch…")) { [weak self] in self?.showFetchTransient() },
            .init(key: "F", title: String(localized: "Pull…")) { [weak self] in self?.showPullTransient() },
            .init(key: "P", title: String(localized: "Push…")) { [weak self] in self?.showPushTransient() },
            .init(key: "c", title: String(localized: "Commit…")) { [weak self] in self?.showCommitTransient() },
            .init(key: "g", title: String(localized: "Reload")) { [weak self] in self?.reload() },
            .init(key: "↩", title: String(localized: "Show the file in the pane")) { [weak self] in self?.visitSelectedFile() },
            .init(key: "q", title: String(localized: "Back to the files")) { [weak self] in self?.onClose(nil) },
        ]
    }

    // MARK: - Feedback

    /// `done` marks a command that finished; other messages are notes. Under a diff or log the message waits: it's
    /// announced now and shown when they close.
    func show(_ text: String, isError: Bool, done: Bool = false) {
        message = (text, isError)
        messageLabel.stringValue = text
        messageLabel.textColor = isError ? GitColors.deleted : .secondaryLabelColor
        let symbol = isError ? "exclamationmark.triangle.fill" : done ? "checkmark.circle" : "info.circle"
        messageSymbol = symbol
        messageIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        messageIcon.contentTintColor = isError ? GitColors.deleted : done ? GitColors.added : .secondaryLabelColor
        messageRow.isHidden = false
        announce(text)
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: table, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

// MARK: - Rows

extension GitStatusViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GitRowView() }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .section: 28
        case .file, .clean: 22
        case .hunk: 20
        case .line: 16
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: GitStatusCell.identifier, owner: nil) as? GitStatusCell ?? GitStatusCell()
        let content = GitStatusCell.Content(rows[row], status: status, expanded: expanded)
        cell.show(content)
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row] != .clean }
}

// MARK: - Right-click menu

extension GitStatusViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        fill(menu, for: table.clickedRow)
    }

    /// The commands for a right click on `row`; a row outside the selection becomes the selection first, as in the
    /// files. The same commands and titles as the key list.
    @discardableResult
    func contextMenu(for row: Int) -> NSMenu {
        let menu = NSMenu()
        fill(menu, for: row)
        return menu
    }

    private func fill(_ menu: NSMenu, for row: Int) {
        menu.removeAllItems()
        menuActions = []
        guard rows.indices.contains(row), rows[row] != .clean else { return }
        if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
        let keys: [[String]] = [["s", "u", "k"], ["⇥", "↩"], ["c"]]
        let items = helpItems
        for group in keys {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for item in items where group.contains(item.key) {
                let entry = NSMenuItem(title: item.title, action: #selector(menuItemChosen(_:)), keyEquivalent: "")
                entry.target = self
                entry.tag = menuActions.count
                menuActions.append(item.action)
                menu.addItem(entry)
            }
        }
    }

    @objc private func menuItemChosen(_ sender: NSMenuItem) {
        menuActions[safe: sender.tag]?()
    }
}

/// The list: its keys go to the status view first.
final class GitStatusTableView: NSTableView {
    weak var owner: GitStatusViewController?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if modifiers.isEmpty, let characters = event.characters, owner?.handleKey(characters, keyCode: event.keyCode) == true { return }
        super.keyDown(with: event)
    }
}
