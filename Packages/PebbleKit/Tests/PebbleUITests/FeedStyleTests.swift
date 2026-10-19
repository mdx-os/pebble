#if canImport(SwiftUI)
import Foundation
import PebbleCore
import SwiftUI
import Testing
@testable import PebbleUI

/// Today's card look: the warm card in dark keeps every word readable, and
/// the grid gives each device the columns it should.
@MainActor
struct FeedStyleTests {
    // MARK: The warm card

    /// Every ink a card writes in, on the warm card and on what sits on it
    /// (the accent wash of a soft button, a chip's neutral wash), over both
    /// ends of the backdrop and a sheet, in both schemes, clears 4.5 to 1.
    @Test(arguments: [ColorScheme.light, .dark])
    func wordsOnTheWarmCardAreReadable(scheme: ColorScheme) {
        let ink: Contrast.RGB = scheme == .dark ? .white : .black
        let ends = Theme.backdropEnds(scheme)
        let inks: [(String, Contrast.RGB)] = [
            ("primary", ink),
            ("secondaryText", Theme.secondaryText.rgb(scheme)),
            ("accentText", Theme.accentText.rgb(scheme)),
            ("dangerText", Theme.dangerText.rgb(scheme)),
        ]
        for (baseName, base) in [("backdrop top", ends.top), ("backdrop bottom", ends.bottom),
                                 ("sheet", Theme.sheetRGB(scheme))] {
            let card = FeedStyle.warmCard(over: base, scheme)
            let surfaces: [(String, Contrast.RGB)] = [
                ("warm card", card),
                ("accent wash on the warm card", Theme.accentRGB.over(card, opacity: Theme.accentWash)),
                ("chip on the warm card", ink.over(card, opacity: Theme.fieldTint)),
                ("disabled button on the warm card", ink.over(card, opacity: Theme.disabledTint)),
            ]
            for (inkName, color) in inks {
                for (surfaceName, surface) in surfaces {
                    let ratio = color.contrast(with: surface)
                    #expect(ratio >= 4.5, "\(inkName) on \(surfaceName) over \(baseName) in \(scheme) is \(ratio)")
                }
            }
        }
    }

    /// Light mode has no warmth, so its cards are exactly the pairs
    /// `Theme.textPairs` already checks.
    @Test func lightCardsAreTheThemesOwn() {
        #expect(FeedStyle.warmth(.light) == 0)
        let base = Theme.backdropEnds(.light).top
        #expect(FeedStyle.warmCard(over: base, .light) == Contrast.RGB.white.over(base, opacity: Theme.cardOpacity(.light)))
    }

    /// The warm card in dark is a charcoal, never near black, and warmer
    /// than the plain card: more red than blue.
    @Test func darkCardsAreWarmCharcoal() {
        for base in [Theme.backdropEnds(.dark).top, Theme.backdropEnds(.dark).bottom] {
            let card = FeedStyle.warmCard(over: base, .dark)
            #expect(card.luminance > 0.01)
            #expect(card.red > card.blue)
        }
    }

    // MARK: Columns

    /// Today's room on a 13-inch iPad with the sidebar beside it, for any
    /// sidebar width the system picks: two cards in portrait, three in
    /// landscape. A phone gets one.
    @Test func eachDeviceGetsItsColumns() {
        func count(_ window: CGFloat) -> Int {
            FeedView.columnCount(for: FeedView.contentWidth(in: window, column: FeedStyle.wideFeedWidth),
                                 minimum: FeedStyle.cardMinimum, accessibilityText: false)
        }
        for sidebar in [320, 340, 375] as [CGFloat] {
            #expect(count(1024 - sidebar) == 2, "portrait beside a \(sidebar) pt sidebar")
            #expect(count(1366 - sidebar) == 3, "landscape beside a \(sidebar) pt sidebar")
        }
        for phone in [375, 390, 402, 430] as [CGFloat] {
            #expect(count(phone) == 1, "a \(phone) pt phone")
        }
    }

    /// At every width and text size the grid stays within one to three
    /// columns, one at accessibility sizes, and every card keeps at least
    /// its minimum width.
    @Test(arguments: [DynamicTypeSize.xSmall, .large, .xxxLarge, .accessibility1, .accessibility5])
    func wideColumnsStayComfortable(text: DynamicTypeSize) {
        for window in [320, 393, 678, 744, 1032, 1366, 1600, 2400] as [CGFloat] {
            let width = FeedView.contentWidth(in: window, column: FeedStyle.wideFeedWidth)
            let count = FeedView.columnCount(for: width, minimum: FeedStyle.cardMinimum,
                                             accessibilityText: text.isAccessibilitySize)
            #expect((1...FeedStyle.maxColumns).contains(count))
            if text.isAccessibilitySize { #expect(count == 1) }
            let card = (width - CGFloat(count - 1) * FeedView.cardSpacing) / CGFloat(count)
            if count > 1 { #expect(card >= FeedStyle.cardMinimum) }
        }
    }

    // MARK: Source chips

    @Test func aSourceChipShowsTheSiteWithoutWww() {
        #expect(SourceChip.host(URL(string: "https://www.riverside.example/pool")!) == "riverside.example")
        #expect(SourceChip.host(URL(string: "https://parks.riverside.example")!) == "parks.riverside.example")
    }
}
#endif
