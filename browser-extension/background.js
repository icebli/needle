(function startNeedleBackground() {
  "use strict";

  const HOST_NAME = "dev.tege.needle.browser";
  const snapshots = new Map();

  function installMenus() {
    browser.contextMenus.removeAll().then(() => {
      browser.contextMenus.create({
        id: "needle-page",
        title: "Download this page with Needle",
        contexts: ["page", "video", "audio"],
        documentUrlPatterns: ["http://*/*", "https://*/*"],
      });
      browser.contextMenus.create({
        id: "needle-link",
        title: "Download linked track with Needle",
        contexts: ["link"],
        targetUrlPatterns: ["http://*/*", "https://*/*"],
      });
    });
  }

  browser.runtime.onInstalled.addListener(installMenus);
  browser.runtime.onStartup.addListener(installMenus);
  installMenus();

  async function settings() {
    const stored = await browser.storage.local.get({
      playlistEnabled: true,
      playlistName: "Needle",
    });
    return stored;
  }

  async function probeTab(tabId) {
    await browser.tabs.executeScript(tabId, { file: "track-detection.js" });
    const results = await browser.tabs.executeScript(tabId, { file: "page-probe.js" });
    return results && results[0];
  }

  async function setStatus(status) {
    await browser.storage.local.set({ lastStatus: { ...status, updatedAt: Date.now() } });
  }

  async function notify(title, message, isError) {
    await browser.notifications.create({
      type: "basic",
      iconUrl: browser.runtime.getURL("icons/needle.svg"),
      title,
      message,
      priority: isError ? 2 : 0,
    });
  }

  async function downloadTrack(track, playlistOverride) {
    if (!track?.sourceUrl || !track?.artist || !track?.title) {
      throw new Error("Needle needs an artist and title. Open the toolbar popup to edit them.");
    }
    const stored = await settings();
    const playlist = playlistOverride || {
      enabled: stored.playlistEnabled,
      name: stored.playlistName,
    };
    await setStatus({ phase: "working", message: "Resolving metadata…", track });

    let response;
    try {
      response = await browser.runtime.sendNativeMessage(HOST_NAME, {
        action: "download",
        sourceUrl: track.sourceUrl,
        artist: track.artist,
        title: track.title,
        album: track.album || null,
        playlist,
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
        const input = snapshot && snapshot.url === info.linkUrl
          ? snapshot
          : { url: info.linkUrl, linkText: info.linkText || "" };
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

  browser.contextMenus.onClicked.addListener((info, tab) => {
    if (info.menuItemId === "needle-page" || info.menuItemId === "needle-link") {
      void handleContextClick(info, tab);
    }
  });

  browser.tabs.onRemoved.addListener((tabId) => snapshots.delete(tabId));

  browser.runtime.onMessage.addListener((message, sender) => {
    if (message?.type === "contextSnapshot" && sender.tab?.id != null) {
      snapshots.set(sender.tab.id, message.snapshot);
      return undefined;
    }
    if (message?.type === "probe" && Number.isInteger(message.tabId)) {
      return probeTab(message.tabId);
    }
    if (message?.type === "doctor") {
      return browser.runtime.sendNativeMessage(HOST_NAME, { action: "doctor" });
    }
    if (message?.type === "download") {
      return downloadTrack(message.track, message.playlist);
    }
    return undefined;
  });
})();
