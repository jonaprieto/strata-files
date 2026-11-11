import AppKit

/// The commit message editor: a sheet with the message, how long its first line is, and what's staged.
enum GitCommitEditor {
    struct Request: Equatable {
        var amend: Bool
        var message: String
        /// `git diff --cached --stat`.
        var staged: String
    }

    /// The message written, or nil when cancelled or when there's no visible window to ask in.
    static func edit(_ request: Request, in window: NSWindow?) async -> String? {
        guard let window, window.isVisible, window.attachedSheet == nil else { return nil }
        let controller = SheetController(request)
        return await withCheckedContinuation { done in
            // The sheet holds the controller until it closes; close() lets go of it.
            controller.finish = { [controller] in _ = controller; done.resume(returning: $0) }
            window.beginSheet(controller.sheet)
        }
    }

    /// The summary line's length against git's conventions: 50 is the aim, 72 the limit.
    static func summaryNote(_ message: String) -> String {
        let summary = message.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return String(localized: "Summary: \(summary.count) of 50 characters", comment: "Commit editor: length of the first line")
    }

    private final class SheetController: NSObject, NSTextViewDelegate {
        let sheet: NSWindow
        var finish: (String?) -> Void = { _ in }
        private let text = NSTextView()
        private let note = NSTextField(labelWithString: "")

        init(_ request: Request) {
            sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
            super.init()
            sheet.title = request.amend ? String(localized: "Amend Commit") : String(localized: "Commit")
            text.isRichText = false
            text.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            text.string = request.message
            text.isAutomaticQuoteSubstitutionEnabled = false
            text.isAutomaticDashSubstitutionEnabled = false
            text.isAutomaticTextReplacementEnabled = false
            text.delegate = self
            text.setAccessibilityLabel(String(localized: "Commit message"))
            let scroll = NSScrollView()
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            text.autoresizingMask = [.width]
            text.isVerticallyResizable = true
            text.textContainer?.widthTracksTextView = true
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            note.textColor = .secondaryLabelColor
            let staged = NSTextField(wrappingLabelWithString: request.staged.isEmpty ? String(localized: "Nothing staged.") : request.staged)
            staged.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            staged.textColor = .secondaryLabelColor
            staged.setAccessibilityLabel(String(localized: "Staged changes"))
            let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancelled))
            cancel.keyEquivalent = "\u{1b}"
            let commit = NSButton(title: request.amend ? String(localized: "Amend") : String(localized: "Commit"), target: self, action: #selector(committed))
            commit.keyEquivalent = "\r"
            commit.keyEquivalentModifierMask = .command
            commit.toolTip = String(localized: "Command-Return")
            let buttons = NSStackView(views: [note, NSView(), cancel, commit])
            let stack = NSStackView(views: [scroll, staged, buttons])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 10
            stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
            for view in [scroll, staged, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
            sheet.contentView = stack
            sheet.initialFirstResponder = text
            textDidChange(Notification(name: NSText.didChangeNotification))
        }

        func textDidChange(_ notification: Notification) {
            note.stringValue = GitCommitEditor.summaryNote(text.string)
            let length = text.string.split(separator: "\n", omittingEmptySubsequences: false).first?.count ?? 0
            note.textColor = length > 72 ? GitColors.deleted : length > 50 ? GitColors.modified : .secondaryLabelColor
        }

        @objc private func cancelled() { close(nil) }
        @objc private func committed() { close(text.string) }

        private func close(_ result: String?) {
            sheet.sheetParent?.endSheet(sheet)
            let finish = finish
            self.finish = { _ in }
            finish(result)
        }
    }
}
