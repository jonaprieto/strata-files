import AppKit
import Testing
@testable import Strata

/// The keyboard button and the Shortcuts window: every key Strata answers to, Dired's and git's included.
@Suite struct ShortcutsWindowTests {
    @Test func theKeyboardButtonIsInTheToolbar() {
        let id = BrowserToolbar.identifier(.showShortcuts)
        #expect(BrowserToolbar.defaults.contains(id))
        #expect(BrowserToolbar.label(.showShortcuts) == String(localized: "Keys"))
        #expect(StrataCommand.showShortcuts.image != nil)
    }

    /// Every letter Dired answers to is listed, and nothing it doesn't.
    @Test func theDiredSectionListsExactlyItsKeys() throws {
        let dired = try #require(ShortcutsWindowController.sections.first { $0.title == ShortcutsWindowController.diredTitle })
        let listed = Set(dired.items.flatMap(\.keys))
        let candidates = (UInt8(33)...UInt8(126)).map { String(UnicodeScalar($0)) }
        let handled = Set(candidates.filter { DiredKey($0) != nil })
        // j and k are named in the n and p row's text rather than as keys of their own.
        #expect(listed == handled.subtracting(["j", "k"]))
        #expect(dired.items.contains { $0.keys == ["n", "p"] && String(localized: $0.action).contains("j, k") })
    }

    @Test func gitAndTerminalKeysAreFoundBySearch() throws {
        let window = ShortcutsWindowController(restoresFrame: false)
        defer { window.window?.contentView = nil }
        for (query, expected) in [("stage", "Stage, unstage (S, U: everything)"), ("history", "Git history beside the files"),
                                  ("terminal", "Terminal under the panes"), ("dired", "Move to Trash")] {
            #expect(window.shownActions(matching: query).contains(String(localized: String.LocalizationValue(expected))), "\(query)")
        }
    }
}
