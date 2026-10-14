(function startNeedleBackground() {
  "use strict";

  importScripts("track-detection.js");

  const HOST_NAME = "dev.tege.needle.browser";
  const snapshots = new Map();

  function installMenus() {
    chrome.contextMenus.removeAll().then(() => {
      chrome.contextMenus.create({
        id: "needle-page",
        title: "Download this page with Needle",
        contexts: ["page", "video", "audio"],
        documentUrlPatterns: ["http://*/*", "https://*/*"],
      });
      chrome.contextMenus.create({
        id: "needle-link",
        title: "Download linked track with Needle",
        contexts: ["link"],
        targetUrlPatterns: ["http://*/*", "https://*/*"],
      });
    });
  }

  chrome.runtime.onInstalled.addListener(installMenus);
  chrome.runtime.onStartup.addListener(installMenus);
  installMenus();

  async function settings() {
    return chrome.storage.local.get({ playlistEnabled: true, playlistName: "Needle" });
  }

  async function probeTab(tabId) {
    await chrome.scripting.executeScript({ target: { tabId }, files: ["track-detection.js"] });
    const results = await chrome.scripting.executeScript({ target: { tabId }, files: ["page-probe.js"] });
    return results && results[0]?.result;
  }

  async function setStatus(status) {
    await chrome.storage.local.set({ lastStatus: { ...status, updatedAt: Date.now() } });
  }

  async function notify(title, message, isError) {
    await chrome.notifications.create({
      type: "basic",
      iconUrl: chrome.runtime.getURL("icons/needle-96.png"),
      title,
      message,
      priority: isError ? 2 : 0,
    });
  }

  // Use the callback form so the companion also works on Chrome releases
  // that predate Promise-returning runtime APIs.
  function sendNativeMessage(message) {
    return new Promise((resolve, reject) => {
      chrome.runtime.sendNativeMessage(HOST_NAME, message, (response) => {
        const error = chrome.runtime.lastError;
        if (error) {
          reject(new Error(error.message));
        } else {
          resolve(response);
        }
      });
    });
  }

  async function downloadTrack(track, playlistOverride) {
    if (!track?.sourceUrl || !track?.artist || !track?.title) {
      throw new Error("Needle needs an artist and title. Open the toolbar popup to edit them.");
    }
    const stored = await settings();
    const playlist = playlistOverride || { enabled: stored.playlistEnabled, name: stored.playlistName };
    await setStatus({ phase: "working", message: "Resolving metadata…", track });
    let response;
    try {
      response = await sendNativeMessage({
        action: "download", sourceUrl: track.sourceUrl, artist: track.artist, title: track.title,
        album: track.album || null, playlist,
      });
    } catch (error) {
      throw new Error(`Needle bridge unavailable: ${error.message || error}`);
    }
    if (!response?.ok) throw new Error(response?.message || "Needle download failed");
    await setStatus({ phase: "saved", message: response.message, track, result: response.result });
    await notify("Needle saved the track", response.message, false);
    return response;
  }

  async function handleContextClick(info, tab) {
    try {
      let track;
      if (info.menuItemId === "needle-link") {
        const snapshot = snapshots.get(tab.id);
        const input = snapshot && snapshot.url === info.linkUrl ? snapshot : { url: info.linkUrl, linkText: info.linkText || "" };
        track = globalThis.NeedleTrackDetection.detectTrack(input);
      } else {
        track = await probeTab(tab.id);
      }
      await downloadTrack(track);
    } catch (error) {
      const message = error.message || String(error);
      await setStatus({ phase: "error", message });
      await notify("Needle could not download this page", message, true);
    }
  }

  chrome.contextMenus.onClicked.addListener((info, tab) => {
    if (info.menuItemId === "needle-page" || info.menuItemId === "needle-link") void handleContextClick(info, tab);
  });
  chrome.tabs.onRemoved.addListener((tabId) => snapshots.delete(tabId));
  function respondWith(operation, sendResponse) {
    Promise.resolve(operation).then(
      (response) => sendResponse(response),
      (error) => sendResponse({ ok: false, message: error.message || String(error) }),
    );
    return true;
  }

  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message?.type === "contextSnapshot" && sender.tab?.id != null) {
      snapshots.set(sender.tab.id, message.snapshot);
      return undefined;
    }
    if (message?.type === "probe" && Number.isInteger(message.tabId)) return respondWith(probeTab(message.tabId), sendResponse);
    if (message?.type === "doctor") return respondWith(sendNativeMessage({ action: "doctor" }), sendResponse);
    if (message?.type === "download") return respondWith(downloadTrack(message.track, message.playlist), sendResponse);
    return undefined;
  });
})();
