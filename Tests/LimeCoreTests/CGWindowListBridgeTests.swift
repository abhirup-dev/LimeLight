import XCTest
import CoreGraphics
@testable import LimeCore

final class CGWindowListBridgeTests: XCTestCase {
    private func entry(
        wid: UInt32 = 1, pid: Int32 = 100, layer: Int = 0, alpha: Double = 1.0,
        bounds: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100),
        owner: String = "App", title: String? = nil
    ) -> [String: Any] {
        var dict: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: wid),
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowAlpha as String: NSNumber(value: alpha),
            kCGWindowOwnerName as String: owner,
            kCGWindowIsOnscreen as String: NSNumber(value: true),
        ]
        if let title { dict[kCGWindowName as String] = title }
        // Encode bounds as the {X,Y,Width,Height} dict CG returns.
        let cf = bounds.dictionaryRepresentation as NSDictionary
        dict[kCGWindowBounds as String] = cf as [NSObject: AnyObject]
        return dict
    }

    func testLayerZeroAccepted() {
        XCTAssertNotNil(CGWindowListBridge.parseEntry(entry(layer: 0)))
    }

    func testMenuBarLayerRejected() {
        // Menu bar items live above layer 20.
        XCTAssertNil(CGWindowListBridge.parseEntry(entry(layer: 25)))
    }

    func testStatusBarPlusOneRejected() {
        // Our own border overlays sit at NSWindow.Level.statusBar.rawValue + 1
        // (= 26 in the Cocoa→CG mapping). They MUST be filtered to prevent the
        // recursive-bordering feedback loop.
        XCTAssertNil(CGWindowListBridge.parseEntry(entry(layer: 26)))
    }

    func testFloatingPanelRejected() {
        // Floating panels (tooltips, popovers) sit at non-zero layers.
        XCTAssertNil(CGWindowListBridge.parseEntry(entry(layer: 3)))
    }

    func testZeroAlphaRejected() {
        XCTAssertNil(CGWindowListBridge.parseEntry(entry(alpha: 0)))
    }

    func testMissingWindowIDRejected() {
        var e = entry()
        e.removeValue(forKey: kCGWindowNumber as String)
        XCTAssertNil(CGWindowListBridge.parseEntry(e))
    }
}
