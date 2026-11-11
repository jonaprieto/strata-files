import AppKit

extension BrowserWindowController {
    /// Shows or hides the terminal under the panes; the first time, its shell starts in the active pane's folder.
    @objc func toggleTerminalDrawer(_ sender: Any?) {
        let drawer = split.terminal
        drawer.paneFolder = { [weak self] in
            // A folder on this Mac: a server's, a container's or an archive's copy is no place for a shell.
            guard let browser = self?.browser, !browser.isOnServer, !browser.isInsideArchive, !browser.isInContainerCopy,
                  let folder = browser.directory, !browser.services.copies.isCopy(folder) else { return nil }
            return folder
        }
        drawer.toggle()
        if !drawer.isShown { window?.makeFirstResponder(browser.activeView?.focusView ?? browser.outlineView) }
    }
}
