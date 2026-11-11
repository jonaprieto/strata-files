import AppKit
import StrataDev

/// Above the status list: the repository and branch, how far it is from its upstream, any operation in progress, a
/// spinner while git runs, and whether Strata may change the repository.
final class GitStatusHeader: NSView {
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let spinner = NSProgressIndicator()
    let trustButton = NSButton(title: String(localized: "Trust…"), target: nil, action: nil)
    let helpButton = NSButton(title: "?", target: nil, action: nil)
    private let lock = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel(String(localized: "Git is running"))
        trustButton.bezelStyle = .push
        trustButton.controlSize = .small
        trustButton.toolTip = String(localized: "Let Strata change this repository, running its own hooks and filters")
        helpButton.bezelStyle = .circular
        helpButton.controlSize = .small
        helpButton.toolTip = String(localized: "Git keys")
        helpButton.setAccessibilityLabel(String(localized: "Git keys"))
        lock.image = NSImage(systemSymbolName: "lock", accessibilityDescription: String(localized: "Read only"))
        lock.contentTintColor = .secondaryLabelColor
        let texts = NSStackView(views: [title, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        let row = NSStackView(views: [texts, NSView(), spinner, lock, trustButton, helpButton])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(repository: GitRepository, status: GitWorkbenchStatus?, trusted: Bool, busy: Bool) {
        let name = repository.root.lastPathComponent
        let branch = status?.branch.displayName ?? "…"
        title.stringValue = "\(name) · \(branch)"
        var parts: [String] = []
        if let branch = status?.branch {
            if let upstream = branch.upstream {
                parts.append(branch.ahead == 0 && branch.behind == 0
                    ? String(localized: "up to date with \(upstream)")
                    : String(localized: "\(branch.ahead) ahead, \(branch.behind) behind \(upstream)", comment: "Git: commits ahead and behind the upstream branch"))
            } else if !branch.isDetached {
                parts.append(String(localized: "no upstream"))
            }
        }
        if let operation = status?.operation { parts.append(operation.title) }
        if let stashes = status?.stashCount, stashes > 0 { parts.append(String(localized: "\(stashes) stashes", comment: "plural")) }
        if !trusted { parts.append(String(localized: "read only")) }
        detail.stringValue = parts.joined(separator: " · ")
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        lock.isHidden = trusted
        trustButton.isHidden = trusted
        setAccessibilityLabel([title.stringValue, detail.stringValue, busy ? String(localized: "Git is running") : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
    }
}
