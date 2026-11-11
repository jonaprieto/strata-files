import AppKit
import StrataDev

/// A whole diff, read only: unstaged, staged, everything uncommitted, a commit or a range. Every file's changes are
/// shown; Tab folds the selected files, Shift-Tab folds or opens them all, and `q` goes back.
final class GitDiffViewController: NSViewController {
    enum Row: Equatable {
        case file(Int)
        case hunk(Int, Int)
        case line(Int, Int, Int)
        case details
        case empty
    }

    let kind: GitDiffKind
    let heading: String
    private let workbench: GitWorkbench
    var onClose: () -> Void = {}
    private(set) var files: [GitFileDiff] = []
    private(set) var folded: Set<Int> = []
    private(set) var rows: [Row] = []
    private(set) var loadTask: Task<Void, Never>?
    let table = KeyTable()
    private let headingLabel = NSTextField(labelWithString: "")
    let hintLabel = NSTextField(labelWithString: String(localized: "Tab fold · Shift-Tab fold all · n p move · q back", comment: "Git diff: the keys shown under it"))

    init(kind: GitDiffKind, title: String, workbench: GitWorkbench) {
        self.kind = kind
        self.heading = title
        self.workbench = workbench
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        table.addTableColumn(NSTableColumn(identifier: .init("diff")))
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.allowsMultipleSelection = true
        table.style = .plain
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.owner = self
        table.setAccessibilityLabel(heading)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        ThemeStyle.bind(scroll, to: .content)
        headingLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        headingLabel.stringValue = heading
        headingLabel.lineBreakMode = .byTruncatingMiddle
        hintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        for subview in [headingLabel, scroll, hintLabel] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            headingLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            headingLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            headingLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: headingLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hintLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
            hintLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            hintLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
        view = root
        loadTask = Task { [weak self, workbench, kind] in
            let files = await workbench.diff(kind)
            var description: String?
            if case .commit(let id) = kind { description = await workbench.describe(commit: id) }
            guard let self, !Task.isCancelled else { return }
            self.details = description
            self.files = files ?? []
            if files == nil { self.headingLabel.stringValue = String(localized: "\(self.heading): git couldn’t show this diff.") }
            self.rebuild()
        }
    }

    func stop() { loadTask?.cancel() }

    /// A commit's author, date and message, shown above its changes.
    private(set) var details: String?

    private func rebuild() {
        rows = details == nil ? [] : [.details]
        for (fileIndex, file) in files.enumerated() {
            rows.append(.file(fileIndex))
            guard !folded.contains(fileIndex) else { continue }
            for (hunkIndex, hunk) in file.hunks.enumerated() {
                rows.append(.hunk(fileIndex, hunkIndex))
                rows += hunk.lines.indices.map { .line(fileIndex, hunkIndex, $0) }
            }
        }
        if files.isEmpty { rows.append(.empty) }
        table.reloadData()
    }

    func handleKey(_ characters: String) -> Bool {
        switch characters {
        case "\t":
            let chosen = Set(table.selectedRowIndexes.compactMap { index -> Int? in
                switch rows[safe: index] {
                case .file(let file)?, .hunk(let file, _)?, .line(let file, _, _)?: file
                default: nil
                }
            })
            guard !chosen.isEmpty else { return true }
            if chosen.isSubset(of: folded) { folded.subtract(chosen) } else { folded.formUnion(chosen) }
            rebuild()
        case "\u{19}":
            folded = folded.count == files.count ? [] : Set(files.indices)
            rebuild()
        case "q", "\u{1b}": onClose()
        case "n", "j": move(1)
        case "p", "k": move(-1)
        default: return false
        }
        return true
    }

    private func move(_ step: Int) {
        let next = min(max((table.selectedRowIndexes.last ?? -1) + step, 0), rows.count - 1)
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    final class KeyTable: NSTableView {
        weak var owner: GitDiffViewController?
        override func keyDown(with event: NSEvent) {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option])
            if modifiers.isEmpty, let characters = event.characters, owner?.handleKey(characters) == true { return }
            super.keyDown(with: event)
        }
    }
}

extension GitDiffViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .file, .empty: 24
        case .details:
            CGFloat(max(details?.split(separator: "\n", omittingEmptySubsequences: false).count ?? 1, 1)) * 16 + 12
        case .hunk: 20
        case .line: 16
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: GitStatusCell.identifier, owner: nil) as? GitStatusCell ?? GitStatusCell()
        switch rows[row] {
        case .file(let index):
            cell.show(.file(files[index].path, diff: files[index], section: .unstaged, expanded: !folded.contains(index)))
        case .hunk(let file, let hunk):
            cell.show(.hunk(files[file].hunks[hunk], index: hunk))
        case .line(let file, let hunk, let line):
            cell.show(.line(files[file].hunks[hunk].lines[line]))
        case .details:
            let text = NSAttributedString(string: details ?? "", attributes: [.foregroundColor: NSColor.labelColor,
                                                                               .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)])
            cell.show(.init(text: text, accessibility: details ?? "", indent: 0, lines: 0))
        case .empty:
            cell.show(.init(text: NSAttributedString(string: String(localized: "No differences."), attributes: [.foregroundColor: NSColor.secondaryLabelColor]),
                            accessibility: String(localized: "No differences."), indent: 0))
        }
        return cell
    }
}
