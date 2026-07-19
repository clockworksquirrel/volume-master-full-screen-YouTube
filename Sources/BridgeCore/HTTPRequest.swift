import Foundation

public struct HTTPRequest: Equatable {
    public let method: String
    public let path: String
    public let headers: [String: String]

    public init(method: String, path: String, headers: [String: String]) {
        self.method = method
        self.path = path
        self.headers = headers
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    public static func parse(_ data: Data) -> HTTPRequest? {
        guard data.count <= 8_192,
              let raw = String(data: data, encoding: .utf8),
              let headerEnd = raw.range(of: "\r\n\r\n")
        else {
            return nil
        }

        let lines = raw[..<headerEnd.lowerBound].components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3,
              parts[2].hasPrefix("HTTP/1.")
        else {
            return nil
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                return nil
            }

            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                return nil
            }
            headers[name] = value
        }

        return HTTPRequest(
            method: String(parts[0]).uppercased(),
            path: String(parts[1]),
            headers: headers
        )
    }
}

public enum BridgeRoute: Equatable {
    case health
    case enter
    case exit

    public static func match(_ request: HTTPRequest) -> BridgeRoute? {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return .health
        case ("POST", "/enter"):
            return .enter
        case ("POST", "/exit"):
            return .exit
        default:
            return nil
        }
    }
}

public func isSharedTabWindowTitle(_ title: String?) -> Bool {
    guard let title else {
        return false
    }

    return title.range(
        of: " - Tab content shared - Helium",
        options: [.anchored, .backwards, .caseInsensitive]
    ) != nil
}

public func shouldApplyFullscreenBridge(
    bundleIdentifier: String?,
    windowTitle: String?
) -> Bool {
    bundleIdentifier == "net.imput.helium" && isSharedTabWindowTitle(windowTitle)
}
