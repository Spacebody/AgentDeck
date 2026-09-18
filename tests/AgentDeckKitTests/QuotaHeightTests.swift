import AppKit
import SwiftUI
import XCTest
@testable import AgentDeckKit

final class QuotaHeightTests: XCTestCase {
    private func page(_ brand: Brand, count: Int) -> QuotaPage {
        let node = QuotaNode(ok: true, hidden: false, accountId: "test", account: nil,
                             isDefault: true, kind: nil,
                             windows: (0..<count).map {
            PreviewSamples.win("seven_day_\($0)", "Long quota window \($0)", 37, resetIn: 86400)
        }, error: nil, noQuota: nil, sampledAt: nil, stale: nil, credits: nil, raw: nil)
        return QuotaPage(id: "\(brand)-\(count)", agentID: "\(brand)", agentName: "Test",
                         brand: brand, account: node)
    }

    @MainActor private func render(_ pages: [QuotaPage], width: CGFloat) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: FlatQuotaCarousel(pages: pages, autoRotate: false)
            .frame(width: width))
        let image = try XCTUnwrap(renderer.nsImage)
        return try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
    }

    @MainActor func testMixedPagesKeepHeightAndFillBottomOfShortCard() throws {
        let previousGlass = GlassRender.useNativeEffect
        let previousLocale = I18N.locale
        GlassRender.useNativeEffect = false
        defer { GlassRender.useNativeEffect = previousGlass; I18N.locale = previousLocale }
        for locale in ["zh-CN", "en", "ja"] {
            I18N.locale = locale
            for width: CGFloat in [300, 420] {
                for count in [2, 3, 5] {
                    for brand: Brand in [.claude, .qoder, .qoderCn] {
                        let single = page(.codex, count: 1)
                        let multiple = page(brand, count: count)
                        let short = try render([single, multiple], width: width)
                        let tall = try render([multiple, single], width: width)
                        XCTAssertEqual(short.pixelsHigh, tall.pixelsHigh, "\(locale) \(width) \(count)")
                        // Above the controls, safely inside the bottom of the card.
                        let color = try XCTUnwrap(short.colorAt(x: short.pixelsWide / 2,
                                                               y: short.pixelsHigh - 40))
                        XCTAssertGreaterThan(color.alphaComponent, 0.1,
                                             "Short page must paint the full shared card height")
                    }
                }
            }
        }
    }

    @MainActor func testSinglePageRemainsCompact() throws {
        let single = page(.codex, count: 1)
        let compact = try render([single], width: 420)
        let mixed = try render([single, page(.qoder, count: 5)], width: 420)
        XCTAssertLessThan(compact.pixelsHigh, mixed.pixelsHigh - 60)
    }

    @MainActor func testUnavailablePageKeepsSharedHeight() throws {
        let node = try JSONDecoder().decode(QuotaNode.self, from: Data(
            #"{"ok":false,"error":"Temporarily unavailable","noQuota":true}"#.utf8))
        let unavailable = QuotaPage(id: "unavailable", agentID: "claude", agentName: "Claude",
                                    brand: .claude, account: node)
        let multiple = page(.qoder, count: 3)
        let first = try render([unavailable, multiple], width: 300)
        let second = try render([multiple, unavailable], width: 300)
        XCTAssertEqual(first.pixelsHigh, second.pixelsHigh)
    }
}
