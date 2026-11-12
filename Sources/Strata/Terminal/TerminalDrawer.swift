import AppKit
import SwiftTerm

/// What the terminal drawer types for the user, as plain functions. Only taking an idle shell to the pane's folder ends
/// in Return; everything else waits for the user to run it.
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

    /// Takes a shell waiting at its prompt to `folder`: Ctrl-E Ctrl-U clear anything typed there, and the leading space
    /// keeps the line out of a history that ignores such lines. Nil while a program runs in the shell (the keys would go
    /// to it), when the shell is already there, or when the folder's name can't be typed safely.
    static func follow(to folder: URL?, shellIn current: String?, atPrompt: Bool) -> String? {
        guard atPrompt, let folder, let text = changeDirectory(to: folder) else { return nil }
        // ponytail: compared as spelled (/private/var as /var); a folder reached through another link is typed again.
        if let current, PathSpelling.short(URL(fileURLWithPath: current)) == PathSpelling.short(folder) { return nil }
        return "\u{05}\u{15} " + text + "\r"
    }

    /// The working folder of process `pid`, as the system has it.
    static func folder(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
            bytes.bindMemory(to: CChar.self).baseAddress.map { String(cString: $0) }
        }
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

/// A terminal under the panes, one per window, started the first time it's shown, in the active pane's folder; shown
/// again, a shell idle at its prompt goes to the active pane's folder. Files dropped on it are typed as quoted paths;
/// "Go to Pane Folder" types a `cd` there. Both wait for Return.
final class TerminalDrawerController: NSViewController {
    enum Edge { case bottom, right }
    static let defaultHeight: CGFloat = 220
    static let defaultWidth: CGFloat = 420
    private let preferences: Prefs
    /// Under the panes or at their right; the choice is kept for new windows.
    private(set) var edge: Edge
    /// The drawer moved to the other edge: its window places it there.
    var onEdgeChange: () -> Void = {}

    /// Starts the shell; tests count calls instead of starting one.
    var startShell: (DroppingTerminalView, URL?) -> Void = { view, folder in
        view.startProcess(executable: TerminalText.shell, args: ["-l"], environment: nil, execName: nil, currentDirectory: folder?.path)
    }
    /// The active pane's folder, for "Go to Pane Folder" and where the shell starts.
    var paneFolder: () -> URL? = { nil }
    /// The shell's folder, and whether it waits at its prompt with no program in front; tests set it.
    lazy var shellState: () -> (folder: String?, atPrompt: Bool) = { [weak self] in
        guard let process = self?.terminal.process, process.running else { return (nil, false) }
        return (TerminalText.folder(of: process.shellPid), tcgetpgrp(process.childfd) == process.shellPid)
    }
    /// Types into the shell; tests record it instead.
    lazy var type: (String) -> Void = { [weak self] text in self?.terminal.send(txt: text) }
    private(set) var isShown = false
    private(set) var hasStarted = false
    /// The drawer's height under the panes, its width at their right; zero while hidden.
    private(set) var sizeConstraint: NSLayoutConstraint!
    private var shownSize: [Edge: CGFloat] = [.bottom: TerminalDrawerController.defaultHeight, .right: TerminalDrawerController.defaultWidth]
    let terminal = DroppingTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    let handle = ResizeHandle()
    private let titleLabel = NSTextField(labelWithString: String(localized: "Terminal"))
    private let edgeButton = NSButton()
    private var edgeLayout: [NSLayoutConstraint] = []
    private var header: NSStackView!

    init(preferences: Prefs) {
        self.preferences = preferences
        edge = preferences.terminalAtRight ? .right : .bottom
        super.init(nibName: nil, bundle: nil)
        preferences.notifications.addObserver(self, selector: #selector(settingsChanged), name: .terminalChanged, object: preferences)
    }

    /// Settings ▸ Terminal changed, or another window's drawer moved: this one follows.
    @objc private func settingsChanged() {
        _ = view
        applyFont()
        let wanted: Edge = preferences.terminalAtRight ? .right : .bottom
        guard wanted != edge else { return }
        edge = wanted
        layOutForEdge()
        onEdgeChange()
    }

    private func applyFont() {
        terminal.font = TerminalFonts.font(family: preferences.terminalFontFamily, size: preferences.terminalFontSize)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        let header = NSStackView()
        self.header = header
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
        edgeButton.isBordered = false
        edgeButton.target = self
        edgeButton.action = #selector(moveToOtherEdge)
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(goHere)
        header.addArrangedSubview(edgeButton)
        header.addArrangedSubview(close)
        terminal.setAccessibilityLabel(String(localized: "Terminal"))
        handle.onDrag = { [weak self] delta in self?.resize(by: delta) }
        for subview in [handle, header, terminal] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
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
            header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: header.bottomAnchor),
            terminal.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        root.isHidden = true
        ThemeStyle.bind(root, to: .content)
        view = root
        layOutForEdge()
        applyFont()
    }

    /// The drag handle runs along the edge facing the panes: the top under them, the left side at their right.
    private func layOutForEdge() {
        let root = view
        NSLayoutConstraint.deactivate(edgeLayout + [sizeConstraint].compactMap { $0 })
        let size = isShown ? shownSize[edge]! : 0
        switch edge {
        case .bottom:
            sizeConstraint = root.heightAnchor.constraint(equalToConstant: size)
            edgeLayout = [
                handle.topAnchor.constraint(equalTo: root.topAnchor),
                handle.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                handle.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                handle.heightAnchor.constraint(equalToConstant: 5),
                header.topAnchor.constraint(equalTo: handle.bottomAnchor),
                header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                terminal.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            ]
        case .right:
            sizeConstraint = root.widthAnchor.constraint(equalToConstant: size)
            edgeLayout = [
                handle.topAnchor.constraint(equalTo: root.topAnchor),
                handle.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                handle.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                handle.widthAnchor.constraint(equalToConstant: 5),
                header.topAnchor.constraint(equalTo: root.topAnchor),
                header.leadingAnchor.constraint(equalTo: handle.trailingAnchor),
                terminal.leadingAnchor.constraint(equalTo: handle.trailingAnchor),
            ]
        }
        NSLayoutConstraint.activate(edgeLayout + [sizeConstraint])
        handle.vertical = edge == .bottom
        handle.setAccessibilityLabel(edge == .bottom ? String(localized: "Terminal height") : String(localized: "Terminal width"))
        let (symbol, title) = edge == .bottom
            ? ("rectangle.righthalf.inset.filled", String(localized: "Move Terminal to the Right"))
            : ("rectangle.bottomhalf.inset.filled", String(localized: "Move Terminal to the Bottom"))
        edgeButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        edgeButton.toolTip = title
    }

    /// Under the panes or at their right, whichever it isn't; new windows open it there too.
    @objc func moveToOtherEdge() {
        // Saved, every drawer follows (this one included) through `settingsChanged`.
        preferences.terminalAtRight = edge == .bottom
    }

    func toggle() { isShown ? hide() : show() }

    func show() {
        _ = view
        isShown = true
        view.isHidden = false
        sizeConstraint.constant = shownSize[edge]!
        let folder = paneFolder()
        if !hasStarted {
            hasStarted = true
            showTitle(folder)
            startShell(terminal, folder)
        } else {
            let shell = shellState()
            if let text = TerminalText.follow(to: folder, shellIn: shell.folder, atPrompt: shell.atPrompt) {
                type(text)
                showTitle(folder)
            }
        }
        view.window?.makeFirstResponder(terminal)
    }

    private func showTitle(_ folder: URL?) {
        titleLabel.stringValue = folder.map { String(localized: "Terminal: \($0.lastPathComponent)") } ?? String(localized: "Terminal")
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        sizeConstraint.constant = 0
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

    /// `delta` toward the panes grows the drawer.
    private func resize(by delta: CGFloat) {
        let room = edge == .bottom ? view.superview?.bounds.height : view.superview?.bounds.width
        let limit = max((room ?? 600) * 0.75, 120)
        let size = min(max(sizeConstraint.constant + delta, edge == .bottom ? 80 : 160), limit)
        shownSize[edge] = size
        sizeConstraint.constant = size
    }

    /// The drawer's edge facing the panes: dragging it changes the drawer's height, or its width at their right.
    final class ResizeHandle: NSView {
        var onDrag: (CGFloat) -> Void = { _ in }
        var vertical = true { didSet { window?.invalidateCursorRects(for: self) } }
        private var last: NSPoint?
        override func resetCursorRects() { addCursorRect(bounds, cursor: vertical ? .resizeUpDown : .resizeLeftRight) }
        override func mouseDown(with event: NSEvent) { last = event.locationInWindow }
        override func mouseUp(with event: NSEvent) { last = nil }
        /// Measured in the window, where up is positive: up, toward the panes above, or left, toward the panes beside,
        /// grows the drawer.
        override func mouseDragged(with event: NSEvent) {
            let point = event.locationInWindow
            defer { last = point }
            guard let last else { return }
            onDrag(vertical ? point.y - last.y : last.x - point.x)
        }
    }
}

/// The drawer's fonts: installed families whose letters are all one width, as a terminal needs.
enum TerminalFonts {
    static func families() -> [String] {
        NSFontManager.shared.availableFontFamilies.filter {
            NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: 12)?.isFixedPitch == true
        }
    }

    /// `family` at `size`; the system's monospaced font when there's no such family or its letters vary in width.
    static func font(family: String?, size: CGFloat) -> NSFont {
        if let family, let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size), font.isFixedPitch {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// The 16 ANSI colors programs choose from, one set for dark and one for light. SwiftTerm's own were drawn for a black
/// background: its blue was too dark to read on a dark theme. These read on every theme's text previews (the terminal's
/// background): soft tones on dark, deep ones on light.
enum TerminalPalette {
    static func colors(dark: Bool) -> [NSColor] {
        (dark ? Self.dark : Self.light).map { hex in
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }

    // Black, red, green, yellow, blue, magenta, cyan, white; then their bright forms.
    private static let dark: [Int] = [
        0x45475A, 0xFFB0C3, 0xA6E3A1, 0xF9E2AF, 0xA4C8FF, 0xF5C2E7, 0x94E2D5, 0xC6CCE4,
        0xA0A4BC, 0xFFC0CF, 0xB9F2B4, 0xFFF0C2, 0xB8D4FF, 0xFFD3F0, 0xA8F0E4, 0xE6EBFF,
    ]
    private static let light: [Int] = [
        0x303446, 0xB4002D, 0x1F6E1F, 0x7A4F00, 0x1E50B8, 0x8E2AA0, 0x0D6470, 0xC8CCD8,
        0x6C6F85, 0xA8002A, 0x1A651A, 0x704800, 0x1A48A8, 0x822496, 0x0B5C67, 0xEFF1F5,
    ]
}

/// The terminal view, taking dropped files as quoted paths typed at the prompt.
final class DroppingTerminalView: LocalProcessTerminalView, ColorThemeUpdating {
    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// Another theme chosen in Settings: its background.
    func updateColorTheme() { applyColors() }

    /// SwiftTerm keeps its text and background colors as fixed values, read once under whatever appearance was current
    /// then: in a dark window it showed black text. They're read again for this view's appearance whenever it changes,
    /// the background from the theme's text previews.
    private func applyColors() {
        var colors: (text: NSColor, background: NSColor)?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if let text = NSColor.textColor.usingColorSpace(.sRGB), let background = ThemeStyle.surface(.preview).usingColorSpace(.sRGB) {
                colors = (text, background)
            }
        }
        guard let colors else { return }
        nativeForegroundColor = colors.text
        nativeBackgroundColor = colors.background
        installColors(TerminalPalette.colors(dark: effectiveAppearance.isDark).map { color in
            Color(red: UInt16(color.redComponent * 65535), green: UInt16(color.greenComponent * 65535), blue: UInt16(color.blueComponent * 65535))
        })
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
