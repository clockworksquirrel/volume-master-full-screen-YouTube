import BridgeCore
import Foundation
import XCTest

final class HTTPRequestTests: XCTestCase {
    func testParsesCaseInsensitiveTokenHeader() {
        let data = Data("POST /enter HTTP/1.1\r\nHost: 127.0.0.1\r\nX-YRF-Token: secret\r\n\r\n".utf8)
        let request = HTTPRequest.parse(data)

        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.path, "/enter")
        XCTAssertEqual(request?.header("x-yrf-token"), "secret")
        XCTAssertEqual(BridgeRoute.match(request!), .enter)
    }

    func testRejectsIncompleteAndOversizedRequests() {
        XCTAssertNil(HTTPRequest.parse(Data("POST /enter HTTP/1.1\r\n".utf8)))
        XCTAssertNil(HTTPRequest.parse(Data(repeating: 65, count: 8_193)))
    }

    func testRoutesRequireExpectedMethod() {
        let request = HTTPRequest(method: "GET", path: "/enter", headers: [:])
        XCTAssertNil(BridgeRoute.match(request))
    }

    func testSharedTabTitleDetection() {
        XCTAssertTrue(isSharedTabWindowTitle("Video - Tab content shared - Helium"))
        XCTAssertFalse(isSharedTabWindowTitle("Video - YouTube - Helium"))
        XCTAssertFalse(isSharedTabWindowTitle("Tab content shared is a Chromium feature - YouTube - Helium"))
        XCTAssertFalse(isSharedTabWindowTitle(nil))
    }

    func testFullscreenBridgeRequiresSharedHeliumWindow() {
        let sharedTitle = "Video - Tab content shared - Helium"

        XCTAssertTrue(shouldApplyFullscreenBridge(
            bundleIdentifier: "net.imput.helium",
            windowTitle: sharedTitle
        ))
        XCTAssertFalse(shouldApplyFullscreenBridge(
            bundleIdentifier: "com.google.Chrome",
            windowTitle: sharedTitle
        ))
        XCTAssertFalse(shouldApplyFullscreenBridge(
            bundleIdentifier: "net.imput.helium",
            windowTitle: "Video - YouTube - Helium"
        ))
        XCTAssertFalse(shouldApplyFullscreenBridge(
            bundleIdentifier: nil,
            windowTitle: nil
        ))
    }
}
