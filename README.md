# volume-master-full-screen-YouTube

Restore true macOS fullscreen for YouTube while a Chromium- or Gecko-family browser is actively sharing the selected tab.

The project keeps YouTube's existing fullscreen button and `f` shortcut. It does not add a replacement player control and it does not install another browser extension. It combines:

1. a portable userscript that observes YouTube's real fullscreen lifecycle; and
2. a native macOS helper that verifies browser-owned sharing evidence and controls the browser window.

Both components are necessary. The userscript can see what YouTube is doing inside the webpage but cannot move a browser window into a macOS fullscreen Space. The helper can perform that native window action after the user grants Accessibility permission, but it cannot see YouTube's DOM fullscreen intent. Together they bridge that security boundary without replacing the player or adding a second capture extension.

## What problem this solves

An extension such as Volume Master can capture and re-route a Chromium tab's audio. Chromium marks that tab as shared. While capture is active, YouTube may enter DOM/player fullscreen without moving the browser window into native macOS fullscreen. The video grows, but the tab strip or browser chrome can remain visible. It feels like a large theater mode rather than a fullscreen Space.

Two separate transitions are involved:

- **DOM fullscreen:** YouTube asks the browser to display its player element fullscreen through the web Fullscreen API.
- **Native window fullscreen:** the browser asks macOS to move its window into a fullscreen Space and hide normal window chrome.

A userscript can observe the first transition. It cannot force the second. The helper supplies only that missing native transition, and only after independently proving that the selected YouTube tab has a browser-owned sharing indicator.

## Browser and userscript-manager compatibility

The userscript uses standards-based fullscreen events and supports both current and legacy userscript request APIs:

| Browser engine | Example browsers | Detection path |
| --- | --- | --- |
| Chromium | Helium, Chrome, Chromium, Brave, Edge, Arc, Opera, Vivaldi, ungoogled-chromium and compatible forks | Selected tab's browser-owned `Tab content shared` accessibility state |
| Gecko | Firefox, Firefox Developer Edition, Firefox ESR, Nightly, Zen, LibreWolf, Waterfox, Floorp, Mullvad Browser, Tor Browser and compatible forks | Selected tab's browser-owned WebRTC/tab-sharing accessibility state |

Known bundle identifiers are recognized directly. Unlisted forks can also be recognized by their Chromium browser framework or Gecko XUL runtime. Electron desktop apps are not accepted by the generic Chromium framework fallback.

Supported userscript APIs:

- `GM.xmlHttpRequest`, used by modern Greasemonkey-compatible managers;
- `GM_xmlhttpRequest`, used by Violentmonkey, Tampermonkey and legacy-compatible managers.

The metadata covers `youtube.com` and every HTTPS YouTube subdomain, prevents iframe injection with `@noframes`, and permits loopback requests only to `127.0.0.1`.

Compatibility is deliberately fail-closed. A Chromium or Gecko fork must expose its active document URL, selected tab, and sharing state through macOS Accessibility. If it hides or substantially restructures those values, the helper returns `changed: false` and leaves the window alone.

### An important Firefox and Gecko distinction

Chromium documents the extension-only streaming [`chrome.tabCapture`](https://developer.chrome.com/docs/extensions/reference/api/tabCapture) API used by tools such as Volume Master. Mozilla's documented [`tabs.captureTab()`](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/tabs/captureTab) API captures a still image; it is not a streaming status API equivalent to Chromium's `tabCapture`.

Some Gecko forks can nevertheless accept extensions that request a Chromium-compatible `tabCapture` name, implement their own compatibility behavior, or let an add-on use another audio path. The manifest alone therefore does not prove that the selected tab is being streamed, and a page-injected volume badge is not trusted evidence.

The Gecko bridge path applies only when Firefox or a Gecko-derived browser exposes a browser-owned sharing marker on the selected tab. If the browser permits native DOM fullscreen while boosted audio is active, the helper should perform a no-op and let the browser's normal fullscreen path continue. A volume booster that only inserts a Web Audio gain node, or a fork that does not expose sharing state through Accessibility, also produces a deliberate no-op.

### Verified Twilight behavior

The following was tested manually on macOS on 2026-07-19:

| Component | Tested value |
| --- | --- |
| Browser | Twilight 1.22t (`app.zen-browser.zen`, Gecko/XUL) |
| Userscript manager | Violentmonkey 2.41.0 |
| Userscript | YouTube Real Fullscreen for Shared Tabs 1.1.0, enabled and injected after a YouTube reload |
| Volume add-on | Volume Master — Increase Volume 1.0.1 from Mozilla Add-ons |
| Amplification | 200% |

With amplification at 200%, YouTube entered genuine browser fullscreen: Twilight removed its normal window/sidebar controls, exposed `YouTube Video Player in Fullscreen`, and restored the prior window after `f` was pressed again. Twilight did not expose a browser-owned selected-tab sharing marker in macOS Accessibility. The helper therefore stayed fail-closed while Twilight's native fullscreen implementation succeeded normally. This is a passing result, not an error: the bridge is only needed in browsers where active sharing blocks the native transition.

## Why the userscript is required

The userscript runs at `document-start` on YouTube. It listens to the browser's standard `fullscreenchange` lifecycle, with legacy WebKit/Gecko event names retained as compatibility fallbacks.

When YouTube enters player fullscreen, the script:

1. waits 350 ms for the browser's fullscreen state to settle;
2. sends `POST /enter` to the local helper;
3. records ownership only when the helper reports that it changed the native window; and
4. displays a short in-player diagnostic if the helper is unavailable or rejects the request.

When YouTube exits player fullscreen, the script:

1. waits 1.8 seconds because moving into a macOS fullscreen Space can briefly emit a DOM fullscreen exit event;
2. confirms that the player is still out of fullscreen; and
3. sends `POST /exit` only when this operation previously changed the native window.

It also handles:

- YouTube's single-page `yt-navigate-finish` navigation;
- `fullscreenerror`;
- hidden or discarded pages;
- the browser back-forward cache;
- page teardown; and
- slow loopback responses.

Every fullscreen operation has a generation number. If an old `/enter` response arrives after the player has already exited fullscreen, the script immediately sends a compensating `/exit`. This prevents a stale response from leaving the native window stuck in fullscreen.

### Why ordinary `fetch()` is not used

The helper is an HTTP service on loopback while YouTube is HTTPS. Ordinary page `fetch()` is constrained by mixed-content rules, CORS, Private Network Access, and the page's own origin. The manager-provided request API is designed for a userscript's explicitly granted cross-origin requests and is restricted by metadata to `127.0.0.1`.

### Why the userscript cannot solve fullscreen alone

A userscript is still browser JavaScript. It can:

- observe YouTube's DOM and fullscreen events;
- use the web Fullscreen API within browser policy; and
- call an explicitly permitted loopback endpoint.

It cannot:

- call AppKit or macOS Accessibility APIs;
- set the native `AXFullScreen` window attribute;
- move a window into a macOS fullscreen Space;
- override a browser's capture-time fullscreen policy; or
- grant itself Accessibility permission.

Monkey-patching `requestFullscreen()`, resizing the video element, or hiding page elements changes only the content inside the tab. None of those actions creates native macOS fullscreen.

## Why the native helper is required

`YouTube Real Fullscreen Bridge.app` is a small Swift/AppKit accessory application. It has no Dock icon or normal window. It listens only on:

```text
127.0.0.1:38471
```

Its API is intentionally small:

| Request | Purpose |
| --- | --- |
| `GET /health` | Report whether the local bridge is running. |
| `POST /enter` | Enter native fullscreen only when every safety check passes. |
| `POST /exit` | Restore only the exact window this helper previously changed. |

macOS protects window automation behind Accessibility permission. The helper needs that permission to inspect the focused browser window and set its native `AXFullScreen` attribute.

### Why the helper cannot solve the problem alone

The helper does not know when the user clicked YouTube's fullscreen button or pressed `f`. Without the userscript it would have to guess by intercepting global shortcuts, polling geometry, or forcing fullscreen whenever a shared tab became active. Those approaches would disconnect native fullscreen from YouTube's actual state and could act when the user never requested it.

The userscript supplies fullscreen intent. The helper remains the authority for the native safety gate.

## How the bridge proves the selected tab is shared

`POST /enter` changes the window only when all of the following remain true:

1. The request includes the bridge capability token and a YouTube page-host header.
2. The frontmost application is a recognized Chromium- or Gecko-family browser.
3. macOS Accessibility permission is available.
4. The browser has a focused window.
5. The browser-owned active-document URL belongs to `youtube.com` or one of its subdomains.
6. The helper finds a sharing marker in browser chrome, never inside the page's `AXWebArea` subtree.
7. That sharing marker belongs to the selected tab, not a captured background tab or a window-wide sharing control.
8. The same URL and selected-tab sharing evidence remain present in a second observation 250 ms later.
9. The window is not already in native fullscreen.

Only then does the helper set `AXFullScreen = true`.

The second observation protects against a stale sharing badge immediately after capture stops. Binding evidence to the selected tab prevents a captured background tab from authorizing fullscreen for an unrelated active YouTube tab.

### Why webpage text and the window title are not trusted

A webpage controls its document title and every accessibility node under its web-content area. A hostile page could display text such as `Tab content shared` or put that phrase in `document.title`.

The helper therefore:

- skips every descendant of `AXWebArea` while collecting sharing evidence;
- does not use the root window title as authorization;
- accepts only browser-chrome roles and sharing identifiers/text; and
- requires the evidence to occur in the selected tab's accessibility branch.

The Chromium title suffix remains available only as a diagnostic utility and is not a policy gate.

### What “no-op” means

A no-op is a successful request that deliberately performs no operation. For example:

```json
{
  "changed": false,
  "message": "Chromium does not expose a sharing indicator on the selected tab."
}
```

This is the expected safe response when the active tab is not shared or when the browser does not expose enough evidence to prove it.

## Why other proposed detection methods are not used

The implementation was checked against browser, web-platform, and macOS alternatives:

| Technique | Why it does not authorize the bridge |
| --- | --- |
| `chrome.tabCapture.getCapturedTabs()` | Authoritative, but extension-only; using it would require the additional extension this project intentionally avoids. |
| Firefox `tabs.captureTab()` | Produces a still image, not a streaming tab-capture status API. |
| Capture Handle | Tells a cooperating capturing page about its capture target; it does not notify a captured page that it is being captured. |
| `getDisplayMedia()` events | Capture tracks and events exist in the capturing context, not in the captured YouTube page. |
| WebRTC stats | The captured YouTube page owns no relevant `RTCPeerConnection` for an extension's tab capture. |
| Chrome media/WebRTC internals | Diagnostic browser pages have no supported native API and would require extension or remote-debugging access to scrape. |
| Chrome DevTools Protocol / Firefox remote debugging | Requires a debugging port, adds a large local control surface, and has no stable cross-browser per-tab capture field. Useful only as a development oracle. |
| Process arguments | Browser process command lines do not expose per-tab capture state. |
| ScreenCaptureKit / TCC | macOS can report this helper's capture permissions and shareable windows; it cannot enumerate another process's intra-browser tab captures. |
| CoreAudio taps | Can capture or observe browser audio, but cannot distinguish a normal playing tab from an internally captured tab. |
| `CGWindowList` | Can corroborate window identity or screen-sharing overlays, but exposes no “this tab is captured” flag. |
| Screenshot/OCR | Requires Screen Recording permission, is theme/layout fragile, and is weaker than the browser's accessibility state. |

Browser-owned, selected-tab accessibility state is the strongest practical proof available without adding an extension or enabling a remote-debugging interface.

## End-to-end flow

```text
You click YouTube fullscreen or press f
                 │
                 ▼
YouTube enters DOM/player fullscreen
                 │
                 ▼
Userscript sends POST /enter to 127.0.0.1
                 │
                 ▼
Helper verifies browser + YouTube URL
                 │
                 ▼
Helper scans browser chrome only
                 │
                 ▼
Sharing marker belongs to selected tab?
          ┌──────┴──────┐
          │             │
         yes            no / unknown
          │             │
          ▼             ▼
Recheck after 250 ms   Return changed:false
          │
          ▼
Set AXFullScreen on the exact window
          │
          ▼
macOS moves the browser into a fullscreen Space
```

On exit, the helper retains the actual `AXUIElement` window reference it changed—not merely a process ID or whichever window happens to be focused later. It restores only that exact owned window.

## Requirements

- macOS 12 or newer
- a Chromium- or Gecko-family browser that exposes the required state through Accessibility
- YouTube over HTTPS
- a userscript manager supporting `GM.xmlHttpRequest` or `GM_xmlhttpRequest`
- Accessibility permission for `YouTube Real Fullscreen Bridge.app`

No purpose-built browser extension is included.

## Install the ready-to-use package

The repository includes:

```text
release/YouTube Real Fullscreen.zip
```

1. Unzip the archive.
2. Run `Install Bridge.command` from the extracted folder.
3. Open **System Settings → Privacy & Security → Accessibility**.
4. Add or enable **YouTube Real Fullscreen Bridge.app**. If an older or deleted copy is listed, remove it and add the freshly installed copy from:

   ```text
   ~/Applications/YouTube Real Fullscreen Bridge.app
   ```

5. Open `youtube-real-fullscreen.user.js` with Violentmonkey, Tampermonkey, Greasemonkey, or another compatible manager and choose **Install** or **Reinstall**.
6. Reload every already-open YouTube tab so version 1.1.0 is injected.
7. In a Chromium browser, disable an “always show toolbar in fullscreen” preference if you want completely edge-to-edge video.

Activate tab sharing, confirm the selected tab shows its browser sharing marker, then use YouTube's normal fullscreen button or press `f`.

## Install from source

Build and test:

```bash
swift test
./script/build_and_run.sh --verify
```

The build script creates an ad-hoc signed app bundle at:

```text
dist/YouTube Real Fullscreen Bridge.app
```

Install it and its per-user launch agent:

```bash
./Install\ Bridge.command
```

The installer copies the app to `~/Applications`, writes `~/Library/LaunchAgents/local.codex.youtube-real-fullscreen.plist`, and starts the agent. Then install the repository's root `youtube-real-fullscreen.user.js` file in your userscript manager and reload YouTube.

## Verify the installation

Check the loopback service:

```bash
curl http://127.0.0.1:38471/health
```

Expected response:

```json
{"changed":false,"message":"ready"}
```

Check the launch agent:

```bash
launchctl print "gui/$(id -u)/local.codex.youtube-real-fullscreen"
```

Inspect the frontmost browser and policy evidence using a development build:

```bash
./script/build_and_run.sh --probe
```

Important probe fields:

- `engine`: detected `chromium` or `gecko` engine;
- `documentURL`: browser-owned active document URL;
- `sharingIndicator`: whether the selected tab passed the sharing gate;
- `sharingCandidates`: browser-chrome elements that looked like sharing evidence;
- `tabCandidates`: tab-strip elements and selected-tab correlation;
- `trusted`: current Accessibility authorization;
- `fullscreen`: native window fullscreen state.

Run automated policy/parser tests:

```bash
swift test
```

The suite covers:

- case-insensitive request headers;
- incomplete, oversized, and duplicate-header rejection;
- strict methods and routes;
- known and runtime-discovered Chromium/Gecko engines;
- exact YouTube host validation;
- Chromium and Gecko sharing labels/identifiers;
- rejection of page-owned sharing text;
- rejection of a captured background tab; and
- acceptance only when YouTube and selected-tab evidence are both present.

## Cross-browser manual test matrix

For every browser/manager pair being qualified:

1. Open a YouTube video without sharing and enter/exit player fullscreen. The helper must not change the native window.
2. Share the selected YouTube tab and repeat. The browser window should enter/exit a native macOS fullscreen Space.
3. Share a background tab in the same window, then select an unshared YouTube tab. The helper must perform a no-op.
4. Select a non-YouTube shared tab. The helper must perform a no-op.
5. Stop sharing immediately after entering player fullscreen. The 250 ms recheck must prevent a stale enter.
6. Exit fullscreen during a slow request. The userscript's generation guard must compensate with `/exit`.
7. Navigate to another YouTube video without a full reload. The `yt-navigate-finish` path must preserve correct behavior.
8. Close or background the page after native entry. Lifecycle cleanup must restore only the owned window.

Recommended matrix:

- Helium + Violentmonkey
- Chrome or Chromium + Tampermonkey/Violentmonkey
- Firefox + Greasemonkey/Violentmonkey, using a real Firefox tab-sharing session
- Zen or another Gecko fork with its normal sharing indicator

Verified results in this repository version:

- Helium + Violentmonkey + a Chromium tab-capture session: selected-tab sharing evidence was detected and the helper entered/restored the exact native window.
- Twilight 1.22t + Violentmonkey + Volume Master 1.0.1 at 200%: Twilight entered and exited native YouTube fullscreen on its own; no selected-tab sharing marker was exposed, so the helper correctly performed a no-op.

## Troubleshooting

### The video grows but browser chrome remains

Confirm:

- userscript version 1.1.0 is enabled for the current YouTube host;
- the page was reloaded after installation;
- the helper health endpoint returns `ready`;
- the newly installed helper—not an old or deleted copy—is enabled in Accessibility;
- the selected tab, rather than a background tab, shows the sharing indicator; and
- the browser exposes that indicator through Accessibility.

Run `./script/build_and_run.sh --probe` from a source checkout to see which gate failed.

### The player shows a bridge error

The userscript displays a short in-player toast when the helper is unreachable, permission is missing, or the frontmost application is unsupported. Run the installer, verify the health endpoint, and verify Accessibility permission.

### Accessibility is enabled but the helper is not trusted

Ad-hoc signed local builds can require a fresh Accessibility entry after the app is rebuilt. Remove the old helper entry, add `~/Applications/YouTube Real Fullscreen Bridge.app`, enable it, then restart the launch agent:

```bash
launchctl kickstart -k "gui/$(id -u)/local.codex.youtube-real-fullscreen"
```

### Fullscreen immediately exits

Confirm userscript version 1.1.0 is installed. The script includes the delayed exit check and generation guard required for native Space transition races.

### Gecko reports no selected-tab sharing indicator

Firefox-family browsers can vary in how their XUL tab-sharing state is mapped into macOS Accessibility, especially with vertical-tab or heavily customized interfaces. First test whether the browser already enters real native fullscreen. If it does, no bridge action is needed. If browser chrome remains visible, verify that a real WebRTC/display-capture session is active, run `--probe`, and inspect `tabCandidates`. Unknown or ambiguous structures intentionally fail closed.

### View helper telemetry

```bash
./script/build_and_run.sh --telemetry
```

## Privacy and security model

- The helper makes no outbound network requests.
- The listener binds only to IPv4 loopback, not the LAN or internet.
- State-changing requests require a capability header.
- The token prevents accidental browser requests and basic cross-site invocation. It is distributed with both local components and is not treated as a secret from other local processes.
- `/enter` also requires the YouTube page-host context header, but the native browser checks—not this header—remain authoritative.
- HTTP headers are capped at 8,192 bytes; duplicate headers, malformed requests, unknown routes, and unexpected methods are rejected.
- Page-owned accessibility descendants are never scanned for sharing evidence.
- The active YouTube URL and selected-tab sharing evidence are revalidated natively on every enter and sampled twice.
- The helper stores only the exact accessibility window reference it changed, plus transient process/browser identity for restoration and logging.
- The helper does not capture audio, video, screenshots, page contents, or browsing history.

## Limitations

- This is a macOS-native solution because it uses AppKit and Accessibility.
- YouTube is intentionally the only supported site.
- A browser must expose its selected-tab sharing state through Accessibility. Browser/fork/UI versions that do not expose it will fail closed.
- Accessibility strings can be localized. Stable sharing identifiers are preferred when exposed; an unrecognized translation may require adding a tested phrase and will otherwise fail closed.
- Firefox/Gecko volume-enhancement paths that do not expose a browser-owned selected-tab sharing marker will not trigger the bridge. Native browser fullscreen remains available when the browser itself permits it.
- Accessibility permission is unavoidable for native window control.
- A userscript manager is required for the narrowly granted HTTPS-to-loopback request.
- The included app is ad-hoc signed for local installation, not Developer ID signed or notarized for broad distribution.
- Without an additional extension, no browser-neutral cryptographic capture attestation exists. Browser-owned selected-tab accessibility state is the strongest practical local evidence available.

## Repository layout

```text
.
├── Package.swift
├── Sources/
│   ├── BridgeCore/HTTPRequest.swift
│   └── YouTubeRealFullscreenBridge/main.swift
├── Tests/BridgeCoreTests/HTTPRequestTests.swift
├── youtube-real-fullscreen.user.js
├── Install Bridge.command
├── Uninstall Bridge.command
├── script/build_and_run.sh
├── dist/YouTube Real Fullscreen Bridge.app
└── release/YouTube Real Fullscreen.zip
```

- `BridgeCore` contains the parser, browser detection, YouTube validation, and sharing policy that can be tested without AppKit.
- `YouTubeRealFullscreenBridge` contains the Accessibility inspection, exact-window ownership, and loopback server.
- `dist/` contains the built local helper.
- `release/` contains the ready-to-install package.

## Uninstall

1. Disable or remove **YouTube Real Fullscreen for Shared Tabs** in the userscript manager.
2. Run `Uninstall Bridge.command`.
3. Optionally remove the helper from **System Settings → Privacy & Security → Accessibility**.

The uninstall script stops the launch agent and moves both the app and launch-agent plist to Trash so they remain recoverable.
