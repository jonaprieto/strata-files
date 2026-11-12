import AppKit

extension BrowserWindowController {
    /// Shows or hides the Git History panel beside the files.
    @objc func toggleGitHistory(_ sender: Any?) {
        if split.isHistoryShown { hideGitHistory() } else { showGitHistory() }
        updateGitHistory()
        if split.isHistoryShown, let table = split.history.log?.table { window?.makeFirstResponder(table) }
    }

    /// With two panes the panel takes the other pane's place, as wide as it was. That pane closes rather than hides,
    /// so nothing (Copy To, Move To) can be sent to a pane that isn't shown.
    private func showGitHistory() {
        let other = panes.first { $0 !== pane }
        let width = other?.host.view.frame.width
        if let other {
            paneUnderHistory = other.location
            toggleDualPane(at: nil)
        }
        split.setHistoryShown(true, width: width)
    }

    private func hideGitHistory() {
        split.setHistoryShown(false)
        let folder = paneUnderHistory
        paneUnderHistory = nil
        if let folder, !isDualPane { toggleDualPane(at: folder) }
    }

    /// The panel follows the active pane while it's shown; hidden, it reads nothing.
    func updateGitHistory() {
        guard split.isHistoryShown else { return }
        let history = split.history
        history.paneFolder = { [weak self] in self?.browser.directory }
        history.navigate = { [weak self] folder in self?.navigate(to: folder) }
        history.showDiff = { [weak self] repository, kind, title, focus in
            self?.browser.showGitDiff(kind, title: title, focusing: focus, in: repository)
        }
        history.follow()
    }
}
