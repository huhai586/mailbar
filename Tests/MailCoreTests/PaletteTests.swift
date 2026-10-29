import Testing
@testable import MailCore

@Suite struct PaletteTests {
    @Test func contrastMathMatchesKnownValues() {
        #expect(abs(Palette.contrast(0x000000, 0xFFFFFF) - 21) < 0.01)
        #expect(abs(Palette.contrast(0x777777, 0xFFFFFF) - 4.48) < 0.05)   // 业界常引用的 #777 对白底约 4.48
        #expect(Palette.contrast(0x123456, 0x123456) == 1)
    }

    @Test func ensureLeavesGoodColorsAloneAndFixesBadOnes() {
        #expect(Palette.ensure(0xFFFFFF, ratio: 7, on: [0x000000], toward: 0xFFFFFF) == 0xFFFFFF)
        let fixed = Palette.ensure(0x555555, ratio: 7, on: [0x000000], toward: 0xFFFFFF)
        #expect(Palette.contrast(fixed, 0x000000) >= 7)
        #expect(fixed != 0x555555)
    }

    @Test func everyThemeHasUniqueIDAndReadableText() {
        let ids = Palette.all.map(\.id)
        #expect(Set(ids).count == ids.count && ids.count == 15)
        for p in Palette.all {
            for surface in p.surfaces {
                #expect(Palette.contrast(p.text, surface) >= 7, "\(p.title) text")
                #expect(Palette.contrast(p.muted, surface) >= 4.5, "\(p.title) muted")
                #expect(Palette.contrast(p.faint, surface) >= 4.4, "\(p.title) faint")
            }
        }
    }

    @Test func semanticColorsStayReadableOnTheThemeSurfaces() {
        for p in Palette.all {
            for (name, color) in [("accent", p.accent), ("red", p.red), ("orange", p.orange), ("yellow", p.yellow),
                                  ("green", p.green), ("cyan", p.cyan), ("blue", p.blue), ("purple", p.purple), ("pink", p.pink)] {
                for surface in [p.bg, p.panel, p.unreadFill] {
                    #expect(Palette.contrast(color, surface) >= 4.4, "\(p.title) \(name)")
                }
            }
        }
    }

    @Test func darkFlagMatchesTheBackground() {
        for p in Palette.all { #expect((Palette.luminance(p.bg) < 0.5) == p.isDark, "\(p.title)") }
    }

    @Test func increasedContrastVariantsAreStrongerThanTheNormalOnes() {
        for p in Palette.all {
            #expect(Palette.contrast(p.mutedContrast, p.bg) >= Palette.contrast(p.muted, p.bg) - 0.01, "\(p.title)")
            #expect(Palette.contrast(p.borderContrast, p.bg) >= Palette.contrast(p.border, p.bg), "\(p.title)")
        }
    }

    @Test func resolveFollowsTheSystemOnlyWhenNoThemeIsChosen() {
        #expect(Palette.resolve(id: "monokai", systemDark: false).id == "monokai")
        #expect(Palette.resolve(id: "system", systemDark: true).id == "dark")
        #expect(Palette.resolve(id: "system", systemDark: false).id == "light")
        #expect(Palette.resolve(id: nil, systemDark: true).id == "dark")
    }
}
