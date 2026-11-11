import AppKit
import StrataDev

/// The plan for an interactive rebase, oldest commit first: a key sets what happens to the selected commit, ⌥↑ and ⌥↓
/// (or dragging) reorder, Return starts, `q` cancels.
final class GitRebaseEditor: NSViewController {
    private(set) var todo: GitRebaseTodo
    let base: String?
    var onStart: (GitRebaseTodo, String?) -> Void = { _, _ in }
    var onCancel: () -> Void = {}
    /// Asks for a reworded message; headless windows give none, which leaves the commit as it is.
    var askMessage: (String, NSWindow?) async -> String? = { initial, window in
        await GitPrompts.askName(String(localized: "New message"), initial, window)
    }
    let table = KeyTable()
    private let note = NSTextField(labelWithString: "")
    private static let dragType = NSPasteboard.PasteboardType("dev.strata.git.rebase-step")

    init(todo: GitRebaseTodo, base: String?) {
        self.todo = todo
        self.base = base
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        table.addTableColumn(NSTableColumn(identifier: .init("step")))
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.rowHeight = 24
        table.style = .plain
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.owner = self
        table.registerForDraggedTypes([Self.dragType])
        table.setAccessibilityLabel(String(localized: "Rebase plan, oldest commit first"))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        ThemeStyle.bind(scroll, to: .content)
        let heading = NSTextField(labelWithString: String(localized: "Rebase, oldest commit first"))
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.stringValue = String(localized: "p pick · r reword · e edit · s squash · f fixup · d drop · ⌥↑ ⌥↓ move · Return start · q cancel")
        for subview in [heading, scroll, note] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            note.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
            note.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            note.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            note.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
        view = root
        if !todo.steps.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    func handleKey(_ characters: String, option: Bool = false) -> Bool {
        let row = table.selectedRow
        if option {
            switch characters {
            case String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)): move(row, by: -1)
            case String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)): move(row, by: 1)
            default: return false
            }
            return true
        }
        switch characters {
        case "p": set(.pick)
        case "e": set(.edit)
        case "s": set(.squash)
        case "f": set(.fixup)
        case "d": set(.drop)
        case "r": reword()
        case "\r": start()
        case "q", "\u{1b}": onCancel()
        case "n", "j": select(row + 1)
        case "k": select(row - 1)
        default: return false
        }
        return true
    }

    func set(_ action: GitRebaseTodo.Action) {
        guard todo.steps.indices.contains(table.selectedRow) else { return }
        let row = table.selectedRow
        todo.steps[row].action = action
        table.reloadData(forRowIndexes: [row], columnIndexes: [0])
        announce(Self.spoken(todo.steps[row]))
    }

    private func reword() {
        let row = table.selectedRow
        guard todo.steps.indices.contains(row) else { return }
        let window = view.window
        let subject = todo.steps[row].commit.subject
        Task { [weak self] in
            guard let message = await self?.askMessage(subject, window), !message.isEmpty else { return }
            self?.set(.reword(message))
        }
    }

    func move(_ row: Int, by step: Int) {
        let target = row + step
        guard todo.steps.indices.contains(row), todo.steps.indices.contains(target) else { return Sounds.beep() }
        todo.move(from: row, to: target)
        table.reloadData()
        select(target)
        announce(String(localized: "Moved to position \(target + 1) of \(todo.steps.count)"))
    }

    private func select(_ row: Int) {
        guard todo.steps.indices.contains(row) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func start() {
        if let problem = todo.problem {
            note.stringValue = problem
            note.textColor = GitColors.deleted
            announce(problem)
            return Sounds.beep()
        }
        onStart(todo, base)
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: table, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    static func spoken(_ step: GitRebaseTodo.Step) -> String {
        "\(title(step.action)), \(step.commit.shortID), \(step.commit.subject)"
    }

    static func title(_ action: GitRebaseTodo.Action) -> String {
        switch action {
        case .pick: String(localized: "pick", comment: "Git rebase action: keep the commit")
        case .reword: String(localized: "reword", comment: "Git rebase action: keep the commit, new message")
        case .edit: String(localized: "edit", comment: "Git rebase action: stop to change the commit")
        case .squash: String(localized: "squash", comment: "Git rebase action: fold into the commit before, joining messages")
        case .fixup: String(localized: "fixup", comment: "Git rebase action: fold into the commit before, keeping its message")
        case .drop: String(localized: "drop", comment: "Git rebase action: leave the commit out")
        }
    }

    final class KeyTable: NSTableView {
        weak var owner: GitRebaseEditor?
        override func keyDown(with event: NSEvent) {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option])
            let option = modifiers == .option
            if modifiers.isEmpty || option, let characters = event.charactersIgnoringModifiers,
               owner?.handleKey(characters, option: option) == true { return }
            super.keyDown(with: event)
        }
    }
}

extension GitRebaseEditor: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { todo.steps.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let step = todo.steps[row]
        let cell = tableView.makeView(withIdentifier: GitStatusCell.identifier, owner: nil) as? GitStatusCell ?? GitStatusCell()
        let mono = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        let color: NSColor = switch step.action {
        case .drop: GitColors.deleted
        case .squash, .fixup: GitColors.renamed
        case .edit, .reword: GitColors.modified
        case .pick: .secondaryLabelColor
        }
        let text = NSMutableAttributedString(string: Self.title(step.action).padding(toLength: 8, withPad: " ", startingAt: 0),
                                             attributes: [.foregroundColor: color, .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .bold)])
        text.append(NSAttributedString(string: step.commit.shortID + "  ", attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: mono]))
        var subject = step.commit.subject
        if case .reword(let message) = step.action { subject = message.split(separator: "\n").first.map(String.init) ?? subject }
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        // A dropped commit is struck through, so it reads apart without relying on color.
        if step.action == .drop { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        text.append(NSAttributedString(string: subject, attributes: attributes))
        cell.show(.init(text: text, accessibility: Self.spoken(step), indent: 0))
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        dropOperation == .above ? .move : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let text = info.draggingPasteboard.string(forType: Self.dragType), let from = Int(text), todo.steps.indices.contains(from) else { return false }
        let to = from < row ? row - 1 : row
        todo.move(from: from, to: min(max(to, 0), todo.steps.count - 1))
        tableView.reloadData()
        return true
    }
}
