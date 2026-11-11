import AppKit

/// The questions git commands ask: a name, one of several choices, a confirmation. Each is a sheet on a visible
/// window; with no window to ask in, the answer is the one that changes nothing.
struct GitPrompts {
    var name: (_ title: String, _ initial: String, _ window: NSWindow?) async -> String? = GitPrompts.askName
    var choose: (_ title: String, _ options: [String], _ window: NSWindow?) async -> String? = GitPrompts.askChoice
    var confirm: (_ title: String, _ detail: String, _ button: String, _ window: NSWindow?) async -> Bool = GitPrompts.askConfirmation

    private static func canAsk(in window: NSWindow?) -> NSWindow? {
        guard let window, window.isVisible, window.attachedSheet == nil else { return nil }
        return window
    }

    private static func run(_ alert: NSAlert, in window: NSWindow) async -> Bool {
        await withCheckedContinuation { done in
            alert.beginSheetModal(for: window) { done.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }

    static func askName(_ title: String, _ initial: String, _ window: NSWindow?) async -> String? {
        guard let window = canAsk(in: window) else { return nil }
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.setAccessibilityLabel(title)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        guard await run(alert, in: window) else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    static func askChoice(_ title: String, _ options: [String], _ window: NSWindow?) async -> String? {
        guard let window = canAsk(in: window), !options.isEmpty else { return nil }
        let alert = NSAlert()
        alert.messageText = title
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        popup.addItems(withTitles: options)
        popup.setAccessibilityLabel(title)
        alert.accessoryView = popup
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard await run(alert, in: window) else { return nil }
        return popup.titleOfSelectedItem
    }

    static func askConfirmation(_ title: String, _ detail: String, _ button: String, _ window: NSWindow?) async -> Bool {
        guard let window = canAsk(in: window) else { return false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: String(localized: "Cancel"))
        // The safe choice answers Return.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        return await run(alert, in: window)
    }
}
