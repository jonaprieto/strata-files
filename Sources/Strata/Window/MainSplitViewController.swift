import AppKit

/// Sidebar | one or two panes (with the status bar under them) | inspector.
final class MainSplitViewController: NSSplitViewController, ThemeSplitWindowContent {
    let sidebar: SidebarViewController
    let panes: PaneContainerViewController
    let inspector: InspectorViewController
    let status: StatusBarController
    let scopeBar = SearchScopeBar()
    let noticeBar = NoticeBar()
    /// The terminal drawer under the panes, hidden until asked for.
    let terminal = TerminalDrawerController()
    /// The Git History panel between the files and the Inspector, collapsed until asked for.
    let history: GitHistoryPanelController
    let historyItem: NSSplitViewItem
    let inspectorItem: NSSplitViewItem

    init(firstPane: PaneHostViewController) {
        let services = firstPane.browser.services
        status = StatusBarController(clipboard: services.clipboard)
        sidebar = SidebarViewController(services: services)
        panes = PaneContainerViewController(first: firstPane)
        inspector = InspectorViewController(services: services)
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        history = GitHistoryPanelController(services: services)
        historyItem = NSSplitViewItem(viewController: history)
        super.init(nibName: nil, bundle: nil)

        // The minimums (100 + 120 + 100) fit inside the window's minimum width (320), so the panes never make the
        // window resize itself: a collapsed inspector peeking out in a narrow window did, and crashed AppKit mid-peek.
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 100
        sidebarItem.maximumThickness = 320
        sidebarItem.addBottomAlignedAccessoryViewController(SidebarFooterController())

        // Keep the split view itself out of the shared footer. Closing a pane can leave its old divider in the
        // backing layer, which otherwise shows through the footer in Columns and Disk Usage.
        let content = NSViewController()
        content.view = NSView()
        ThemeStyle.bind(content.view, to: .content)
        content.addChild(panes)
        panes.view.translatesAutoresizingMaskIntoConstraints = false
        panes.view.clipsToBounds = true
        content.view.addSubview(panes.view)
        content.addChild(terminal)
        terminal.view.translatesAutoresizingMaskIntoConstraints = false
        content.view.addSubview(terminal.view)
        NSLayoutConstraint.activate([
            panes.view.leadingAnchor.constraint(equalTo: content.view.safeAreaLayoutGuide.leadingAnchor),
            panes.view.trailingAnchor.constraint(equalTo: content.view.safeAreaLayoutGuide.trailingAnchor),
            panes.view.topAnchor.constraint(equalTo: content.view.topAnchor),
            panes.view.bottomAnchor.constraint(equalTo: terminal.view.topAnchor),
            terminal.view.leadingAnchor.constraint(equalTo: content.view.safeAreaLayoutGuide.leadingAnchor),
            terminal.view.trailingAnchor.constraint(equalTo: content.view.safeAreaLayoutGuide.trailingAnchor),
            terminal.view.bottomAnchor.constraint(equalTo: content.view.safeAreaLayoutGuide.bottomAnchor),
        ])
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 120
        contentItem.addBottomAlignedAccessoryViewController(status)
        scopeBar.isHidden = true
        contentItem.addTopAlignedAccessoryViewController(scopeBar)
        noticeBar.isHidden = true
        contentItem.addTopAlignedAccessoryViewController(noticeBar)

        inspectorItem.minimumThickness = 100
        inspectorItem.maximumThickness = 440

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        historyItem.minimumThickness = 220
        historyItem.maximumThickness = 520
        historyItem.holdingPriority = .init(260)
        addSplitViewItem(inspectorItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The panel is in the split only while it shows: hidden, even a collapsed item keeps a divider, and the window's
    /// smallest size would no longer fit.
    var isHistoryShown: Bool { splitViewItems.contains(historyItem) }

    /// `width`, in a pane's place: as wide as the pane was, past the panel's usual widest.
    func setHistoryShown(_ shown: Bool, width: CGFloat? = nil) {
        guard shown != isHistoryShown else { return }
        if shown {
            historyItem.maximumThickness = width == nil ? 520 : NSSplitViewItem.unspecifiedDimension
            let index = splitViewItems.firstIndex(of: inspectorItem) ?? splitViewItems.count
            // The panel's frame isn't laid out yet once inserted; the files' right edge before it is where it ends.
            let end = splitView.arrangedSubviews[safe: index - 1]?.frame.maxX ?? 0
            insertSplitViewItem(historyItem, at: index)
            guard let width, index > 0 else { return }
            splitView.layoutSubtreeIfNeeded()
            splitView.setPosition(end - width - splitView.dividerThickness, ofDividerAt: index - 1)
        } else {
            removeSplitViewItem(historyItem)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.autosaveName = "StrataMainSplit"
    }
}
