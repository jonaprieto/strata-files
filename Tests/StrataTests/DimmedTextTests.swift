import AppKit
import Testing
@testable import Strata

/// Hidden, git-ignored and cut items read fainter than the rest, yet stay readable on every theme's file list.
@Suite struct DimmedTextTests {
    /// `color` laid over `background` as drawn, both in `appearance`.
    private func contrast(_ color: NSColor, over background: NSColor, in appearance: NSAppearance) throws -> Double {
        var pair: (NSColor, NSColor)?
        appearance.performAsCurrentDrawingAppearance {
            if let text = color.usingColorSpace(.sRGB), let back = background.usingColorSpace(.sRGB) { pair = (text, back) }
        }
        let (text, back) = try #require(pair)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a * text.alphaComponent + b * (1 - text.alphaComponent) }
        func luminance(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Double {
            func linear(_ c: CGFloat) -> Double { Double(c) <= 0.04045 ? Double(c) / 12.92 : pow((Double(c) + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        let front = luminance(mix(text.redComponent, back.redComponent), mix(text.greenComponent, back.greenComponent),
                              mix(text.blueComponent, back.blueComponent))
        let behind = luminance(back.redComponent, back.greenComponent, back.blueComponent)
        return (max(front, behind) + 0.05) / (min(front, behind) + 0.05)
    }

    @Test func dimmedTextReadsOnEveryThemesFileList() throws {
        for (name, dark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
            let appearance = try #require(NSAppearance(named: name))
            for palette in ColorTheme.allCases {
                for role in [ThemeSurfaceRole.content, .alternatingRow] {
                    let surface = palette == .system ? NSColor.controlBackgroundColor : palette.surface(role, dark: dark)
                    for (label, color) in [("name", DimmedText.name), ("detail", DimmedText.detail)] {
                        #expect(try contrast(color, over: surface, in: appearance) >= 3, "\(label) on \(palette) \(role), \(name)")
                    }
                    // Still fainter than what isn't dimmed.
                    #expect(try contrast(DimmedText.detail, over: surface, in: appearance)
                            < contrast(.labelColor, over: surface, in: appearance), "\(palette) \(role), \(name)")
                }
            }
        }
    }

    /// The List's date, size and kind columns use it for a dimmed item, and their usual gray otherwise.
    @Test func theListsColumnsUseIt() {
        let cell = TextCellView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        cell.configure("Today at 12:34", alignment: .left, dimmed: true)
        #expect(cell.textField?.textColor == DimmedText.detail)
        cell.configure("Today at 12:34", alignment: .left, dimmed: false)
        #expect(cell.textField?.textColor == .secondaryLabelColor)
    }
}
