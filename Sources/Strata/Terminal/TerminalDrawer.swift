import AppKit
import SwiftTerm

/// What the terminal drawer types for the user, as plain functions. Nothing ends in Return: the user runs it.
enum TerminalText {
    /// Dropped items as shell-quoted paths, each followed by a space. Nil when a name holds a control character,
    /// which a shell's line editor could read as Return or another key.
    static func paths(_ urls: [URL]) -> String? {
        guard !urls.isEmpty else { return nil }
        let paths = urls.map(\.path)
        guard paths.allSatisfy({ path in !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }) else { return nil }
        return paths.map(ShellQuote.quote).joined(separator: " ") + " "
    }

    /// `cd` to `folder`, left for the user to run.
    static func changeDirectory(to folder: URL) -> String? {
        paths([folder]).map { "cd " + $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The user's login shell, or zsh.
    static var shell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }
}

/// A terminal under the panes, one per window, started the first time it's shown, in the active pane's folder.
/// Files dropped on it are typed as quoted paths; "Go to Pane Folder" types a `cd` there. Both wait for Return.
final class TerminalDrawerController: NSViewController {
    static let defaultHeight: CGFloat = 220

    /// Starts the shell; tests count calls instead of starting one.
    var startShell: (DroppingTerminalView, URL?) -> Void = { view, folder in
        view.startProcess(executable: TerminalText.shell, args: ["-l"], environment: nil, execName: nil, currentDirectory: folder?.path)
    }
    /// The active pane's folder, for "Go to Pane Folder" and where the shell starts.
    var paneFolder: () -> URL? = { nil }
    private(set) var isShown = false
    private(set) var hasStarted = false
    private(set) var heightConstraint: NSLayoutConstraint!
    private var shownHeight = TerminalDrawerController.defaultHeight
    let terminal = DroppingTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    private let handle = ResizeHandle()
    private let titleLabel = NSTextField(labelWithString: String(localized: "Terminal"))

    override func loadView() {
        let root = NSView()
        let header = NSStackView()
        header.orientation = .horizontal
        header.edgeInsets = NSEdgeInsets(top: 2, left: 10, bottom: 2, right: 6)
        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        let goHere = NSButton(title: String(localized: "Go to Pane Folder"), target: self, action: #selector(goToPaneFolder))
        goHere.controlSize = .small
        goHere.bezelStyle = .push
        goHere.toolTip = String(localized: "Types cd and the active pane’s folder; press Return to go there")
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Hide Terminal"))!,
                             target: self, action: #selector(hideClicked))
        close.isBordered = false
        close.toolTip = String(localized: "Hide Terminal")
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(goHere)
        header.addArrangedSubview(close)
        terminal.setAccessibilityLabel(String(localized: "Terminal"))
        handle.onDrag = { [weak self] delta in self?.resize(by: delta) }
        handle.setAccessibilityLabel(String(localized: "Terminal height"))
        for subview in [handle, header, terminal] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        heightConstraint = root.heightAnchor.constraint(equalToConstant: 0)
        // Hidden, the drawer is zero high and must never size the window: what's inside gives way and is clipped,
        // so the window's own minimum size and the file canvas stay as they are without it.
        root.clipsToBounds = true
        header.setClippingResistancePriority(.defaultLow, for: .horizontal)
        let yielding = [
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ]
        yielding.forEach { $0.priority = .defaultLow }
        NSLayoutConstraint.activate(yielding + [
            heightConstraint,
            handle.topAnchor.constraint(equalTo: root.topAnchor),
            handle.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            handle.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            handle.heightAnchor.constraint(equalToConstant: 5),
            header.topAnchor.constraint(equalTo: handle.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: header.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        root.isHidden = true
        ThemeStyle.bind(root, to: .content)
        view = root
    }

    func toggle() { isShown ? hide() : show() }

    func show() {
        _ = view
        isShown = true
        view.isHidden = false
        heightConstraint.constant = shownHeight
        if !hasStarted {
            hasStarted = true
            let folder = paneFolder()
            titleLabel.stringValue = folder.map { String(localized: "Terminal: \($0.lastPathComponent)") } ?? String(localized: "Terminal")
            startShell(terminal, folder)
        }
        view.window?.makeFirstResponder(terminal)
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        heightConstraint.constant = 0
        view.isHidden = true
    }

    /// Ends the shell when its window closes.
    func stop() {
        if hasStarted { terminal.terminate() }
    }

    @objc private func hideClicked() { hide() }

    @objc func goToPaneFolder() {
        guard let folder = paneFolder(), let text = TerminalText.changeDirectory(to: folder) else { return Sounds.beep() }
        terminal.send(txt: text)
        view.window?.makeFirstResponder(terminal)
    }

    private func resize(by delta: CGFloat) {
        let limit = max((view.superview?.bounds.height ?? 600) * 0.75, 120)
        shownHeight = min(max(heightConstraint.constant - delta, 80), limit)
        heightConstraint.constant = shownHeight
    }

    /// The drawer's top edge: dragging it changes the drawer's height.
    private final class ResizeHandle: NSView {
        var onDrag: (CGFloat) -> Void = { _ in }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
        override func mouseDragged(with event: NSEvent) { onDrag(-event.deltaY) }
    }
}

/// The terminal view, taking dropped files as quoted paths typed at the prompt.
final class DroppingTerminalView: LocalProcessTerminalView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { Self.urls(sender).isEmpty ? [] : .copy }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { typePaths(Self.urls(sender)) }

    /// Types `urls` at the prompt; false (and nothing typed) when one can't be typed safely.
    @discardableResult
    func typePaths(_ urls: [URL]) -> Bool {
        guard let text = TerminalText.paths(urls) else { Sounds.beep(); return false }
        send(txt: text)
        return true
    }

    private static func urls(_ info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}
