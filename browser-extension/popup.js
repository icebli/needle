(function startNeedlePopup() {
  "use strict";

  const elements = Object.fromEntries([
    "artist", "title", "source-link", "source-site", "source-url", "download-button",
    "playlist-check", "settings-button", "download-panel", "settings-panel", "back-button",
    "playlist-name", "playlist-enabled", "doctor-button", "status-text", "status-dot", "status-spinner",
  ].map((id) => [id.replace(/-([a-z])/g, (_, letter) => letter.toUpperCase()), document.getElementById(id)]));
  let currentTrack = null;

  function setStatus(phase, message) {
    const footer = elements.statusText.closest(".status");
    footer.className = `status ${phase || ""}`;
    elements.statusText.textContent = message;
    elements.statusSpinner.hidden = phase !== "working";
  }

  function updateButton() {
    elements.downloadButton.disabled = !(
      currentTrack?.sourceUrl && elements.artist.value.trim() && elements.title.value.trim()
    );
  }

  function showTrack(track) {
    currentTrack = track;
    elements.artist.value = track?.artist || "";
    elements.title.value = track?.title || "";
    elements.sourceSite.textContent = track?.site || "Current page";
    elements.sourceUrl.textContent = track?.sourceUrl || "No supported page detected";
    elements.sourceLink.href = track?.sourceUrl || "#";
    updateButton();
  }

  async function loadSettings() {
    const stored = await browser.storage.local.get({
      playlistEnabled: true,
      playlistName: "Needle",
      lastStatus: null,
    });
    elements.playlistEnabled.checked = stored.playlistEnabled;
    elements.playlistCheck.checked = stored.playlistEnabled;
    elements.playlistName.value = stored.playlistName;
    if (stored.lastStatus?.message) setStatus(stored.lastStatus.phase, stored.lastStatus.message);
  }

  async function detectPage() {
    try {
      const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
      const track = await browser.runtime.sendMessage({ type: "probe", tabId: tab.id });
      showTrack(track);
      if (!track?.complete) {
        setStatus("error", "Add the missing artist or title before downloading");
      }
    } catch (error) {
      showTrack(null);
      setStatus("error", `Page detection unavailable: ${error.message || error}`);
    }
  }

  async function checkConnection() {
    setStatus("working", "Checking Needle bridge…");
    try {
      const response = await browser.runtime.sendMessage({ type: "doctor" });
      setStatus(response?.ok ? "ready" : "error", response?.message || "Needle bridge unavailable");
    } catch (error) {
      setStatus("error", `Needle bridge unavailable: ${error.message || error}`);
    }
  }

  elements.artist.addEventListener("input", updateButton);
  elements.title.addEventListener("input", updateButton);
  elements.settingsButton.addEventListener("click", () => {
    elements.downloadPanel.hidden = true;
    elements.settingsPanel.hidden = false;
  });
  elements.backButton.addEventListener("click", () => {
    elements.settingsPanel.hidden = true;
    elements.downloadPanel.hidden = false;
  });
  elements.playlistCheck.addEventListener("change", async () => {
    elements.playlistEnabled.checked = elements.playlistCheck.checked;
    await browser.storage.local.set({ playlistEnabled: elements.playlistCheck.checked });
  });
  elements.playlistEnabled.addEventListener("change", async () => {
    elements.playlistCheck.checked = elements.playlistEnabled.checked;
    await browser.storage.local.set({ playlistEnabled: elements.playlistEnabled.checked });
  });
  elements.playlistName.addEventListener("change", async () => {
    const value = elements.playlistName.value.trim() || "Needle";
    elements.playlistName.value = value;
    await browser.storage.local.set({ playlistName: value });
  });
  elements.doctorButton.addEventListener("click", checkConnection);
  elements.downloadButton.addEventListener("click", async () => {
    const track = {
      ...currentTrack,
      artist: elements.artist.value.trim(),
      title: elements.title.value.trim(),
    };
    elements.downloadButton.disabled = true;
    setStatus("working", "Resolving metadata…");
    try {
      const response = await browser.runtime.sendMessage({
        type: "download",
        track,
        playlist: {
          enabled: elements.playlistCheck.checked,
          name: elements.playlistName.value.trim() || "Needle",
        },
      });
      setStatus("saved", response.message);
    } catch (error) {
      setStatus("error", error.message || String(error));
    } finally {
      updateButton();
    }
  });

  browser.storage.onChanged.addListener((changes, area) => {
    if (area === "local" && changes.lastStatus?.newValue) {
      const status = changes.lastStatus.newValue;
      setStatus(status.phase, status.message);
    }
  });

  void (async () => {
    await loadSettings();
    await Promise.all([detectPage(), checkConnection()]);
  })();
})();
