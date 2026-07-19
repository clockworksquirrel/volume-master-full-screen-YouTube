import AppKit
import ApplicationServices
import BridgeCore
import Foundation
import Network
import OSLog

private let bridgePort: NWEndpoint.Port = 38_471
private let bridgeToken = "792c7cdbaa0561ce2e0f2534d75b7d5aa689a7648f41d3b6dde476ff23a6af5a"
private let axFullScreenAttribute = "AXFullScreen"
private let axIdentifierAttribute = "AXIdentifier"
private let axWebAreaRole = "AXWebArea"
private let maximumAccessibilityElements = 1_200
private let maximumAccessibilityDepth = 18
private let captureEvidenceStabilityNanoseconds: UInt64 = 250_000_000
private let logger = Logger(
    subsystem: "local.codex.youtube-real-fullscreen",
    category: "bridge"
)

private struct ActionResult {
    let status: Int
    let changed: Bool
    let message: String
}

private struct BrowserWindowSnapshot {
    var documentURL: String?
    var chromeElements: [BrowserChromeElement]
}

@MainActor
private final class FullscreenController {
    private var forcedWindow: AXUIElement?
    private var forcedPID: pid_t?
    private var forcedBrowserName: String?
    private var permissionPrompted = false

    func probe() -> [String: Any] {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return ["frontmost": NSNull(), "trusted": AXIsProcessTrusted()]
        }

        let engine = browserEngine(for: application)
        var result: [String: Any] = [
            "frontmost": application.bundleIdentifier ?? application.localizedName ?? "unknown",
            "engine": engine?.rawValue ?? NSNull(),
            "pid": application.processIdentifier,
            "trusted": AXIsProcessTrusted(),
        ]

        if AXIsProcessTrusted(),
           let engine,
           let window = focusedWindow(for: application.processIdentifier)
        {
            let snapshot = inspectBrowserWindow(window)
            let decision = evaluateBridgePolicy(
                engine: engine,
                documentURL: snapshot.documentURL,
                chromeElements: snapshot.chromeElements
            )
            let sharingCandidates = snapshot.chromeElements
                .filter(isBrowserChromeSharingIndicator)
                .map { element in
                    [
                        "role": element.role,
                        "identifier": element.identifier ?? "",
                        "text": element.text,
                        "selectedTab": element.isWithinSelectedTab,
                    ] as [String: Any]
                }
            let tabCandidates = snapshot.chromeElements
                .filter { $0.role == "AXTab" || $0.role == "AXRadioButton" }
                .map { element in
                    [
                        "role": element.role,
                        "identifier": element.identifier ?? "",
                        "text": element.text,
                        "selectedTab": element.isWithinSelectedTab,
                    ] as [String: Any]
                }
            result["documentURL"] = snapshot.documentURL ?? NSNull()
            result["sharingIndicator"] = decision.evidence != nil
            result["sharingCandidates"] = sharingCandidates
            result["tabCandidates"] = tabCandidates
            result["policyMessage"] = decision.message
            result["fullscreen"] = boolAttribute(axFullScreenAttribute, of: window) ?? NSNull()
        }

        return result
    }

    func enter(pageHost: String?) async -> ActionResult {
        guard isYouTubeHost(pageHost) else {
            return ActionResult(status: 403, changed: false, message: "The request did not come from a YouTube page.")
        }

        guard let application = NSWorkspace.shared.frontmostApplication,
              let engine = browserEngine(for: application)
        else {
            return ActionResult(
                status: 409,
                changed: false,
                message: "The frontmost application is not a supported Chromium- or Gecko-based browser."
            )
        }

        guard ensureAccessibilityPermission() else {
            return ActionResult(
                status: 503,
                changed: false,
                message: "Allow YouTube Real Fullscreen Bridge in System Settings > Privacy & Security > Accessibility."
            )
        }

        let pid = application.processIdentifier
        guard let window = focusedWindow(for: pid) else {
            return ActionResult(status: 409, changed: false, message: "No focused browser window was found.")
        }

        let snapshot = inspectBrowserWindow(window)
        let decision = evaluateBridgePolicy(
            engine: engine,
            documentURL: snapshot.documentURL,
            chromeElements: snapshot.chromeElements
        )
        guard decision.allowed else {
            return ActionResult(status: 200, changed: false, message: decision.message)
        }

        // A browser can remove its sharing badge shortly after capture stops.
        // Require the selected-tab evidence to survive a second observation so
        // a stale accessibility update cannot authorize fullscreen.
        try? await Task.sleep(nanoseconds: captureEvidenceStabilityNanoseconds)
        let stableSnapshot = inspectBrowserWindow(window)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              evaluateBridgePolicy(
                  engine: engine,
                  documentURL: stableSnapshot.documentURL,
                  chromeElements: stableSnapshot.chromeElements
              ).allowed
        else {
            return ActionResult(
                status: 200,
                changed: false,
                message: "The selected tab's sharing indicator did not remain active."
            )
        }

        if boolAttribute(axFullScreenAttribute, of: window) == true {
            return ActionResult(status: 200, changed: false, message: "The browser window is already fullscreen.")
        }

        guard setFullscreen(true, on: window) else {
            return ActionResult(status: 500, changed: false, message: "The browser rejected the native fullscreen request.")
        }

        forcedWindow = window
        forcedPID = pid
        forcedBrowserName = application.localizedName ?? application.bundleIdentifier
        logger.info(
            "Entered native fullscreen for a shared YouTube tab in \(self.forcedBrowserName ?? "browser", privacy: .public)"
        )
        return ActionResult(status: 200, changed: true, message: "Entered native fullscreen.")
    }

    func exit() -> ActionResult {
        guard let window = forcedWindow else {
            return ActionResult(status: 200, changed: false, message: "This bridge did not enter fullscreen.")
        }

        guard ensureAccessibilityPermission() else {
            return ActionResult(status: 503, changed: false, message: "Accessibility permission is unavailable.")
        }

        var currentPID: pid_t = 0
        guard AXUIElementGetPid(window, &currentPID) == .success,
              currentPID == forcedPID
        else {
            clearForcedWindow()
            return ActionResult(status: 200, changed: false, message: "The original browser window is no longer available.")
        }

        if boolAttribute(axFullScreenAttribute, of: window) != true {
            clearForcedWindow()
            return ActionResult(status: 200, changed: false, message: "The browser window already left fullscreen.")
        }

        guard setFullscreen(false, on: window) else {
            return ActionResult(status: 500, changed: false, message: "The browser rejected the fullscreen exit request.")
        }

        let browserName = forcedBrowserName ?? "browser"
        clearForcedWindow()
        logger.info("Restored the \(browserName, privacy: .public) window after page fullscreen ended")
        return ActionResult(status: 200, changed: true, message: "Exited native fullscreen.")
    }

    private func clearForcedWindow() {
        forcedWindow = nil
        forcedPID = nil
        forcedBrowserName = nil
    }

    private func ensureAccessibilityPermission() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }

        if !permissionPrompted {
            permissionPrompted = true
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
            ] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        return false
    }

    private func browserEngine(for application: NSRunningApplication) -> BrowserEngine? {
        var frameworkNames: [String] = []
        var hasXULRuntime = false

        if let bundleURL = application.bundleURL {
            let frameworksURL = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
            frameworkNames = (try? FileManager.default.contentsOfDirectory(
                at: frameworksURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).map(\.lastPathComponent)) ?? []

            hasXULRuntime = FileManager.default.fileExists(
                atPath: bundleURL.appendingPathComponent("Contents/MacOS/XUL").path
            )
        }

        return detectBrowserEngine(
            bundleIdentifier: application.bundleIdentifier,
            frameworkNames: frameworkNames,
            hasXULRuntime: hasXULRuntime
        )
    }

    private func focusedWindow(for pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &value
        ) == .success,
        let value
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func inspectBrowserWindow(_ window: AXUIElement) -> BrowserWindowSnapshot {
        var snapshot = BrowserWindowSnapshot(
            documentURL: stringAttribute(kAXDocumentAttribute, of: window),
            chromeElements: []
        )
        var visited = 0

        func visit(_ element: AXUIElement, depth: Int, withinSelectedTab: Bool) {
            guard depth <= maximumAccessibilityDepth,
                  visited < maximumAccessibilityElements
            else {
                return
            }
            visited += 1

            let role = stringAttribute(kAXRoleAttribute, of: element) ?? ""
            if role == axWebAreaRole {
                if snapshot.documentURL == nil {
                    snapshot.documentURL = stringAttribute(kAXURLAttribute, of: element)
                        ?? stringAttribute(kAXDocumentAttribute, of: element)
                }
                // Never inspect page-owned descendants. Sharing evidence must come
                // from trusted browser chrome, not text controlled by a website.
                return
            }

            let isTabElement = role == "AXTab" || role == "AXRadioButton"
            let isSelectedTab = boolAttribute(kAXSelectedAttribute, of: element) == true
                || boolAttribute(kAXValueAttribute, of: element) == true
            let selectedTabBranch = withinSelectedTab
                || (isTabElement && isSelectedTab)

            if depth > 0 {
                let text = [
                    stringAttribute(kAXTitleAttribute, of: element),
                    stringAttribute(kAXDescriptionAttribute, of: element),
                    stringAttribute(kAXHelpAttribute, of: element),
                    stringAttribute(kAXValueAttribute, of: element),
                ]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")

                snapshot.chromeElements.append(BrowserChromeElement(
                    role: role,
                    identifier: stringAttribute(axIdentifierAttribute, of: element),
                    text: text,
                    isWithinSelectedTab: selectedTabBranch
                ))
            }

            for child in children(of: element) {
                visit(child, depth: depth + 1, withinSelectedTab: selectedTabBranch)
                if visited >= maximumAccessibilityElements {
                    break
                }
            }
        }

        visit(window, depth: 0, withinSelectedTab: false)
        return snapshot
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success,
        let children = value as? [AXUIElement]
        else {
            return []
        }
        return children
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value
        else {
            return nil
        }

        if let string = value as? String {
            return string
        }
        if let url = value as? URL {
            return url.absoluteString
        }
        return nil
    }

    private func boolAttribute(_ attribute: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private func setFullscreen(_ value: Bool, on window: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            window,
            axFullScreenAttribute as CFString,
            &settable
        ) == .success,
        settable.boolValue
        else {
            return false
        }

        return AXUIElementSetAttributeValue(
            window,
            axFullScreenAttribute as CFString,
            value ? kCFBooleanTrue : kCFBooleanFalse
        ) == .success
    }
}

private final class BridgeServer {
    private let controller: FullscreenController
    private let queue = DispatchQueue(label: "local.codex.youtube-real-fullscreen.server")
    private let listener: NWListener

    @MainActor
    init(controller: FullscreenController) throws {
        self.controller = controller

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: bridgePort)
        listener = try NWListener(using: parameters)
    }

    func start() {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                logger.info("Bridge listening on 127.0.0.1:\(bridgePort.rawValue)")
            case .failed(let error):
                logger.error("Bridge listener failed: \(error.localizedDescription, privacy: .public)")
                NSApplication.shared.terminate(nil)
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, accumulated: Data())
    }

    private func receiveRequest(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            guard error == nil else {
                connection.cancel()
                return
            }

            var requestData = accumulated
            if let data {
                requestData.append(data)
            }

            guard requestData.count <= 8_192 else {
                self.respond(connection, status: 400, body: self.json(changed: false, message: "Malformed request."))
                return
            }

            guard requestData.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if isComplete {
                    self.respond(connection, status: 400, body: self.json(changed: false, message: "Malformed request."))
                    return
                }
                self.receiveRequest(connection, accumulated: requestData)
                return
            }

            guard let request = HTTPRequest.parse(requestData) else {
                self.respond(connection, status: 400, body: self.json(changed: false, message: "Malformed request."))
                return
            }

            guard let route = BridgeRoute.match(request) else {
                self.respond(connection, status: 404, body: self.json(changed: false, message: "Unknown route."))
                return
            }

            if route == .health {
                self.respond(connection, status: 200, body: self.json(changed: false, message: "ready"))
                return
            }

            guard request.header("x-yrf-token") == bridgeToken else {
                self.respond(connection, status: 403, body: self.json(changed: false, message: "Invalid bridge token."))
                return
            }

            Task { @MainActor in
                let result: ActionResult
                switch route {
                case .enter:
                    result = await self.controller.enter(pageHost: request.header("x-yrf-page-host"))
                case .exit:
                    result = self.controller.exit()
                case .health:
                    return
                }
                self.respond(
                    connection,
                    status: result.status,
                    body: self.json(changed: result.changed, message: result.message)
                )
            }
        }
    }

    private func json(changed: Bool, message: String) -> String {
        let object: [String: Any] = ["changed": changed, "message": message]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let output = String(data: data, encoding: .utf8)
        else {
            return #"{"changed":false,"message":"Serialization error."}"#
        }
        return output
    }

    private func respond(_ connection: NWConnection, status: Int, body: String) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 409: reason = "Conflict"
        case 500: reason = "Internal Server Error"
        case 503: reason = "Service Unavailable"
        default: reason = "Error"
        }

        let response = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: application/json; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r
        \(body)
        """

        connection.send(
            content: response.data(using: .utf8),
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }
}

@main
private struct YouTubeRealFullscreenBridgeApp {
    @MainActor
    static func main() {
        let controller = FullscreenController()

        if CommandLine.arguments.contains("--probe") {
            let result = controller.probe()
            let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8)!)
            return
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        do {
            let server = try BridgeServer(controller: controller)
            server.start()
            withExtendedLifetime(server) {
                application.run()
            }
        } catch {
            logger.error("Unable to start bridge: \(error.localizedDescription, privacy: .public)")
            exit(1)
        }
    }
}
