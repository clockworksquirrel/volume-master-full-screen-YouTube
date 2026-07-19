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
            guard !name.isEmpty, headers[name] == nil else {
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

public enum BrowserEngine: String, Equatable {
    case chromium
    case gecko
}

public struct BrowserChromeElement: Equatable {
    public let role: String
    public let identifier: String?
    public let text: String
    public let isWithinSelectedTab: Bool

    public init(
        role: String,
        identifier: String?,
        text: String,
        isWithinSelectedTab: Bool = false
    ) {
        self.role = role
        self.identifier = identifier
        self.text = text
        self.isWithinSelectedTab = isWithinSelectedTab
    }
}

public enum SharingEvidence: String, Equatable {
    case browserChromeIndicator
}

public struct BridgePolicyDecision: Equatable {
    public let allowed: Bool
    public let message: String
    public let evidence: SharingEvidence?

    public init(allowed: Bool, message: String, evidence: SharingEvidence?) {
        self.allowed = allowed
        self.message = message
        self.evidence = evidence
    }
}

private let chromiumBundleIdentifiers: Set<String> = [
    "com.brave.browser",
    "com.brave.browser.beta",
    "com.brave.browser.dev",
    "com.brave.browser.nightly",
    "com.google.chrome",
    "com.google.chrome.beta",
    "com.google.chrome.canary",
    "com.google.chrome.dev",
    "com.microsoft.edgemac",
    "com.microsoft.edgemac.beta",
    "com.microsoft.edgemac.canary",
    "com.microsoft.edgemac.dev",
    "com.operasoftware.opera",
    "com.operasoftware.operadeveloper",
    "com.vivaldi.vivaldi",
    "com.vivaldi.vivaldi.snapshot",
    "company.thebrowser.browser",
    "company.thebrowser.browser.beta",
    "io.github.ungoogled_software.ungoogled_chromium",
    "net.imput.helium",
    "org.chromium.chromium",
]

private let geckoBundleIdentifiers: Set<String> = [
    "app.zen-browser.zen",
    "io.gitlab.librewolf-community",
    "net.mullvad.mullvadbrowser",
    "net.waterfox.waterfox",
    "one.ablaze.floorp",
    "org.mozilla.firefox",
    "org.mozilla.firefoxdeveloperedition",
    "org.mozilla.firefox-esr",
    "org.mozilla.librewolf",
    "org.mozilla.nightly",
    "org.torproject.torbrowser",
]

public func detectBrowserEngine(
    bundleIdentifier: String?,
    frameworkNames: [String] = [],
    hasXULRuntime: Bool = false
) -> BrowserEngine? {
    let identifier = bundleIdentifier?.lowercased()

    if let identifier, chromiumBundleIdentifiers.contains(identifier) {
        return .chromium
    }
    if let identifier, geckoBundleIdentifiers.contains(identifier) {
        return .gecko
    }
    if hasXULRuntime {
        return .gecko
    }

    let normalizedFrameworks = frameworkNames.map { $0.lowercased() }
    if normalizedFrameworks.contains(where: {
        $0.hasSuffix(" framework.framework") && $0 != "electron framework.framework"
    }) {
        return .chromium
    }

    return nil
}

public func isYouTubeHost(_ value: String?) -> Bool {
    guard let host = value?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased(),
        !host.isEmpty
    else {
        return false
    }

    return host == "youtube.com" || host.hasSuffix(".youtube.com")
}

public func isYouTubeURL(_ value: String?) -> Bool {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty
    else {
        return false
    }

    let candidate = value.contains("://") ? value : "https://\(value)"
    return isYouTubeHost(URL(string: candidate)?.host)
}

public func isChromiumSharedWindowTitle(
    _ title: String?,
    applicationName: String?
) -> Bool {
    guard let title,
          let applicationName = applicationName?.trimmingCharacters(in: .whitespacesAndNewlines),
          !applicationName.isEmpty
    else {
        return false
    }

    return title.range(
        of: " - Tab content shared - \(applicationName)",
        options: [.anchored, .backwards, .caseInsensitive]
    ) != nil
}

public func isBrowserChromeSharingIndicator(_ element: BrowserChromeElement) -> Bool {
    let role = element.role.lowercased()
    let interactiveRoles = [
        "axbutton",
        "axcheckbox",
        "axgroup",
        "aximage",
        "axradiobutton",
        "axstatictext",
        "axtab",
    ]
    guard interactiveRoles.contains(role) else {
        return false
    }

    let identifier = normalizedWords(element.identifier ?? "")
    if identifier.contains("webrtc sharing")
        || identifier.contains("sharing icon")
        || identifier.contains("tab sharing")
        || identifier.contains("screen sharing")
    {
        return true
    }

    let text = normalizedWords(element.text)
    let phrases = [
        "tab content shared",
        "tab content is being shared",
        "this tab is being shared",
        "this tab s content is being shared",
        "sharing this tab",
        "you are sharing your screen",
        "you are sharing your window",
        "you are sharing a tab",
        "screen is being shared",
        "stop sharing",
    ]
    return phrases.contains(where: text.contains)
}

public func isSelectedTabSharingIndicator(_ element: BrowserChromeElement) -> Bool {
    element.isWithinSelectedTab && isBrowserChromeSharingIndicator(element)
}

public func evaluateBridgePolicy(
    engine: BrowserEngine,
    documentURL: String?,
    chromeElements: [BrowserChromeElement]
) -> BridgePolicyDecision {
    guard isYouTubeURL(documentURL) else {
        return BridgePolicyDecision(
            allowed: false,
            message: "The active browser tab is not YouTube.",
            evidence: nil
        )
    }

    guard chromeElements.contains(where: isSelectedTabSharingIndicator) else {
        let engineName = engine == .chromium ? "Chromium" : "Gecko"
        return BridgePolicyDecision(
            allowed: false,
            message: "\(engineName) does not expose a sharing indicator on the selected tab.",
            evidence: nil
        )
    }

    return BridgePolicyDecision(
        allowed: true,
        message: "The active YouTube tab is shared.",
        evidence: .browserChromeIndicator
    )
}

private func normalizedWords(_ value: String) -> String {
    let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
        CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
    }
    return String(scalars)
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
}
