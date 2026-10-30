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
  const missingReasons = new Map();
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
    const localDuration = Number(track?.duration?.milliseconds ?? track?.duration ?? track?.duration_ms ?? track?.durationMs);
    return Number.isFinite(localDuration) && Math.floor(localDuration / 1000) === expectedSeconds;
  }

  function trackKey(artist, title) {
    return `${normalize(artist)}::${normalize(title)}`;
  }

  function localKey(track) {
    return trackKey(artistFromLocal(track), track?.name);
  }

  function localTrackMatch(localTracks, requested) {
    const exactKey = trackKey(requested.artist, requested.name);
    const exactMatches = localTracks.filter((track) => localKey(track) === exactKey);
    const titleMatches = localTracks.filter((track) => normalize(track?.name) === normalize(requested.name));
    const candidates = (exactMatches.length > 0 ? exactMatches : titleMatches)
      .filter((track, index, tracks) => !track?.uri || tracks.findIndex((candidate) => candidate?.uri === track.uri) === index);
    if (!candidates.length) return { track: null, reason: "no matching Spotify local track" };

    if (requested.savedPath) {
      const pathMatches = candidates.filter((track) => pathFromLocal(track) === requested.savedPath);
      if (pathMatches.length === 1) return { track: pathMatches[0], reason: null };
      if (pathMatches.length > 1) {
        return { track: null, reason: `Spotify exposed ${pathMatches.length} local files at the queued path` };
      }
    }

    if (requested.durationMs != null) {
      const durationCandidates = candidates.filter((track) => durationMatches(track, requested.durationMs));
      if (durationCandidates.length === 1) {
        const candidate = durationCandidates[0];
        const candidateAlbum = albumFromLocal(candidate);
        if (!requested.album || !candidateAlbum || normalize(candidateAlbum) === normalize(requested.album)) {
          return { track: candidate, reason: null };
        }
        return { track: null, reason: "Spotify local album metadata does not match the queued album" };
      }
      if (durationCandidates.length > 1 && requested.album) {
        const exactMetadataMatches = durationCandidates.filter((track) =>
          artistFromLocal(track) === requested.artist
          && track?.name === requested.name
          && albumFromLocal(track) === requested.album,
        );
        if (exactMetadataMatches.length === 1) return { track: exactMetadataMatches[0], reason: null };
        const albumMatches = durationCandidates.filter((track) => normalize(albumFromLocal(track)) === normalize(requested.album));
        if (albumMatches.length === 1) return { track: albumMatches[0], reason: null };
      }
      // A queued duration is part of the downloaded file identity. If Spotify
      // cannot expose that duration, do not fall back to a same-tag recording.
      return {
        track: null,
        reason: durationCandidates.length
          ? `Spotify exposed ${durationCandidates.length} matching local files with the queued duration`
          : "Spotify has not exposed a local file with the queued duration",
      };
    }

    if (candidates.length > 0 && requested.album) {
      const albumKey = normalize(requested.album);
      const albumMatches = candidates.filter((track) => normalize(albumFromLocal(track)) === albumKey);
      if (albumMatches.length === 1) return { track: albumMatches[0], reason: null };
      if (albumMatches.length > 1) {
        return { track: null, reason: `Spotify exposed ${albumMatches.length} matching local files for the queued album` };
      }
      // Older Spotify builds may omit local album metadata. Only fall back
      // when there is one candidate and no album value that contradicts it.
      if (candidates.length === 1 && !albumFromLocal(candidates[0])) return { track: candidates[0], reason: null };
      return { track: null, reason: "Spotify local album metadata does not match the queued album" };
    }
    return candidates.length === 1
      ? { track: candidates[0], reason: null }
      : { track: null, reason: `Spotify exposed ${candidates.length} matching local files` };
  }

  function findLocalTrack(localTracks, requested) {
    return localTrackMatch(localTracks, requested).track;
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

  async function markDone(jobId, playlistUri, addedUri, extra = {}) {
    const response = await fetch(`${QUEUE_SERVER}/done`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jobId, playlistUri, addedUri, ...extra }),
    });
    if (!response.ok) throw new Error(`Needle could not acknowledge Spotify delivery (${response.status})`);
  }

  async function reportProgress(jobId, detail) {
    const response = await fetch(`${QUEUE_SERVER}/progress`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jobId, detail }),
    });
    if (!response.ok) throw new Error(`Needle could not record delivery progress (${response.status})`);
  }

  async function readLocalTracks(LocalFilesAPI, logger = log) {
    try {
      const response = await LocalFilesAPI.getTracks();
      return response?.items || response || [];
    } catch (error) {
      await logger("error", `Spotify Local Files lookup failed: ${error?.message || String(error)}`);
      return null;
    }
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

  async function playlistItems(PlaylistAPI, uri, requireComplete = false) {
    const rows = [];
    const seen = new Set();
    let expectedTotal;
    for (let page = 0; page < 1000; page += 1) {
      const response = await PlaylistAPI.getContents(uri, { offset: rows.length, limit: 200 });
      const items = response?.items || response?.contents?.items || response?.rows || [];
      const total = response?.totalLength;
      if (!Number.isInteger(total) || total < 0) {
        if (!requireComplete && rows.length === 0 && items.length < 200) return items;
        throw new Error("Spotify did not confirm the complete playlist length");
      }
      if (expectedTotal === undefined) expectedTotal = total;
      if (expectedTotal !== total || (!items.length && rows.length < total)
        || items.some((row) => requireComplete && (!row.uid || seen.has(row.uid)))) {
        throw new Error("Spotify returned an incomplete or changing playlist; waiting before changing any rows");
      }
      for (const row of items) {
        if (requireComplete && seen.has(row.uid)) throw new Error("Spotify repeated a playlist row during pagination");
        if (row.uid) seen.add(row.uid);
        rows.push(row);
      }
      if (rows.length === expectedTotal) return rows;
      if (rows.length > expectedTotal) break;
    }
    throw new Error("Spotify returned an incomplete playlist; waiting before changing any rows");
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

  function currentMetadataMatch(localTracks, requested) {
    const matches = localTracks.filter((track) => track?.uri
      && artistFromLocal(track) === requested.artist
      && track.name === requested.name
      && albumFromLocal(track) === (requested.album || "")
      && requested.durationMs != null && durationMatches(track, requested.durationMs));
    const distinct = matches.filter((track, index) => matches.findIndex((other) => other.uri === track.uri) === index);
    return distinct.length === 1 ? distinct[0] : null;
  }

  const rowsOf = (items) => items.map(({ uri, uid }) => ({ uri, uid }));
  const sameRows = (left, right) => left.length === right.length
    && left.every((row, index) => row.uri === right[index]?.uri && row.uid === right[index]?.uid);

  async function currentJob(job) {
    const response = await fetch(`${QUEUE_SERVER}/queue?protocol=2`);
    if (!response.ok) throw new Error("Needle could not verify the current repair job");
    const jobs = await response.json();
    const current = jobs.find((item) => item.id === job.id && item.revision === job.revision);
    if (!current) throw new Error("Metadata changed again; waiting for the current repair job");
    return current;
  }

  async function checkpoint(job, mutation) {
    const response = await fetch(`${QUEUE_SERVER}/checkpoint`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jobId: job.id, revision: job.revision, mutation }),
    });
    if (!response.ok) throw new Error("Metadata changed again; this repair will resume from its saved state");
    job.reconcile.mutation = mutation;
  }

  async function reconcileJob(PlaylistAPI, localTracks, job, io = {}) {
    const progress = io.progress || reportProgress;
    const done = io.done || markDone;
    const persist = io.checkpoint || checkpoint;
    const refresh = io.currentJob || currentJob;
    const wait = async (detail) => { await progress(job.id, detail); return false; };
    const target = job.reconcile?.target;
    const requested = job.tracks?.[0];
    if (!target?.playlistUri?.startsWith("spotify:playlist:") || !target.addedUri?.startsWith("spotify:local:") || !requested) {
      return wait("Spotify's original playlist receipt is missing. No playlist was changed.");
    }
    let mutation = job.reconcile.mutation;
    const local = mutation ? { uri: mutation.newUri } : currentMetadataMatch(localTracks, requested);
    if (!local) return wait("Waiting for Spotify to index the file's current artist, title, album, and duration. The existing playlist entry is preserved.");
    let rows = rowsOf(await playlistItems(PlaylistAPI, target.playlistUri, true));
    const finish = async (row, detail) => {
      await done(job.id, target.playlistUri, row.uri, { revision: job.revision, addedUid: row.uid || null, detail });
      return true;
    };
    if (!mutation && local.uri === target.addedUri) {
      const matches = rows.filter((row) => row.uri === local.uri && (!target.addedUid || row.uid === target.addedUid));
      if (matches.length !== 1) return wait("The original Spotify row is missing or ambiguous. No playlist was changed.");
      await refresh(job);
      if (PlaylistAPI.resync) await PlaylistAPI.resync(target.playlistUri);
      return finish(matches[0], "Current tags use the same Spotify URI. The playlist entry is preserved; Spotify artwork refresh is unconfirmed.");
    }
    if (!mutation) {
      const oldRows = rows.filter((row) => row.uri === target.addedUri);
      const old = target.addedUid ? oldRows.find((row) => row.uid === target.addedUid) : oldRows.length === 1 ? oldRows[0] : null;
      const currentRows = rows.filter((row) => row.uri === local.uri);
      if (!old && oldRows.length === 0) {
        if (currentRows.length === 1) { await refresh(job); return finish(currentRows[0], "The playlist already contains the current recording."); }
        return wait("The original playlist entry was removed. Needle will not add it again.");
      }
      if (!old?.uid || rows.some((row) => !row.uid)) return wait("Spotify's original playlist row is ambiguous or has no row ID. No playlist was changed.");
      if (currentRows.length) return wait("The playlist contains both old and current recordings. Needle needs an unambiguous row before replacing anything.");
      mutation = { phase: "adding", oldUid: old.uid, newUri: local.uri, newUid: null, originalRows: rows };
      await persist(job, mutation);
      // A persisted adding phase makes a lost response distinguishable from a
      // fresh request. Retries inspect the playlist and never repeat this add.
      try { await PlaylistAPI.add(target.playlistUri, [local.uri], { before: { uid: old.uid } }); }
      catch (_) { return wait("Spotify did not confirm the replacement insert. Needle will inspect this same repair. Manual review is needed if no replacement appears; it will not add another copy."); }
      rows = rowsOf(await playlistItems(PlaylistAPI, target.playlistUri, true));
    }
    const original = mutation.originalRows;
    const oldIndex = original.findIndex((row) => row.uid === mutation.oldUid && row.uri === target.addedUri);
    if (oldIndex < 0) return wait("The saved replacement plan is invalid. No playlist row was removed.");
    const originalUIDs = new Set(original.map((row) => row.uid));
    const newRows = rows.filter((row) => row.uri === mutation.newUri && row.uid && !originalUIDs.has(row.uid)
      && (!mutation.newUid || row.uid === mutation.newUid));
    if (newRows.length !== 1) return wait("Spotify has not confirmed the exact replacement row. If it never appears, review the playlist manually; Needle will not insert another copy or remove the original.");
    const replacement = newRows[0];
    const expectedFinal = original.map((row, index) => index === oldIndex ? replacement : row);
    if (sameRows(rows, expectedFinal)) {
      await refresh(job);
      if (!mutation.newUid) { mutation = { ...mutation, phase: "removing", newUid: replacement.uid }; await persist(job, mutation); }
      return finish(replacement, "Spotify now uses the file's current tags. Spotify artwork refresh is unconfirmed.");
    }
    const expectedInserted = [...original.slice(0, oldIndex), replacement, ...original.slice(oldIndex)];
    if (!sameRows(rows, expectedInserted)) return wait("The playlist changed during repair. Needle preserved every row and is waiting for review.");
    mutation = { ...mutation, phase: "inserted", newUid: replacement.uid };
    await persist(job, mutation);
    const current = await refresh(job);
    if (current.reconcile?.target?.addedUri !== target.addedUri
      || current.reconcile?.mutation?.newUid !== replacement.uid) throw new Error("The repair target changed before removal");
    rows = rowsOf(await playlistItems(PlaylistAPI, target.playlistUri, true));
    if (!sameRows(rows, expectedInserted)) return wait("The playlist changed before removal. The original entry is preserved.");
    mutation = { ...mutation, phase: "removing" };
    await persist(job, mutation);
    // UID is mandatory: Spotify removes every occurrence when it falls back
    // to URI removal. The exact replacement row was confirmed above.
    try { await PlaylistAPI.remove(target.playlistUri, [{ uri: target.addedUri, uid: mutation.oldUid }]); }
    catch (_) { return wait("Spotify did not confirm removal. Needle will check this saved replacement again."); }
    rows = rowsOf(await playlistItems(PlaylistAPI, target.playlistUri, true));
    if (!sameRows(rows, expectedFinal)) return wait("Waiting for Spotify to confirm the replacement and unchanged playlist order.");
    return finish(replacement, "Spotify now uses the file's current tags. Spotify artwork refresh is unconfirmed.");
  }

  async function processJob(Spicetify, PlaylistAPI, localTracks, job) {
    if (job.reconcile) { await reconcileJob(PlaylistAPI, localTracks, job); return; }
    const requested = job?.tracks?.[0];
    if (!requested) {
      await markDone(job.id, null, null);
      return;
    }
    const match = localTrackMatch(localTracks, requested);
    const local = match.track;
    if (!local?.uri) {
      const attempts = (missingAttempts.get(job.id) || 0) + 1;
      const previousReason = missingReasons.get(job.id);
      missingAttempts.set(job.id, attempts);
      missingReasons.set(job.id, match.reason);
      if (attempts === 1 || attempts % 12 === 0 || previousReason !== match.reason) {
        const detail = `Open Spotify Local Files and choose the recording: ${match.reason}`;
        await log("warn", `Waiting for Spotify to identify ${requested.artist} — ${requested.name}: ${match.reason}`);
        try {
          await reportProgress(job.id, detail);
        } catch (error) {
          await log("error", `${job.id}: ${error?.message || String(error)}`);
        }
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
    const confirmedRows = await playlistItems(PlaylistAPI, playlistUri);
    const matchingRows = confirmedRows.filter((row) => row.uri === local.uri);
    await markDone(job.id, playlistUri, local.uri, { addedUid: matchingRows.length === 1 ? matchingRows[0].uid || null : null });
    missingAttempts.delete(job.id);
    missingReasons.delete(job.id);
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
          const response = await fetch(`${QUEUE_SERVER}/queue?protocol=2`);
          if (!response.ok) return;
          queue = await response.json();
        } catch (_) {
          return;
        }
        if (!queue?.length) return;

        const localTracks = await readLocalTracks(LocalFilesAPI);
        if (!localTracks) return;
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
    LocalFilesAPI.getEvents?.().addListener?.("update", poll);
    setInterval(poll, POLL_INTERVAL_MS);
  }

  return {
    currentMetadataMatch,
    reconcileJob,
    playlistItems,
    ensurePlaylist,
    confirmPlaylistAddition,
    findLocalTrack,
    localTrackMatch,
    findPlaylistInRootlist,
    normalize,
    playlistIndex,
    playlistURI,
    reportProgress,
    readLocalTracks,
    start,
    trackKey,
  };
});
