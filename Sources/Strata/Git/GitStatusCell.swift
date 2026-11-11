import AppKit
import StrataDev

/// One row of a status or diff view: a section title, a file, a hunk header or a diff line, with what VoiceOver reads.
final class GitStatusCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("GitStatusCell")

    struct Content {
        var text: NSAttributedString
        var accessibility: String
        var indent: CGFloat
        /// A faint fill across the row, for added and removed lines.
        var background: NSColor? = nil
        /// Lines shown; each line still ends in an ellipsis rather than wrapping.
        var lines = 1
    }

    private let label = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint!
    private var background: NSColor?
    /// The row's text in its own colors, kept for when the row is no longer selected.
    private var text = NSAttributedString()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
        textField = label
        leading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            leading,
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ content: Content) {
        // An attributed string's own paragraph style wins over the label's line break mode, and its default wraps:
        // in a narrow panel a row would run into the next one.
        let text = NSMutableAttributedString(attributedString: content.text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        self.text = text
        showText()
        // Set every time: a reused cell may come from a row with another count.
        label.maximumNumberOfLines = content.lines
        leading.constant = 8 + content.indent
        setAccessibilityLabel(content.accessibility)
        label.setAccessibilityLabel(content.accessibility)
        background = content.background
        applyBackground()
    }

    /// On the selection's accent color, gray, green or blue text doesn't read: the whole row takes the selection's text
    /// color, as AppKit gives plain labels.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { showText() } }
    }

    private func showText() {
        guard backgroundStyle == .emphasized else { label.attributedStringValue = text; return }
        let selected = NSMutableAttributedString(attributedString: text)
        selected.addAttribute(.foregroundColor, value: NSColor.alternateSelectedControlTextColor, range: NSRange(location: 0, length: selected.length))
        label.attributedStringValue = selected
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }

    private func applyBackground() {
        guard let background else { layer?.backgroundColor = nil; return }
        wantsLayer = true
        var color: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { color = background.cgColor }
        layer?.backgroundColor = color
    }
}

extension GitStatusCell.Content {
    private static var mono: NSFont { .monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular) }

    init(_ row: GitStatusRow, status: GitWorkbenchStatus?, expanded: Set<GitStatusOutline.FileKey>) {
        switch row {
        case .clean:
            self = .init(text: NSAttributedString(string: String(localized: "Nothing to commit, the working files match the last commit."),
                                                  attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]),
                         accessibility: String(localized: "Nothing to commit"), indent: 0)
        case .section(let section, let count):
            self = .section(section.title, count: count)
        case .file(let section, let path, let diff):
            let isExpanded = expanded.contains(.init(section: section, path: path))
            self = .file(path, diff: diff, section: section, expanded: diff == nil ? nil : isExpanded)
        case .hunk(let section, let path, let index):
            let diffs = section == .staged ? status?.staged : status?.unstaged
            guard let hunk = diffs?.first(where: { $0.path == path })?.hunks[safe: index] else { self = .empty; return }
            self = .hunk(hunk, index: index)
        case .line(let section, let path, let hunkIndex, let lineIndex):
            let diffs = section == .staged ? status?.staged : status?.unstaged
            guard let line = diffs?.first(where: { $0.path == path })?.hunks[safe: hunkIndex]?.lines[safe: lineIndex] else { self = .empty; return }
            self = .line(line)
        }
    }

    static let empty = Self(text: NSAttributedString(), accessibility: "", indent: 0)

    static func section(_ title: String, count: Int) -> Self {
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        text.append(NSAttributedString(string: "  \(count)", attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                                                                          .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]))
        return .init(text: text, accessibility: String(localized: "\(title), \(count) files", comment: "plural"), indent: 0)
    }

    /// `expanded` is nil for files with no diff to show (untracked, unmerged).
    static func file(_ path: String, diff: GitFileDiff?, section: GitStatusSection, expanded: Bool?) -> Self {
        let (letter, color, state) = describe(diff, section: section)
        let text = NSMutableAttributedString()
        let disclosure = expanded.map { $0 ? "▾ " : "▸ " } ?? "   "
        text.append(NSAttributedString(string: disclosure, attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: mono]))
        text.append(NSAttributedString(string: letter + "  ", attributes: [.foregroundColor: color, .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .bold)]))
        let shown = diff.flatMap { $0.isRename ? "\($0.oldPath ?? "") → \($0.newPath ?? "")" : nil } ?? path
        text.append(NSAttributedString(string: shown, attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]))
        var spoken = [shown, state]
        if let expanded { spoken.append(expanded ? String(localized: "changes shown") : String(localized: "changes hidden")) }
        return .init(text: text, accessibility: spoken.joined(separator: ", "), indent: 12)
    }

    static func hunk(_ hunk: GitHunk, index: Int) -> Self {
        let header = "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@ \(hunk.section)"
        let text = NSAttributedString(string: header, attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: mono])
        let last = hunk.newStart + max(hunk.newCount - 1, 0)
        let spoken = String(localized: "Hunk \(index + 1), lines \(hunk.newStart) to \(last)", comment: "Accessibility: a block of changes in a file")
        return .init(text: text, accessibility: hunk.section.isEmpty ? spoken : "\(spoken), \(hunk.section)", indent: 28)
    }

    static func line(_ line: GitDiffLine) -> Self {
        let (prefix, color, spoken): (String, NSColor, String) = switch line.kind {
        case .added: ("+", GitColors.added, String(localized: "Added: \(line.text)", comment: "Accessibility: a line added in a diff"))
        case .removed: ("-", GitColors.deleted, String(localized: "Removed: \(line.text)", comment: "Accessibility: a line removed in a diff"))
        case .context: (" ", .labelColor, String(localized: "Unchanged: \(line.text)", comment: "Accessibility: a context line in a diff"))
        case .noNewline: ("\\", .tertiaryLabelColor, String(localized: "No newline at end of file"))
        }
        let text = NSAttributedString(string: prefix + line.text, attributes: [.foregroundColor: color, .font: mono])
        // Faint enough that a selected line still shows its selection through it.
        let fill: NSColor? = switch line.kind {
        case .added: GitColors.added.withAlphaComponent(0.12)
        case .removed: GitColors.deleted.withAlphaComponent(0.12)
        case .context, .noNewline: nil
        }
        return .init(text: text, accessibility: spoken, indent: 28, background: fill)
    }

    private static func describe(_ diff: GitFileDiff?, section: GitStatusSection) -> (String, NSColor, String) {
        switch section {
        case .untracked: return ("?", GitColors.untracked, String(localized: "untracked", comment: "Git file state"))
        case .conflicted: return ("U", GitColors.conflicted, String(localized: "unmerged", comment: "Git file state"))
        case .staged, .unstaged: break
        }
        guard let diff else { return ("M", GitColors.modified, String(localized: "modified", comment: "Git file state")) }
        if diff.isNew { return ("A", GitColors.added, String(localized: "new file", comment: "Git file state")) }
        if diff.isDeleted { return ("D", GitColors.deleted, String(localized: "deleted", comment: "Git file state")) }
        if diff.isRename { return ("R", GitColors.renamed, String(localized: "renamed", comment: "Git file state")) }
        if diff.hunks.isEmpty, diff.oldMode != diff.newMode { return ("T", GitColors.modified, String(localized: "mode changed", comment: "Git file state")) }
        if diff.isBinary { return ("M", GitColors.modified, String(localized: "binary, modified", comment: "Git file state")) }
        return ("M", GitColors.modified, String(localized: "modified", comment: "Git file state"))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// The git lists' rows: a selection is a faint tint of the theme's selection color, so a row's text keeps its own
/// colors (a diff line its red or green, a commit its branches) and an added or removed line's tint shows through it.
/// With Increase Contrast the native selection, and its text color, come back.
final class GitRowView: NSTableRowView {
    private var native: Bool { ThemeStyle.highContrast || effectiveAppearance.isHighContrast }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        native ? super.interiorBackgroundStyle : .normal
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard !native else { return super.drawSelection(in: dirtyRect) }
        guard selectionHighlightStyle != .none else { return }
        ThemeStyle.selection(emphasized: isEmphasized).withAlphaComponent(isEmphasized ? 0.35 : 0.5).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4).fill()
    }
}
