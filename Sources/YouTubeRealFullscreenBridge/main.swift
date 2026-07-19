import AppKit
import ApplicationServices
import BridgeCore
import Foundation
import Network
import OSLog

private let bridgePort: NWEndpoint.Port = 38_471
private let bridgeToken = "792c7cdbaa0561ce2e0f2534d75b7d5aa689a7648f41d3b6dde476ff23a6af5a"
private let heliumBundleIdentifier = "net.imput.helium"
private let axFullScreenAttribute = "AXFullScreen"
private let logger = Logger(
    subsystem: "local.codex.youtube-real-fullscreen",
    category: "bridge"
)

private struct ActionResult {
    let status: Int
    let changed: Bool
    let message: String
}

@MainActor
private final class FullscreenController {
    private var forcedPID: pid_t?
    private var permissionPrompted = false

    func probe() -> [String: Any] {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return ["frontmost": NSNull(), "trusted": AXIsProcessTrusted()]
        }

        var result: [String: Any] = [
            "frontmost": application.bundleIdentifier ?? application.localizedName ?? "unknown",
            "pid": application.processIdentifier,
            "trusted": AXIsProcessTrusted(),
        ]

        if let window = focusedWindow(for: application.processIdentifier) {
            let title = stringAttribute(kAXTitleAttribute, of: window)
            result["windowTitle"] = title ?? NSNull()
            result["shared"] = isSharedTabWindowTitle(title)
            result["fullscreen"] = boolAttribute(axFullScreenAttribute, of: window) ?? NSNull()
        }

        return result
    }

    func enter() -> ActionResult {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier == heliumBundleIdentifier else {
            return ActionResult(
                status: 409,
                changed: false,
                message: "Helium is not the frontmost application."
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
            return ActionResult(status: 409, changed: false, message: "No focused Helium window was found.")
        }

        let title = stringAttribute(kAXTitleAttribute, of: window)
        guard shouldApplyFullscreenBridge(
            bundleIdentifier: application.bundleIdentifier,
            windowTitle: title
        ) else {
            return ActionResult(status: 200, changed: false, message: "The active tab is not being shared.")
        }

        if boolAttribute(axFullScreenAttribute, of: window) == true {
            return ActionResult(status: 200, changed: false, message: "The Helium window is already fullscreen.")
        }

        guard setFullscreen(true, on: window) else {
            return ActionResult(status: 500, changed: false, message: "Helium rejected the native fullscreen request.")
        }

        forcedPID = pid
        logger.info("Entered native fullscreen for a shared Helium tab")
        return ActionResult(status: 200, changed: true, message: "Entered native fullscreen.")
    }

    func exit() -> ActionResult {
        guard let pid = forcedPID else {
            return ActionResult(status: 200, changed: false, message: "This bridge did not enter fullscreen.")
        }

        guard ensureAccessibilityPermission(),
              let window = focusedWindow(for: pid)
        else {
            forcedPID = nil
            return ActionResult(status: 200, changed: false, message: "The original Helium window is no longer available.")
        }

        if boolAttribute(axFullScreenAttribute, of: window) != true {
            forcedPID = nil
            return ActionResult(status: 200, changed: false, message: "The Helium window already left fullscreen.")
        }

        guard setFullscreen(false, on: window) else {
            return ActionResult(status: 500, changed: false, message: "Helium rejected the fullscreen exit request.")
        }

        forcedPID = nil
        logger.info("Restored the Helium window after page fullscreen ended")
        return ActionResult(status: 200, changed: true, message: "Exited native fullscreen.")
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

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
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
                    result = self.controller.enter()
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
