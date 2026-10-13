(function installNeedlePlaylistCompanion(root, factory) {
  const companion = factory();
  if (typeof module === "object" && module.exports) module.exports = companion;
  if (root.Spicetify) void companion.start(root.Spicetify);
})(typeof globalThis !== "undefined" ? globalThis : this, function createNeedlePlaylistCompanion() {
  "use strict";

  const QUEUE_SERVER = "http://127.0.0.1:29878";
  const POLL_INTERVAL_MS = 5000;
  const playlistCache = new Map();
  // Spotify's RootlistAPI.createPlaylist currently resolves without a URI on
  // some desktop builds. Remember that creation is in flight so each poll
  // does not create another playlist while Spotify refreshes the rootlist.
  const playlistCreationPending = new Set();
  const activeJobs = new Set();
  const missingAttempts = new Map();
  const pendingAdds = new Map();
  const ADD_CONFIRM_ATTEMPTS = 6;
  const ADD_CONFIRM_DELAY_MS = 500;

  function normalize(value) {
    return String(value || "")
      .normalize("NFKD")
      .replace(/[\u0300-\u036f]/g, "")
      .toLowerCase()
      .replace(/[^\p{L}\p{N}\s]/gu, " ")
      .replace(/\s+/g, " ")
      .trim();
  }

  function artistFromLocal(track) {
    return track?.album?.artist?.name || track?.artists?.[0]?.name || track?.artist?.name || "";
  }

  function albumFromLocal(track) {
    return track?.album?.name || track?.album?.title || "";
  }

  function pathFromLocal(track) {
    return track?.path || track?.filePath || track?.file?.path || track?.localFile?.path || "";
  }

  function durationSecondsFromURI(uri) {
    if (typeof uri !== "string") return null;
    const value = Number(uri.slice(uri.lastIndexOf(":") + 1));
    return Number.isInteger(value) && value >= 0 ? value : null;
  }

  function durationMatches(track, durationMs) {
    if (!Number.isFinite(durationMs) || durationMs < 0) return false;
    const expectedSeconds = Math.floor(durationMs / 1000);
    const uriSeconds = durationSecondsFromURI(track?.uri);
    if (uriSeconds !== null) return uriSeconds === expectedSeconds;
    const localDuration = Number(track?.duration ?? track?.duration_ms ?? track?.durationMs);
    return Number.isFinite(localDuration) && Math.floor(localDuration / 1000) === expectedSeconds;
  }

  function trackKey(artist, title) {
    return `${normalize(artist)}::${normalize(title)}`;
  }

  function localKey(track) {
    return trackKey(artistFromLocal(track), track?.name);
  }

  function findLocalTrack(localTracks, requested) {
    const exactKey = trackKey(requested.artist, requested.name);
    const exactMatches = localTracks.filter((track) => localKey(track) === exactKey);
    const titleMatches = localTracks.filter((track) => normalize(track?.name) === normalize(requested.name));
    const candidates = exactMatches.length > 0 ? exactMatches : titleMatches;
    if (!candidates.length) return null;

    if (requested.savedPath) {
      const pathMatches = candidates.filter((track) => pathFromLocal(track) === requested.savedPath);
      if (pathMatches.length === 1) return pathMatches[0];
      if (pathMatches.length > 1) return null;
    }

    if (requested.durationMs != null) {
      const durationCandidates = candidates.filter((track) => durationMatches(track, requested.durationMs));
      if (durationCandidates.length === 1) return durationCandidates[0];
      // A queued duration is part of the downloaded file identity. If Spotify
      // cannot expose that duration, do not fall back to a same-tag recording.
      return null;
    }

    if (candidates.length > 0 && requested.album) {
      const albumKey = normalize(requested.album);
      const albumMatches = candidates.filter((track) => normalize(albumFromLocal(track)) === albumKey);
      if (albumMatches.length === 1) return albumMatches[0];
      if (albumMatches.length > 1) return null;
      // Older Spotify builds may omit local album metadata. Only fall back
      // when there is one candidate and no album value that contradicts it.
      if (candidates.length === 1 && !albumFromLocal(candidates[0])) return candidates[0];
      return null;
    }
    return candidates.length === 1 ? candidates[0] : null;
  }

  function playlistIndex(items) {
    return {
      uris: new Set((items || []).map((item) => item?.uri).filter(Boolean)),
      keys: new Set((items || []).map(localKey).filter((key) => key !== "::")),
    };
  }

  function playlistURI(value) {
    if (typeof value === "string") return value.startsWith("spotify:playlist:") ? value : null;
    const uri = value?.uri
      || value?.playlist?.uri
      || value?.data?.uri
      || value?.playlistUri
      || null;
    if (uri?.startsWith("spotify:playlist:")) return uri;
    const id = value?.id || value?.playlist?.id || value?.data?.id;
    return id ? `spotify:playlist:${id}` : null;
  }

  async function log(level, message) {
    try {
      await fetch(`${QUEUE_SERVER}/log`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ level, message: String(message) }),
      });
    } catch (_) {}
  }

  async function markDone(jobId, playlistUri, addedUri) {
    await fetch(`${QUEUE_SERVER}/done`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jobId, playlistUri, addedUri }),
    });
  }

  function findPlaylistInRootlist(rootlist, name) {
    const key = normalize(name);
    const matches = [];

    function visit(items) {
      for (const item of items || []) {
        if (item?.type === "playlist" && normalize(item?.name) === key && item?.uri) {
          matches.push(item);
        }
        if (item?.items) visit(item.items);
      }
    }
    visit(rootlist?.items);

    return matches.find((playlist) => playlist?.isOwnedBySelf === true)
      || matches.find((playlist) => playlist?.canEditItems === true)
      || matches[0]
      || null;
  }

  async function ensurePlaylist(Spicetify, name) {
    const key = normalize(name);
    if (playlistCache.has(key)) return playlistCache.get(key);

    const RootlistAPI = Spicetify?.Platform?.RootlistAPI;
    if (!RootlistAPI) throw new Error("Spotify RootlistAPI is unavailable");

    const playlist = findPlaylistInRootlist(await RootlistAPI.getContents(), name);
    let uri = playlist?.uri || null;
    if (!uri) {
      if (playlistCreationPending.has(key)) {
        throw new Error(`Spotify is still creating the \"${name}\" playlist`);
      }
      const created = await RootlistAPI.createPlaylist(name);
      uri = playlistURI(created);
      if (uri) await log("info", `Created Spotify playlist ${uri}`);
      if (!uri) {
        playlistCreationPending.add(key);
        throw new Error(`Spotify is refreshing the \"${name}\" playlist`);
      }
    }
    if (!uri) throw new Error(`Spotify did not return a URI for playlist "${name}"`);
    playlistCache.set(key, uri);
    playlistCreationPending.delete(key);
    return uri;
  }

  async function playlistItems(PlaylistAPI, uri) {
    const response = await PlaylistAPI.getContents(uri);
    return response?.items || response?.contents?.items || response?.rows || [];
  }

  async function confirmPlaylistAddition(
    PlaylistAPI,
    playlistUri,
    local,
    requested,
    sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
  ) {
    const pending = pendingAdds.get(`${playlistUri}::${local.uri}`);
    if (!pending) {
      await PlaylistAPI.add(playlistUri, [local.uri], { after: { uid: "end" } });
      pendingAdds.set(`${playlistUri}::${local.uri}`, true);
    }

    for (let attempt = 0; attempt < ADD_CONFIRM_ATTEMPTS; attempt += 1) {
      const index = playlistIndex(await playlistItems(PlaylistAPI, playlistUri));
      // A normalized artist/title match is not sufficient here: users can
      // have multiple local recordings with the same tags (different files,
      // edits, or durations). Confirm the exact URI that this job queued.
      if (index.uris.has(local.uri)) {
        pendingAdds.delete(`${playlistUri}::${local.uri}`);
        return true;
      }
      if (attempt < ADD_CONFIRM_ATTEMPTS - 1) await sleep(ADD_CONFIRM_DELAY_MS);
    }
    return false;
  }

  async function processJob(Spicetify, PlaylistAPI, localTracks, job) {
    const requested = job?.tracks?.[0];
    if (!requested) {
      await markDone(job.id, null, null);
      return;
    }
    const local = findLocalTrack(localTracks, requested);
    if (!local?.uri) {
      const attempts = (missingAttempts.get(job.id) || 0) + 1;
      missingAttempts.set(job.id, attempts);
      if (attempts === 1 || attempts % 12 === 0) {
        await log("warn", `Waiting for Spotify to index ${requested.artist} — ${requested.name}`);
      }
      return;
    }

    const playlistUri = await ensurePlaylist(Spicetify, job.playlistName || "Needle");
    const index = playlistIndex(await playlistItems(PlaylistAPI, playlistUri));
    let added = false;
    if (!index.uris.has(local.uri)) {
      if (!await confirmPlaylistAddition(PlaylistAPI, playlistUri, local, requested)) {
        throw new Error(`Spotify did not confirm adding ${requested.artist} — ${requested.name} yet`);
      }
      added = true;
    }
    await markDone(job.id, playlistUri, local.uri);
    missingAttempts.delete(job.id);
    const message = added
      ? `Added ${requested.artist} — ${requested.name} to ${job.playlistName || "Needle"}`
      : `${requested.artist} — ${requested.name} is already in ${job.playlistName || "Needle"}`;
    Spicetify.showNotification(message);
    await log("info", message);
  }

  async function start(Spicetify) {
    await log("info", "Needle playlist companion script loaded");
    let apiWaits = 0;
    while (
      !Spicetify?.Platform?.PlaylistAPI
      || !Spicetify?.Platform?.LocalFilesAPI
      || !Spicetify?.Platform?.RootlistAPI
    ) {
      await new Promise((resolve) => setTimeout(resolve, 500));
      apiWaits += 1;
      if (apiWaits % 20 === 0) {
        await log(
          "warn",
          `Waiting for Spotify APIs: PlaylistAPI=${Boolean(Spicetify?.Platform?.PlaylistAPI)} ` +
          `LocalFilesAPI=${Boolean(Spicetify?.Platform?.LocalFilesAPI)} ` +
          `RootlistAPI=${Boolean(Spicetify?.Platform?.RootlistAPI)}`,
        );
      }
    }
    const PlaylistAPI = Spicetify.Platform.PlaylistAPI;
    const LocalFilesAPI = Spicetify.Platform.LocalFilesAPI;
    let polling = false;

    const poll = async () => {
      if (polling) return;
      polling = true;
      try {
        let queue;
        try {
          const response = await fetch(`${QUEUE_SERVER}/queue`);
          if (!response.ok) return;
          queue = await response.json();
        } catch (_) {
          return;
        }
        if (!queue?.length) return;

        const localResponse = await LocalFilesAPI.getTracks();
        const localTracks = localResponse?.items || localResponse || [];
        for (const job of queue) {
          if (activeJobs.has(job.id)) continue;
          activeJobs.add(job.id);
          try {
            await processJob(Spicetify, PlaylistAPI, localTracks, job);
          } catch (error) {
            const message = error?.message || String(error);
            const waitingForSpotify = message.startsWith("Spotify is refreshing")
              || message.startsWith("Spotify is still creating")
              || message.startsWith("Spotify did not confirm");
            await log(waitingForSpotify ? "info" : "error", `${job.id}: ${message}`);
            if (!waitingForSpotify) {
              Spicetify.showNotification(`Needle playlist sync failed: ${message}`, true);
            }
          } finally {
            activeJobs.delete(job.id);
          }
        }
      } finally {
        polling = false;
      }
    };

    await log("info", "Needle playlist companion initialized");
    await poll();
    setInterval(poll, POLL_INTERVAL_MS);
  }

  return {
    ensurePlaylist,
    confirmPlaylistAddition,
    findLocalTrack,
    findPlaylistInRootlist,
    normalize,
    playlistIndex,
    playlistURI,
    start,
    trackKey,
  };
});
