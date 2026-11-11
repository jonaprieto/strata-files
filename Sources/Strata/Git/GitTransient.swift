import AppKit

/// Magit's transient menus: a small popover listing the next keys, each also a button. Pressing a key or clicking
/// runs it and closes the popover; Escape closes it.
final class GitTransient: NSViewController {
    struct Item {
        let key: String
        let title: String
        let action: () -> Void
    }

    private let heading: String
    let items: [Item]
    private weak var popover: NSPopover?

    private init(_ heading: String, _ items: [Item]) {
        self.heading = heading
        self.items = items
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Shown next to `view` when it's in a visible window; headless, nothing is shown.
    @discardableResult
    static func show(_ heading: String, _ items: [Item], from view: NSView, owner: NSViewController) -> GitTransient? {
        guard let window = view.window, window.isVisible else { return nil }
        let content = GitTransient(heading, items)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        content.popover = popover
        let anchor = view.visibleRect.isEmpty ? view.bounds : NSRect(x: view.visibleRect.midX, y: view.visibleRect.minY + 4, width: 1, height: 1)
        popover.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
        window.makeFirstResponder(content.view)
        return content
    }

    override func loadView() {
        let keys = TransientView()
        keys.owner = self
        let title = NSTextField(labelWithString: heading)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let stack = NSStackView(views: [title])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        for (index, item) in items.enumerated() {
            let button = NSButton(title: "\(item.key)   \(item.title)", target: self, action: #selector(clicked(_:)))
            button.tag = index
            button.isBordered = false
            button.alignment = .left
            button.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.setAccessibilityLabel(String(localized: "\(item.title), key \(item.key)", comment: "Accessibility: a command in a git menu and its key"))
            stack.addArrangedSubview(button)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        keys.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: keys.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: keys.trailingAnchor),
            stack.topAnchor.constraint(equalTo: keys.topAnchor),
            stack.bottomAnchor.constraint(equalTo: keys.bottomAnchor),
        ])
        keys.setAccessibilityLabel(heading)
        view = keys
    }

    @objc private func clicked(_ sender: NSButton) { run(sender.tag) }

    fileprivate func pressed(_ characters: String) -> Bool {
        if characters == "\u{1b}" { popover?.close(); return true }
        guard let index = items.firstIndex(where: { $0.key == characters }) else { return false }
        run(index)
        return true
    }

    private func run(_ index: Int) {
        popover?.close()
        items[index].action()
    }

    private final class TransientView: NSView {
        weak var owner: GitTransient?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            if let characters = event.characters, owner?.pressed(characters) == true { return }
            super.keyDown(with: event)
        }
    }
}
