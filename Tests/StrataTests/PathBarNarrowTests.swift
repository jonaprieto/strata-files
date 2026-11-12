import AppKit
import Testing
@testable import Strata
@testable import StrataDev

/// A pane's address bar in a narrow window: whole folders give way, so what's left shows side by side inside the bar,
/// never drawn over one another, and the current folder stays.
@MainActor struct PathBarNarrowTests {
    @Test func aNarrowBarKeepsItsCrumbsApartAndInside() throws {
        let tree = try TestTree("formal-anoma/audit/")
        let environment = try IndependentEnvironment()
        let services = environment.services
        let bar = PathBar(preferences: services.preferences, places: services.places, index: services.index,
                          copies: services.copies, names: services.folderNames, clipboard: services.clipboard, embedded: true)
        let folder = tree.url("formal-anoma/audit")
        bar.url = folder
        bar.gitRoot = folder
        var model = GitBranchPill.Model(branch: "main")
        model.changes = 1
        bar.branchPill.model = model
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 32))
        bar.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: host.leadingAnchor), bar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bar.topAnchor.constraint(equalTo: host.topAnchor), bar.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        for width in [600.0, 300, 200, 150, 120, 90] {
            host.setFrameSize(NSSize(width: width, height: 32))
            host.layoutSubtreeIfNeeded()
            let shown = all(bar).filter { ($0 is CrumbButton || $0 is GitBranchPill) && !$0.isHiddenOrHasHiddenAncestor }
                .map { $0.convert($0.bounds, to: bar) }.filter { $0.width > 0 }
            // Parent folders give way whole; the current folder always shows, shortened when it must be.
            for frame in shown {
                #expect(frame.minX >= -0.5 && frame.maxX <= bar.bounds.width + 0.5, "width \(width): \(frame) outside \(bar.bounds)")
            }
            let names = all(bar).compactMap { $0 as? CrumbButton }.filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.title)
            #expect(names.last == "audit", "width \(width): \(names)")
        }
        withExtendedLifetime((tree, environment)) {}
    }
}
