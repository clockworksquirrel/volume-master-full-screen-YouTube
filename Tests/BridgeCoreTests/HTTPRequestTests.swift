import BridgeCore
import Foundation
import XCTest

final class HTTPRequestTests: XCTestCase {
    func testParsesCaseInsensitiveHeaders() {
        let data = Data(
            "POST /enter HTTP/1.1\r\nHost: 127.0.0.1\r\nX-YRF-Token: secret\r\nX-YRF-Page-Host: www.youtube.com\r\n\r\n".utf8
        )
        let request = HTTPRequest.parse(data)

        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.path, "/enter")
        XCTAssertEqual(request?.header("x-yrf-token"), "secret")
        XCTAssertEqual(request?.header("X-YRF-PAGE-HOST"), "www.youtube.com")
        XCTAssertEqual(BridgeRoute.match(request!), .enter)
    }

    func testRejectsIncompleteOversizedAndDuplicateHeaderRequests() {
        XCTAssertNil(HTTPRequest.parse(Data("POST /enter HTTP/1.1\r\n".utf8)))
        XCTAssertNil(HTTPRequest.parse(Data(repeating: 65, count: 8_193)))
        XCTAssertNil(HTTPRequest.parse(Data(
            "POST /enter HTTP/1.1\r\nX-YRF-Token: first\r\nx-yrf-token: second\r\n\r\n".utf8
        )))
    }

    func testRoutesRequireExpectedMethod() {
        XCTAssertNil(BridgeRoute.match(HTTPRequest(method: "GET", path: "/enter", headers: [:])))
        XCTAssertEqual(
            BridgeRoute.match(HTTPRequest(method: "GET", path: "/health", headers: [:])),
            .health
        )
        XCTAssertEqual(
            BridgeRoute.match(HTTPRequest(method: "POST", path: "/exit", headers: [:])),
            .exit
        )
    }

    func testDetectsKnownAndRuntimeDiscoveredBrowserEngines() {
        XCTAssertEqual(detectBrowserEngine(bundleIdentifier: "com.google.Chrome"), .chromium)
        XCTAssertEqual(detectBrowserEngine(bundleIdentifier: "org.mozilla.firefox"), .gecko)
        XCTAssertEqual(detectBrowserEngine(bundleIdentifier: "app.zen-browser.zen"), .gecko)

        XCTAssertEqual(
            detectBrowserEngine(
                bundleIdentifier: "com.example.new-browser",
                frameworkNames: ["Future Browser Framework.framework"]
            ),
            .chromium
        )
        XCTAssertEqual(
            detectBrowserEngine(bundleIdentifier: "com.example.gecko-browser", hasXULRuntime: true),
            .gecko
        )
        XCTAssertNil(detectBrowserEngine(
            bundleIdentifier: "com.example.desktop-app",
            frameworkNames: ["Electron Framework.framework"]
        ))
    }

    func testRecognizesOnlyYouTubeHostsAndURLs() {
        XCTAssertTrue(isYouTubeHost("youtube.com"))
        XCTAssertTrue(isYouTubeHost("WWW.YouTube.com"))
        XCTAssertTrue(isYouTubeURL("https://music.youtube.com/watch?v=abc"))
        XCTAssertFalse(isYouTubeHost("youtube.com.example.test"))
        XCTAssertFalse(isYouTubeURL("https://example.test/?next=youtube.com"))
        XCTAssertFalse(isYouTubeURL(nil))
    }

    func testRecognizesChromiumAndGeckoBrowserChromeSharingIndicators() {
        XCTAssertTrue(isBrowserChromeSharingIndicator(BrowserChromeElement(
            role: "AXRadioButton",
            identifier: nil,
            text: "Video - Tab content shared - Browser"
        )))
        XCTAssertTrue(isBrowserChromeSharingIndicator(BrowserChromeElement(
            role: "AXButton",
            identifier: "webrtc-sharing-icon",
            text: ""
        )))
        XCTAssertTrue(isBrowserChromeSharingIndicator(BrowserChromeElement(
            role: "AXButton",
            identifier: nil,
            text: "You are sharing your screen. Stop sharing"
        )))
        XCTAssertTrue(isBrowserChromeSharingIndicator(BrowserChromeElement(
            role: "AXStaticText",
            identifier: nil,
            text: "This tab's content is being shared"
        )))
    }

    func testRejectsPageControlledTextAndUnrelatedChromeText() {
        XCTAssertFalse(isBrowserChromeSharingIndicator(BrowserChromeElement(
            role: "AXWebArea",
            identifier: "webrtc-sharing-icon",
            text: "This tab is being shared"
        )))
        XCTAssertFalse(isBrowserChromeSharingIndicator(BrowserChromeElement(
            role: "AXStaticText",
            identifier: nil,
            text: "A page about how tab content sharing works"
        )))
        XCTAssertFalse(isBrowserChromeSharingIndicator(BrowserChromeElement(
            role: "AXWindow",
            identifier: nil,
            text: "Video - Tab content shared - Helium"
        )))
    }

    func testPolicyRequiresBothYouTubeAndBrowserChromeSharingEvidence() {
        let chromiumIndicator = BrowserChromeElement(
            role: "AXRadioButton",
            identifier: nil,
            text: "Video - Tab content shared - Helium",
            isWithinSelectedTab: true
        )
        let geckoIndicator = BrowserChromeElement(
            role: "AXButton",
            identifier: "webrtc-sharing-icon",
            text: "Sharing this tab",
            isWithinSelectedTab: true
        )

        XCTAssertEqual(
            evaluateBridgePolicy(
                engine: .chromium,
                documentURL: "https://www.youtube.com/watch?v=abc",
                chromeElements: [chromiumIndicator]
            ),
            BridgePolicyDecision(
                allowed: true,
                message: "The active YouTube tab is shared.",
                evidence: .browserChromeIndicator
            )
        )
        XCTAssertTrue(evaluateBridgePolicy(
            engine: .gecko,
            documentURL: "https://youtube.com/watch?v=abc",
            chromeElements: [geckoIndicator]
        ).allowed)
        XCTAssertFalse(evaluateBridgePolicy(
            engine: .chromium,
            documentURL: "https://example.test/watch?v=abc",
            chromeElements: [chromiumIndicator]
        ).allowed)
        XCTAssertFalse(evaluateBridgePolicy(
            engine: .gecko,
            documentURL: "https://youtube.com/watch?v=abc",
            chromeElements: []
        ).allowed)

        let backgroundTabIndicator = BrowserChromeElement(
            role: "AXRadioButton",
            identifier: nil,
            text: "Background tab - Tab content shared - Browser",
            isWithinSelectedTab: false
        )
        XCTAssertFalse(evaluateBridgePolicy(
            engine: .chromium,
            documentURL: "https://youtube.com/watch?v=abc",
            chromeElements: [backgroundTabIndicator]
        ).allowed)
    }

    func testWindowTitleMarkerIsDiagnosticOnlyAndRequiresExactSuffix() {
        XCTAssertTrue(isChromiumSharedWindowTitle(
            "Video - Tab content shared - Helium",
            applicationName: "Helium"
        ))
        XCTAssertFalse(isChromiumSharedWindowTitle(
            "Tab content shared is a Chromium feature - YouTube - Helium",
            applicationName: "Helium"
        ))
        XCTAssertFalse(isChromiumSharedWindowTitle(
            "Video - Tab content shared - Helium",
            applicationName: "Chrome"
        ))
    }
}
