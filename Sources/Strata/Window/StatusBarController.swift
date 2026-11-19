import AppKit

/// Item count, selection size and free space, attached under the file list.
final class StatusBarController: NSSplitViewItemAccessoryViewController {
    var details: String? {
        get { status.label.toolTip }
        set { status.label.toolTip = newValue }
    }
    private let status: BrowserStatusView

    init(clipboard: Clipboard) {
        status = BrowserStatusView(clipboard: clipboard)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    override func loadView() {
        let container = ThemeAccessoryView()
        status.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(status)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            { let usual = container.heightAnchor.constraint(equalToConstant: 28); usual.priority = .defaultLow; return usual }(),
            status.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            status.topAnchor.constraint(equalTo: container.topAnchor),
            status.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    /// Lines break between the details, never inside one ("5 items", a branch's state).
    var text = "" {
        didSet {
            status.label.stringValue = text.components(separatedBy: " · ")
                .map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }.joined(separator: " · ")
        }
    }
}
