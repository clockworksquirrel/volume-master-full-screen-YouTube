// ==UserScript==
// @name         YouTube Real Fullscreen for Shared Tabs
// @namespace    local.codex.youtube-real-fullscreen
// @version      1.0.1
// @description  Makes YouTube's existing fullscreen control enter native macOS fullscreen when Volume Master is sharing the tab.
// @author       Local
// @match        https://www.youtube.com/*
// @grant        GM_xmlhttpRequest
// @connect      127.0.0.1
// @run-at       document-start
// ==/UserScript==

(() => {
  "use strict";

  const BRIDGE_ORIGIN = "http://127.0.0.1:38471";
  const BRIDGE_TOKEN = "792c7cdbaa0561ce2e0f2534d75b7d5aa689a7648f41d3b6dde476ff23a6af5a";
  const ENTER_DELAY_MS = 350;
  const EXIT_DELAY_MS = 1800;

  let bridgeEnteredFullscreen = false;
  let pendingEnter = 0;
  let pendingExit = 0;
  let lastErrorMessage = "";

  function showPlayerMessage(message) {
    if (!message || message === lastErrorMessage) return;
    lastErrorMessage = message;

    const player = document.querySelector(".html5-video-player") || document.body;
    if (!player) return;

    const toast = document.createElement("div");
    toast.textContent = message;
    Object.assign(toast.style, {
      position: "absolute",
      left: "50%",
      bottom: "84px",
      zIndex: "2147483647",
      maxWidth: "min(680px, 80vw)",
      padding: "10px 14px",
      borderRadius: "6px",
      color: "white",
      background: "rgba(0, 0, 0, 0.82)",
      font: "500 14px/1.35 system-ui, sans-serif",
      textAlign: "center",
      pointerEvents: "none",
      transform: "translateX(-50%)",
    });
    player.appendChild(toast);
    window.setTimeout(() => toast.remove(), 5200);
  }

  function callBridge(action) {
    return new Promise((resolve, reject) => {
      GM_xmlhttpRequest({
        method: "POST",
        url: `${BRIDGE_ORIGIN}/${action}`,
        headers: {
          "X-YRF-Token": BRIDGE_TOKEN,
        },
        timeout: 2500,
        onload(response) {
          let body;
          try {
            body = JSON.parse(response.responseText || "{}");
          } catch {
            reject(new Error("The fullscreen bridge returned an invalid response."));
            return;
          }

          if (response.status >= 200 && response.status < 300) {
            resolve(body);
          } else {
            reject(new Error(body.message || `Fullscreen bridge error ${response.status}.`));
          }
        },
        onerror() {
          reject(new Error("Start YouTube Real Fullscreen Bridge, then try fullscreen again."));
        },
        ontimeout() {
          reject(new Error("The fullscreen bridge did not respond."));
        },
      });
    });
  }

  async function enterNativeFullscreenIfShared() {
    try {
      const result = await callBridge("enter");
      bridgeEnteredFullscreen = result.changed === true;
    } catch (error) {
      console.warn("[YouTube Real Fullscreen]", error);
      showPlayerMessage(error.message);
    }
  }

  async function restoreNativeWindow() {
    if (!bridgeEnteredFullscreen) return;
    bridgeEnteredFullscreen = false;

    try {
      await callBridge("exit");
    } catch (error) {
      console.warn("[YouTube Real Fullscreen]", error);
    }
  }

  document.addEventListener("fullscreenchange", () => {
    window.clearTimeout(pendingEnter);
    window.clearTimeout(pendingExit);

    if (document.fullscreenElement) {
      pendingEnter = window.setTimeout(enterNativeFullscreenIfShared, ENTER_DELAY_MS);
    } else {
      // Chromium can briefly leave DOM fullscreen while macOS moves the
      // browser window into its fullscreen Space. Wait for that transition
      // to settle so a transient event does not immediately undo the bridge.
      pendingExit = window.setTimeout(() => {
        if (!document.fullscreenElement) {
          void restoreNativeWindow();
        }
      }, EXIT_DELAY_MS);
    }
  }, true);

  window.addEventListener("pagehide", () => {
    window.clearTimeout(pendingEnter);
    window.clearTimeout(pendingExit);
    void restoreNativeWindow();
  });
})();
