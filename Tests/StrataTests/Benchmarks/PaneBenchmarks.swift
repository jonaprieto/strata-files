import AppKit
import Testing
@testable import Strata

/// The pane paths every user crosses, timed for `scripts/benchmark-git.sh`, which runs this file unchanged at a base
/// commit and at HEAD to compare them. Off unless STRATA_BENCHMARK is set; it prints timings and asserts none.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["STRATA_BENCHMARK"] != nil))
struct PaneBenchmarks {
    static func report(_ name: String, _ samples: [Duration]) {
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let ms = Double(median.components.attoseconds) / 1e15 + Double(median.components.seconds) * 1000
        print("BENCH \(name) \(String(format: "%.3f", ms))")
    }

    @Test func navigatingAFolderOfFiveThousandItems() async throws {
        let tree = try TestTree((0..<5_000).map { "big/file-\($0).txt" } + ["small/a"])
        let environment = try IndependentEnvironment()
        let browser = BrowserViewController(services: environment.services)
        _ = browser.view
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for _ in 0..<15 {
            browser.load(tree.url("small"))
            await browser.directoryReads.task?.value
            let start = clock.now
            browser.load(tree.url("big"))
            await browser.directoryReads.task?.value
            samples.append(clock.now - start)
        }
        Self.report("pane.navigate.5000", samples)
        browser.stopBackgroundWork()
        withExtendedLifetime((tree, environment)) {}
    }

    @Test func validatingMenusWithASelection() async throws {
        let tree = try TestTree((0..<200).map { "f-\($0)" })
        let environment = try IndependentEnvironment()
        let browser = BrowserViewController(services: environment.services)
        _ = browser.view
        browser.load(tree.root)
        await browser.directoryReads.task?.value
        browser.select((0..<50).map { tree.url("f-\($0)") })
        let items = [StrataCommand.moveToTrash, .renameSelection, .duplicate, .copy, .paste, .newFolder, .openSelection,
                     .copyPath, .toggleHiddenFiles, .compress].map { $0.menuItem() }
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for _ in 0..<15 {
            let start = clock.now
            for _ in 0..<200 { for item in items { _ = browser.validateMenuItem(item) } }
            samples.append(clock.now - start)
        }
        Self.report("pane.validate.2000", samples)
        browser.stopBackgroundWork()
        withExtendedLifetime((tree, environment)) {}
    }
}
