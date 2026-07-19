// ==UserScript==
// @name         YouTube Real Fullscreen for Shared Tabs
// @namespace    local.codex.youtube-real-fullscreen
// @version      1.1.0
// @description  Preserves YouTube's native macOS fullscreen while a Chromium- or Gecko-based browser is sharing the tab.
// @author       Local
// @match        https://youtube.com/*
// @match        https://*.youtube.com/*
// @grant        GM_xmlhttpRequest
// @grant        GM.xmlHttpRequest
// @connect      127.0.0.1
// @run-at       document-start
// @noframes
// @homepageURL  https://github.com/clockworksquirrel/volume-master-fullscreen
// @downloadURL  https://raw.githubusercontent.com/clockworksquirrel/volume-master-fullscreen/main/youtube-real-fullscreen.user.js
// @updateURL    https://raw.githubusercontent.com/clockworksquirrel/volume-master-fullscreen/main/youtube-real-fullscreen.user.js
// ==/UserScript==

(() => {
  "use strict";

  if (window.top !== window.self) return;

  const SCRIPT_VERSION = "1.1.0";
  const BRIDGE_ORIGIN = "http://127.0.0.1:38471";
  const BRIDGE_TOKEN = "792c7cdbaa0561ce2e0f2534d75b7d5aa689a7648f41d3b6dde476ff23a6af5a";
  const ENTER_DELAY_MS = 350;
  const EXIT_DELAY_MS = 1800;
  const REQUEST_TIMEOUT_MS = 3000;

  let bridgeEnteredFullscreen = false;
  let pendingEnter = 0;
  let pendingExit = 0;
  let operationGeneration = 0;
  let lastErrorMessage = "";

  function getFullscreenElement() {
    return document.fullscreenElement
      || document.webkitFullscreenElement
      || document.mozFullScreenElement
      || null;
  }

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
    window.setTimeout(() => {
      toast.remove();
      if (lastErrorMessage === message) lastErrorMessage = "";
    }, 5200);
  }

  function requestFunction() {
    if (typeof GM !== "undefined" && typeof GM.xmlHttpRequest === "function") {
      return GM.xmlHttpRequest.bind(GM);
    }
    if (typeof GM_xmlhttpRequest === "function") {
      return GM_xmlhttpRequest;
    }
    return null;
  }

  function callBridge(action) {
    return new Promise((resolve, reject) => {
      const request = requestFunction();
      if (!request) {
        reject(new Error("This userscript manager does not provide cross-origin requests."));
        return;
      }

      let settled = false;
      let requestHandle;
      const finish = (callback, value) => {
        if (settled) return;
        settled = true;
        window.clearTimeout(fallbackTimeout);
        callback(value);
      };
      const handleLoad = (response) => {
        let body;
        try {
          body = JSON.parse(response.responseText || "{}");
        } catch {
          finish(reject, new Error("The fullscreen bridge returned an invalid response."));
          return;
        }

        if (response.status >= 200 && response.status < 300) {
          finish(resolve, body);
        } else {
          finish(reject, new Error(body.message || `Fullscreen bridge error ${response.status}.`));
        }
      };
      const handleConnectionError = () => {
        finish(reject, new Error("Start YouTube Real Fullscreen Bridge, then try fullscreen again."));
      };
      const handleTimeout = () => {
        finish(reject, new Error("The fullscreen bridge did not respond."));
      };
      const fallbackTimeout = window.setTimeout(() => {
        if (requestHandle && typeof requestHandle.abort === "function") {
          requestHandle.abort();
        }
        handleTimeout();
      }, REQUEST_TIMEOUT_MS + 500);

      const options = {
        method: "POST",
        url: `${BRIDGE_ORIGIN}/${action}`,
        headers: {
          "X-YRF-Token": BRIDGE_TOKEN,
          "X-YRF-Page-Host": location.hostname,
          "X-YRF-Page-Origin": location.origin,
          "X-YRF-Script-Version": SCRIPT_VERSION,
        },
        timeout: REQUEST_TIMEOUT_MS,
        onload: handleLoad,
        onerror: handleConnectionError,
        ontimeout: handleTimeout,
      };

      try {
        requestHandle = request(options);
        if (requestHandle && typeof requestHandle.then === "function") {
          requestHandle.then(handleLoad, handleConnectionError);
        }
      } catch (error) {
        finish(reject, error instanceof Error ? error : new Error(String(error)));
      }
    });
  }

  async function enterNativeFullscreenIfShared(generation) {
    try {
      const result = await callBridge("enter");

      // A slow /enter response may arrive after the page has already exited
      // fullscreen. Compensate immediately so native fullscreen cannot get stuck.
      if (generation !== operationGeneration || !getFullscreenElement()) {
        if (result.changed === true) {
          await callBridge("exit");
        }
        return;
      }

      if (result.changed === true) bridgeEnteredFullscreen = true;
      lastErrorMessage = "";
    } catch (error) {
      console.warn("[YouTube Real Fullscreen]", error);
      showPlayerMessage(error instanceof Error ? error.message : String(error));
    }
  }

  async function restoreNativeWindow(generation) {
    if (!bridgeEnteredFullscreen || generation !== operationGeneration) return;
    bridgeEnteredFullscreen = false;

    try {
      await callBridge("exit");
      lastErrorMessage = "";
    } catch (error) {
      // Preserve ownership so a later lifecycle event can retry the restore.
      bridgeEnteredFullscreen = true;
      console.warn("[YouTube Real Fullscreen]", error);
    }
  }

  function handleFullscreenChange() {
    const generation = ++operationGeneration;
    window.clearTimeout(pendingEnter);
    window.clearTimeout(pendingExit);

    if (getFullscreenElement()) {
      pendingEnter = window.setTimeout(
        () => void enterNativeFullscreenIfShared(generation),
        ENTER_DELAY_MS,
      );
    } else {
      // Browsers can briefly leave DOM fullscreen while macOS moves the window
      // into its fullscreen Space. Confirm the exit after that transition settles.
      pendingExit = window.setTimeout(() => {
        if (!getFullscreenElement() && generation === operationGeneration) {
          void restoreNativeWindow(generation);
        }
      }, EXIT_DELAY_MS);
    }
  }

  for (const eventName of ["fullscreenchange", "webkitfullscreenchange", "mozfullscreenchange"]) {
    document.addEventListener(eventName, handleFullscreenChange, true);
  }

  document.addEventListener("fullscreenerror", () => {
    const generation = ++operationGeneration;
    window.clearTimeout(pendingEnter);
    window.clearTimeout(pendingExit);
    void restoreNativeWindow(generation);
  }, true);

  document.addEventListener("yt-navigate-finish", () => {
    if (!getFullscreenElement()) {
      const generation = ++operationGeneration;
      void restoreNativeWindow(generation);
    }
  }, true);

  document.addEventListener("visibilitychange", () => {
    if (document.hidden && !getFullscreenElement()) {
      const generation = ++operationGeneration;
      void restoreNativeWindow(generation);
    }
  }, true);

  window.addEventListener("pagehide", (event) => {
    if (event.persisted) return;
    const generation = ++operationGeneration;
    window.clearTimeout(pendingEnter);
    window.clearTimeout(pendingExit);
    void restoreNativeWindow(generation);
  });
})();
