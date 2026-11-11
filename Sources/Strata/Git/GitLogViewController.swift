import AppKit
import StrataDev

/// The history, newest first, with its graph: each commit's lane, where branches fork and merge, and the branches and
/// tags at it. Return shows a commit's changes; with two commits selected, `d` shows what changed between them.
final class GitLogViewController: NSViewController {
    static let pageSize = 500

    let all: Bool
    private let workbench: GitWorkbench
    var onClose: () -> Void = {}
    var onShowDiff: (GitDiffKind, String) -> Void = { _, _ in }
    var onReset: (GitCommit) -> Void = { _ in }
    /// Rebase from the selected commit (it and every newer one).
    var onRebase: (GitCommit) -> Void = { _ in }
    private(set) var commits: [GitCommit] = []
    private(set) var graph: [GitGraphRow] = []
    private(set) var hasMore = true
    private(set) var loadTask: Task<Void, Never>?
    let table = KeyTable()
    private let headingLabel = NSTextField(labelWithString: "")

    init(all: Bool, workbench: GitWorkbench) {
        self.all = all
        self.workbench = workbench
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var heading: String { all ? String(localized: "History of all branches") : String(localized: "History of the current branch") }

    override func loadView() {
        let root = NSView()
        for (identifier, width) in [("graph", 80.0), ("commit", 400.0)] {
            let column = NSTableColumn(identifier: .init(identifier))
            column.width = width
            if identifier == "graph" { column.resizingMask = [] }
            table.addTableColumn(column)
        }
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.rowHeight = 22
        table.allowsMultipleSelection = true
        table.style = .plain
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.owner = self
        table.target = self
        table.doubleAction = #selector(showSelected)
        table.setAccessibilityLabel(heading)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        ThemeStyle.bind(scroll, to: .content)
        headingLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        headingLabel.stringValue = heading
        for subview in [headingLabel, scroll] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            headingLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            headingLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: headingLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        loadMore()
    }

    func stop() { loadTask?.cancel() }

    /// The next page, appended; the graph is laid out again over everything loaded so lanes stay continuous.
    func loadMore() {
        guard hasMore, loadTask == nil else { return }
        let skip = commits.count
        loadTask = Task { [weak self, workbench, all] in
            let page = await workbench.log(all: all, skip: skip, limit: Self.pageSize)
            guard let self, !Task.isCancelled else { return }
            self.loadTask = nil
            guard let page else {
                self.headingLabel.stringValue = String(localized: "\(self.heading): git couldn’t read the history.")
                self.hasMore = false
                return
            }
            self.hasMore = page.count == Self.pageSize
            self.commits += page
            self.graph = GitGraph.layout(self.commits)
            self.table.reloadData()
            if skip == 0, !self.commits.isEmpty { self.table.selectRowIndexes([0], byExtendingSelection: false) }
        }
    }

    var selectedCommits: [GitCommit] { table.selectedRowIndexes.compactMap { commits[safe: $0] } }

    @objc func showSelected() {
        guard let commit = selectedCommits.first else { return Sounds.beep() }
        onShowDiff(.commit(commit.id), String(localized: "Commit \(commit.shortID): \(commit.subject)"))
    }

    /// Two commits: what changed from the older to the newer.
    func diffSelected() {
        let chosen = table.selectedRowIndexes.filter { commits.indices.contains($0) }
        guard chosen.count == 2, let first = chosen.first, let last = chosen.last else { return showSelected() }
        // Rows run newest first.
        let newer = commits[first], older = commits[last]
        onShowDiff(.range(older.id, newer.id), "\(older.shortID)..\(newer.shortID)")
    }

    func handleKey(_ characters: String) -> Bool {
        switch characters {
        case "\r": showSelected()
        case "d": diffSelected()
        case "x": if let commit = selectedCommits.first { onReset(commit) } else { Sounds.beep() }
        case "r": if let commit = selectedCommits.first { onRebase(commit) } else { Sounds.beep() }
        case "q", "\u{1b}": onClose()
        case "n", "j": move(1)
        case "p", "k": move(-1)
        default: return false
        }
        return true
    }

    private func move(_ step: Int) {
        guard !commits.isEmpty else { return }
        let next = min(max((table.selectedRowIndexes.last ?? -1) + step, 0), commits.count - 1)
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    final class KeyTable: NSTableView {
        weak var owner: GitLogViewController?
        override func keyDown(with event: NSEvent) {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option])
            if modifiers.isEmpty, let characters = event.characters, owner?.handleKey(characters) == true { return }
            super.keyDown(with: event)
        }
    }

    /// What VoiceOver reads for a commit.
    static func spoken(_ commit: GitCommit) -> String {
        var parts = [commit.shortID, commit.subject, String(localized: "by \(commit.author)"),
                     RelativeDateTimeFormatter().localizedString(for: commit.date, relativeTo: Date())]
        if !commit.refs.isEmpty { parts.append(commit.refs.joined(separator: ", ")) }
        if commit.isMerge { parts.append(String(localized: "merge", comment: "Accessibility: a merge commit")) }
        return parts.joined(separator: ", ")
    }
}

extension GitLogViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { commits.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if row >= commits.count - 50 { loadMore() }
        let commit = commits[row]
        if tableColumn?.identifier.rawValue == "graph" {
            let view = tableView.makeView(withIdentifier: GitGraphCell.identifier, owner: nil) as? GitGraphCell ?? GitGraphCell()
            view.row = graph[safe: row]
            view.isMerge = commit.isMerge
            view.setAccessibilityElement(false)
            return view
        }
        let cell = tableView.makeView(withIdentifier: GitStatusCell.identifier, owner: nil) as? GitStatusCell ?? GitStatusCell()
        let text = NSMutableAttributedString()
        let mono = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        text.append(NSAttributedString(string: commit.shortID + "  ", attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: mono]))
        for ref in commit.refs {
            let color = ref.hasPrefix("tag: ") ? GitColors.modified : ref.contains("/") ? GitColors.renamed : GitColors.added
            text.append(NSAttributedString(string: "[\(ref)] ", attributes: [.foregroundColor: color, .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)]))
        }
        text.append(NSAttributedString(string: commit.subject, attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]))
        let date = RelativeDateTimeFormatter().localizedString(for: commit.date, relativeTo: Date())
        text.append(NSAttributedString(string: "  \(commit.author), \(date)", attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]))
        cell.show(.init(text: text, accessibility: Self.spoken(commit), indent: 0))
        return cell
    }
}

/// The graph for one row: lanes passing by, lanes ending at the commit, lanes it continues into, and its dot.
final class GitGraphCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("GitGraphCell")
    static let laneWidth: CGFloat = 12
    var row: GitGraphRow? { didSet { needsDisplay = true } }
    var isMerge = false { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    static func color(_ lane: Int) -> NSColor {
        let colors = [GitColors.renamed, GitColors.added, GitColors.modified, GitColors.conflicted, GitColors.untracked, GitColors.deleted]
        return colors[lane % colors.count]
    }

    static func x(_ lane: Int) -> CGFloat { 8 + CGFloat(lane) * laneWidth }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let middle = bounds.midY
        func line(_ lane: Int, from: NSPoint, to: NSPoint) {
            Self.color(lane).setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.move(to: from)
            if from.x == to.x {
                path.line(to: to)
            } else {
                path.curve(to: to, controlPoint1: NSPoint(x: from.x, y: (from.y + to.y) / 2), controlPoint2: NSPoint(x: to.x, y: (from.y + to.y) / 2))
            }
            path.stroke()
        }
        let node = NSPoint(x: Self.x(row.node), y: middle)
        for lane in row.passing { line(lane, from: NSPoint(x: Self.x(lane), y: 0), to: NSPoint(x: Self.x(lane), y: bounds.maxY)) }
        for lane in row.incoming { line(lane, from: NSPoint(x: Self.x(lane), y: 0), to: node) }
        for lane in row.outgoing { line(lane, from: node, to: NSPoint(x: Self.x(lane), y: bounds.maxY)) }
        let dot = NSBezierPath(ovalIn: NSRect(x: node.x - 4, y: node.y - 4, width: 8, height: 8))
        Self.color(row.node).setFill()
        Self.color(row.node).setStroke()
        dot.lineWidth = 1.5
        // A merge is drawn hollow, so it reads apart from an ordinary commit without relying on color.
        if isMerge { dot.stroke() } else { dot.fill() }
    }
}
