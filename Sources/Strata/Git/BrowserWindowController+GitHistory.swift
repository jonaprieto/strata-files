import AppKit

extension BrowserWindowController {
    /// Shows or hides the Git History panel beside the files.
    @objc func toggleGitHistory(_ sender: Any?) {
        split.setHistoryShown(!split.isHistoryShown)
        updateGitHistory()
        if split.isHistoryShown, let table = split.history.log?.table { window?.makeFirstResponder(table) }
    }

    /// The panel follows the active pane while it's shown; hidden, it reads nothing.
    func updateGitHistory() {
        guard split.isHistoryShown else { return }
        let history = split.history
        history.paneFolder = { [weak self] in self?.browser.directory }
        history.navigate = { [weak self] folder in self?.navigate(to: folder) }
        history.showDiff = { [weak self] repository, kind, title in self?.browser.showGitDiff(kind, title: title, in: repository) }
        history.follow()
    }
}
