# Volume Master Fullscreen

Restore true macOS fullscreen for YouTube in Helium while Volume Master is capturing the active tab.

This project deliberately keeps YouTube's existing fullscreen button and `f` keyboard shortcut. It does not add a replacement player control and it does not install another Chromium extension. It combines:

1. a small userscript that observes YouTube's own fullscreen state; and
2. a small native macOS helper that performs the window-level fullscreen action that webpage JavaScript is not allowed to perform.

Both pieces are required because the problem crosses a browser security boundary. The userscript can see what YouTube is doing inside the webpage, but it cannot control a native macOS window. The helper can control the Helium window after the user grants Accessibility permission, but it cannot reliably know whether YouTube intended to enter or exit player fullscreen. Together they bridge exactly that gap.

## The problem

Volume Master boosts or processes a tab's audio by capturing that tab. Helium/Chromium marks the captured tab with the small sharing square and exposes `Tab content shared` in the window's accessibility title.

When that capture is active, YouTube's fullscreen control can enter a contained, fullscreen-looking player while the Helium window itself remains in its ordinary desktop window. The video becomes larger, but browser chrome can remain visible and macOS does not move the window into a fullscreen Space. This feels more like an enlarged theater mode than true fullscreen.

Without tab capture, YouTube and Chromium normally coordinate two related transitions:

- **DOM fullscreen:** YouTube asks the browser to make its player element fullscreen with the Fullscreen API.
- **Native window fullscreen:** the browser moves its macOS window into a fullscreen Space and hides its normal window chrome.

During tab capture, the first transition can still happen while the second one is suppressed or contained. A page-level workaround alone cannot force Chromium to change that browser/window policy.

## Why the userscript is necessary

The userscript runs only on `https://www.youtube.com/*`. Its job is to observe the intent that only the page can report accurately.

It listens for YouTube's standard `fullscreenchange` event:

- when `document.fullscreenElement` becomes non-null, YouTube has entered player fullscreen;
- when it becomes null, YouTube has left player fullscreen.

This means the normal YouTube UI remains the source of truth. Clicking the existing fullscreen icon and pressing `f` both use the same path. The script does not guess from mouse positions, replace the player, poll the page continuously, or register a competing global hotkey.

After an enter event, the script waits briefly and sends `POST /enter` to the local helper. After an exit event, it sends `POST /exit` only if that helper previously reported that it changed the native window.

The script also handles a Chromium/macOS transition race. Moving a window into a fullscreen Space can briefly produce a page fullscreen exit event. Exiting the native window immediately would undo the transition that just began, so the script debounces the exit for 1.8 seconds and confirms that page fullscreen is still inactive before asking the helper to restore the window.

The request uses Violentmonkey's `GM_xmlhttpRequest` because the bridge is a loopback HTTP service reached from an HTTPS page. Ordinary page `fetch` is subject to the webpage's origin, mixed-content, and CORS restrictions. The userscript-manager request is narrowly allowed only for `127.0.0.1` by its metadata.

### Why the userscript cannot solve this alone

A userscript is still browser JavaScript. It can:

- observe YouTube's DOM and fullscreen events;
- call the browser Fullscreen API within the browser's rules; and
- send a request to a permitted local endpoint.

It cannot:

- call AppKit;
- set the macOS `AXFullScreen` window attribute;
- move a Helium window into a macOS fullscreen Space;
- override Chromium's tab-capture fullscreen policy; or
- grant itself Accessibility access.

Monkey-patching `requestFullscreen()`, resizing the video element, or hiding browser-visible page elements would only change content inside the tab. None of those actions makes the native window fullscreen.

## Why the native helper is necessary

The helper is a small Swift/AppKit executable packaged as `YouTube Real Fullscreen Bridge.app`. It performs one privileged desktop action: setting the focused Helium window's macOS `AXFullScreen` attribute.

macOS protects window automation behind Accessibility permission. Once the user enables the helper in **System Settings → Privacy & Security → Accessibility**, the helper can inspect the frontmost application's focused window and request native fullscreen.

The helper runs as an accessory application with no Dock icon or ordinary window. The installer adds a per-user launch agent so it starts at login and remains available to the userscript. It listens only on:

```text
127.0.0.1:38471
```

Its API is intentionally tiny:

| Request | Purpose |
| --- | --- |
| `GET /health` | Report whether the local bridge is running. |
| `POST /enter` | Enter native fullscreen if every shared-tab safety check passes. |
| `POST /exit` | Restore the window only if this helper previously put it in fullscreen. |

### Why the helper cannot solve this alone

The native process can see the frontmost application and window, but it does not have YouTube's DOM state. Without the userscript it would need to use a less reliable and more invasive strategy such as:

- intercepting keyboard shortcuts globally;
- replacing the meaning of the `f` key;
- polling window geometry or titles and guessing when the player changed; or
- forcing fullscreen whenever a captured tab becomes active, even if the user never requested it.

Those approaches would disconnect the behavior from YouTube's real fullscreen control. The userscript gives the helper an explicit enter/exit signal at the moment YouTube changes state.

## Shared-tab-only safety gate

The bridge is designed to be inactive on ordinary tabs. `POST /enter` changes a window only when all of the following are true:

1. Helium is the frontmost application.
2. The frontmost application has the exact bundle identifier `net.imput.helium`.
3. A focused Helium window can be obtained through the Accessibility API.
4. That window's title ends with the exact, case-insensitive suffix:

   ```text
    - Tab content shared - Helium
   ```

5. The window is not already in native fullscreen.

If the tab is not being shared, the helper returns a successful no-op response:

```json
{
  "changed": false,
  "message": "The active tab is not being shared."
}
```

The exit path is stateful as well. The helper stores the Helium process ID only after it successfully changes that window. A later `/exit` request cannot pull an unrelated window out of fullscreen; it restores only the window that this bridge previously changed.

This title check is the boundary requested by this project: native bridging applies only while Helium itself reports that the active tab content is shared.

## End-to-end flow

```text
You click YouTube fullscreen or press f
                 │
                 ▼
YouTube enters DOM/player fullscreen
                 │
                 ▼
Userscript receives fullscreenchange
                 │
                 ▼
Userscript sends authenticated POST /enter to 127.0.0.1
                 │
                 ▼
Helper verifies Helium + focused window + exact shared-tab title suffix
                 │
        ┌────────┴────────┐
        │                 │
   Shared tab        Ordinary tab
        │                 │
        ▼                 ▼
Set AXFullScreen     Return changed:false
        │
        ▼
macOS moves Helium into a fullscreen Space
```

When YouTube later exits player fullscreen, the userscript waits for the transition to settle and calls `/exit`. The helper restores the native window only when it owns that fullscreen transition.

## Requirements

- macOS 12 or newer
- Helium with bundle identifier `net.imput.helium`
- YouTube
- Volume Master, or another condition that causes Helium to show the `Tab content shared` marker
- Violentmonkey for installing the userscript
- Accessibility permission for the native helper

No additional purpose-built browser extension is included. The userscript uses the existing userscript manager.

## Install the ready-to-use package

The repository includes a ready-to-install archive at:

```text
release/YouTube Real Fullscreen.zip
```

1. Unzip `release/YouTube Real Fullscreen.zip`.
2. Run `Install Bridge.command` from the extracted folder.
3. Open **System Settings → Privacy & Security → Accessibility**.
4. Add or enable **YouTube Real Fullscreen Bridge.app**. If an older copy is listed, remove it and add the newly installed copy from:

   ```text
   ~/Applications/YouTube Real Fullscreen Bridge.app
   ```

5. Open `youtube-real-fullscreen.user.js` with Violentmonkey and choose **Install** or **Reinstall**.
6. Reload any already-open YouTube tabs so the new userscript is injected.
7. In Helium, turn off **View → Always Show Toolbar in Full Screen** if you want edge-to-edge video without the fullscreen toolbar.

Now activate Volume Master for the YouTube tab, confirm that Helium shows the sharing square, and use YouTube's regular fullscreen button or press `f`.

## Install from a source checkout

The repository also contains the complete Swift package and tests.

Build and test:

```bash
swift test
./script/build_and_run.sh --verify
```

The build script creates an ad-hoc signed app bundle at:

```text
dist/YouTube Real Fullscreen Bridge.app
```

Then run:

```bash
./Install\ Bridge.command
```

The installer accepts either repository layout (`dist/…`) or release-package layout (the app beside the installer). It copies the helper to `~/Applications`, creates `~/Library/LaunchAgents/local.codex.youtube-real-fullscreen.plist`, and starts the launch agent.

Install the root `youtube-real-fullscreen.user.js` file in Violentmonkey and reload YouTube.

## Normal use

There is no separate fullscreen control to learn:

- click YouTube's fullscreen icon; or
- focus the YouTube player and press `f`.

When the active tab is shared, the helper bridges that action into native macOS fullscreen. When the active tab is not shared, the bridge does nothing and YouTube/Helium keep their normal behavior.

## Verify the installation

Check that the helper is listening:

```bash
curl http://127.0.0.1:38471/health
```

Expected result:

```json
{"changed":false,"message":"ready"}
```

Check the launch agent:

```bash
launchctl print "gui/$(id -u)/local.codex.youtube-real-fullscreen"
```

Build and run the policy/parser tests:

```bash
swift test
```

The test suite covers:

- case-insensitive token-header parsing;
- request-size and completeness rejection;
- allowed HTTP methods and routes;
- exact shared-tab title detection; and
- rejection of non-Helium or unshared windows.

## Troubleshooting

### The video grows, but the browser chrome remains

Confirm all of the following:

- the userscript is enabled for `youtube.com`;
- the YouTube page was reloaded after installing or updating the script;
- the helper health endpoint returns `ready`;
- the newly installed helper—not a deleted or older copy—is enabled in Accessibility;
- the active tab shows the sharing square and Helium reports `Tab content shared`; and
- **Always Show Toolbar in Full Screen** is disabled if the remaining UI is Helium's fullscreen toolbar.

### The player shows a bridge error message

The userscript displays a short in-player toast when the helper is unreachable or macOS permission is missing. Start the helper or run `Install Bridge.command`, then verify Accessibility permission.

### Accessibility is enabled but the helper still cannot control Helium

Remove the old helper entry from Accessibility, add `~/Applications/YouTube Real Fullscreen Bridge.app` again, enable it, and restart the launch agent:

```bash
launchctl kickstart -k "gui/$(id -u)/local.codex.youtube-real-fullscreen"
```

### Fullscreen enters and immediately exits

Make sure userscript version 1.0.1 or later is installed. Version 1.0.1 added the delayed exit check needed for Chromium's transient fullscreen event during the macOS Space transition.

### Inspect helper telemetry

Build and start the development helper with its unified log stream:

```bash
./script/build_and_run.sh --telemetry
```

Or inspect current frontmost-window information from a development build:

```bash
./script/build_and_run.sh --probe
```

## Privacy and security model

- The helper makes no outbound network requests.
- The listener binds only to IPv4 loopback (`127.0.0.1`), not to the LAN or internet.
- State-changing routes require the matching `X-YRF-Token` request header.
- The token blocks accidental requests and ordinary cross-site form submissions; it is a local capability value distributed with both components, not a remote account secret.
- Requests are capped at 8,192 bytes.
- Unknown routes and unexpected HTTP methods are rejected.
- The helper checks the frontmost bundle identifier and exact shared-tab window-title suffix again on every enter request. The userscript cannot bypass that native-side gate.
- Accessibility access is used only to read the focused Helium window title/fullscreen state and set that window's fullscreen attribute.
- The helper remembers only the process ID of a window it changed. It does not record browsing history, video titles, audio, or page content.

## Limitations

- The native helper currently targets Helium only.
- The userscript currently targets YouTube only.
- The shared-state check depends on Helium's current accessibility window-title suffix. A future Helium/Chromium title-format change may require updating `isSharedTabWindowTitle`.
- macOS Accessibility permission is unavoidable for native window control.
- A userscript manager is required because an ordinary page script cannot make the privileged loopback request reliably from YouTube's HTTPS origin.
- The included helper is ad-hoc signed for local installation, not Developer ID signed or notarized for broad distribution.

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

- `BridgeCore` contains the small HTTP parser, route matching, and shared-tab policy that can be unit tested without launching AppKit.
- `YouTubeRealFullscreenBridge` contains the AppKit/Accessibility controller and loopback server.
- `dist/` contains the built local helper app.
- `release/` contains the complete ready-to-install package.

## Uninstall

1. Disable or delete **YouTube Real Fullscreen for Shared Tabs** in Violentmonkey.
2. Run `Uninstall Bridge.command`.
3. Optionally remove the helper entry from **System Settings → Privacy & Security → Accessibility**.

The uninstall script stops the launch agent and moves both the installed app and its launch-agent plist to Trash, keeping them recoverable.

