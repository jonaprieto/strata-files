import AppKit
import StrataModel

final class BrowserStatusView: NSView {
    let label = NSTextField(labelWithString: "")
    let clipboard: ClipboardIndicator

    init(clipboard: Clipboard) {
        self.clipboard = ClipboardIndicator(clipboard: clipboard)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        // A narrow window wraps the details instead of cutting out their middle.
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.cell?.wraps = true
        label.cell?.usesSingleLineMode = false
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        label.setContentHuggingPriority(.init(200), for: .horizontal)
        let stack = NSStackView(views: [label, self.clipboard])
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }
}
