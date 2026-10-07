import XCTest
import CoreGraphics
@testable import refik

final class DisplayPlacementTests: XCTestCase {
    private func screen(_ id: String, _ rect: CGRect, scale: CGFloat = 1, main: Bool = false) -> DisplayDescriptor {
        DisplayDescriptor(id: id, legacyID: id == "main" ? 1 : 2, name: id, frame: rect,
                          visibleFrame: rect, scale: scale, isMain: main)
    }
    func testPreferredDisplayReturnsAfterRemovalWithoutLosingItsPosition() {
        let main = screen("main", CGRect(x: 0, y: 0, width: 1440, height: 875), scale: 2, main: true)
        let external = screen("external", CGRect(x: -1920, y: 220, width: 1920, height: 1080))
        let saved = ["external": DisplayPosition(edge: "left", vertical: 0.8),
                     "main": DisplayPosition(edge: "right", vertical: 0.2)]
        let original = DisplayPlacementPolicy.mascot(in: external.visibleFrame, position: saved["external"]!)
        let fallback = DisplayPlacementPolicy.select(displays: [main], preferredID: "external", legacyID: 2, currentFrame: original)!
        XCTAssertEqual(fallback.id, "main")
        let fallbackFrame = DisplayPlacementPolicy.mascot(in: fallback.visibleFrame,
            position: DisplayPlacementPolicy.position(for: fallback, saved: saved, defaultPosition: saved["external"]!))
        XCTAssertTrue(main.visibleFrame.contains(fallbackFrame))
        let restored = DisplayPlacementPolicy.select(displays: [main, external], preferredID: "external", legacyID: 2, currentFrame: fallbackFrame)!
        XCTAssertEqual(restored.id, "external")
        XCTAssertEqual(DisplayPlacementPolicy.mascot(in: restored.visibleFrame, position: saved[restored.id]!), original)
    }
    func testClosestUsesRectangleDistanceAndAutomaticStartsOnMain() {
        let main = screen("main", CGRect(x: 0, y: 0, width: 1000, height: 800), main: true)
        let tall = screen("tall", CGRect(x: -600, y: -700, width: 600, height: 2200), scale: 2)
        XCTAssertEqual(DisplayPlacementPolicy.select(displays: [tall, main], preferredID: nil, legacyID: 0, currentFrame: nil)?.id, "main")
        XCTAssertEqual(DisplayPlacementPolicy.select(displays: [main, tall], preferredID: "missing", legacyID: 1,
            currentFrame: CGRect(x: -30, y: 1200, width: 10, height: 10))?.id, "tall")
        XCTAssertNil(DisplayPlacementPolicy.select(displays: [], preferredID: nil, legacyID: 0, currentFrame: nil))
    }
    func testPanelAndMascotStayWithinNegativeStaggeredFramesAtDifferentScales() {
        for scale: CGFloat in [1, 1.5, 2] {
            let display = screen("external", CGRect(x: -1400, y: -650, width: 1200, height: 740), scale: scale)
            for edge in ["left", "right"] {
                for vertical in [-1.0, 0.0, 0.5, 1.0, 2.0, Double.nan] {
                    let mascot = DisplayPlacementPolicy.mascot(in: display.visibleFrame, position: DisplayPosition(edge: edge, vertical: vertical))
                    XCTAssertTrue(display.visibleFrame.contains(mascot))
                    for size in [CGSize(width: 324, height: 475), CGSize(width: 1600, height: 2000)] {
                        let panel = DisplayPlacementPolicy.panel(in: display.visibleFrame, mascot: mascot, requestedSize: size, edge: edge)
                        XCTAssertTrue(display.visibleFrame.contains(panel))
                    }
                }
            }
        }
    }
    func testTinyVisibleAreaFitsOversizedWindowsAndVerticalDragClamps() {
        let area = CGRect(x: -10, y: 20, width: 40, height: 30)
        let mascot = DisplayPlacementPolicy.mascot(in: area, position: DisplayPosition(edge: "right", vertical: 1))
        XCTAssertTrue(area.contains(mascot))
        XCTAssertTrue(area.contains(DisplayPlacementPolicy.panel(in: area, mascot: mascot, requestedSize: CGSize(width: 324, height: 475), edge: "right")))
        XCTAssertEqual(DisplayPlacementPolicy.vertical(for: -100, in: area), 0)
        XCTAssertEqual(DisplayPlacementPolicy.vertical(for: 1000, in: area), 1)
    }
    func testLegacyIdentityIsUsedOnlyBeforeStableIdentityExists() {
        let main = screen("main", CGRect(x: 0, y: 0, width: 1000, height: 800), main: true)
        let other = screen("other", CGRect(x: 1000, y: 0, width: 1000, height: 800))
        XCTAssertEqual(DisplayPlacementPolicy.select(displays: [main, other], preferredID: nil, legacyID: 2, currentFrame: nil)?.id, "other")
        XCTAssertEqual(DisplayPlacementPolicy.select(displays: [main, other], preferredID: "missing", legacyID: 2, currentFrame: nil)?.id, "main")
    }
}
