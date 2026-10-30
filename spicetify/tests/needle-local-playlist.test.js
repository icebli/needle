const test = require("node:test");
const assert = require("node:assert/strict");
const companion = require("../needle-local-playlist.js");

const local = (artist, name, uri) => ({
  name,
  uri,
  album: { artist: { name: artist } },
});

const localWithDuration = (artist, name, uri, duration) => ({
  ...local(artist, name, uri),
  duration,
});

test("matches cleaned Needle tags to a Spotify local file", () => {
  const tracks = [local("Kendrick Lamar", "The Heart Pt. 2", "spotify:local:one")];
  const match = companion.findLocalTrack(tracks, {
    artist: "KENDRICK LAMAR",
    name: "The Heart Pt. 2",
  });
  assert.equal(match.uri, "spotify:local:one");
});

test("uses the queued album to distinguish duplicate local recordings", () => {
  const tracks = [
    { ...local("Kanye West", "Living So Italian (feat. JAY-Z)", "spotify:local:manual"), album: { name: "REAL VERSION", artist: { name: "Kanye West" } } },
    { ...local("Kanye West", "Living So Italian (feat. JAY-Z)", "spotify:local:needle"), album: { name: "Unknown Album", artist: { name: "Kanye West" } } },
  ];
  const match = companion.findLocalTrack(tracks, {
    artist: "Kanye West",
    name: "Living So Italian (feat. JAY-Z)",
    album: "Unknown Album",
  });
  assert.equal(match.uri, "spotify:local:needle");
});

test("does not select a preexisting recording when its album contradicts the queued album", () => {
  const match = companion.findLocalTrack([
    { ...local("Kanye West", "Living So Italian (feat. JAY-Z)", "spotify:local:manual"), album: { name: "REAL VERSION", artist: { name: "Kanye West" } } },
  ], {
    artist: "Kanye West",
    name: "Living So Italian (feat. JAY-Z)",
    album: "Unknown Album",
  });
  assert.equal(match, null);
});

test("does not guess when a title-only match is ambiguous", () => {
  const tracks = [
    local("Artist One", "Intro", "spotify:local:one"),
    local("Artist Two", "Intro", "spotify:local:two"),
  ];
  assert.equal(companion.findLocalTrack(tracks, { artist: "Missing", name: "Intro" }), null);
});

test("uses the queued duration to select the downloaded recording", () => {
  const tracks = [
    localWithDuration("Kanye West", "Living So Italian (feat. JAY-Z)", "spotify:local:older:189", 189823),
    localWithDuration("Kanye West", "Living So Italian (feat. JAY-Z)", "spotify:local:needle:190", 190055),
  ];
  const match = companion.findLocalTrack(tracks, {
    artist: "Kanye West",
    name: "Living So Italian (feat. JAY-Z)",
    durationMs: 190055,
  });
  assert.equal(match.uri, "spotify:local:needle:190");
});

test("uses the queued saved path when Spotify exposes it", () => {
  const tracks = [
    { ...local("Artist", "Song", "spotify:local:one"), path: "/Music/old.mp3" },
    { ...local("Artist", "Song", "spotify:local:two"), path: "/Music/new.mp3" },
  ];
  const match = companion.findLocalTrack(tracks, {
    artist: "Artist",
    name: "Song",
    savedPath: "/Music/new.mp3",
  });
  assert.equal(match.uri, "spotify:local:two");
});

test("keeps the companion poll alive when Spotify local-file lookup fails", async () => {
  const messages = [];
  const tracks = await companion.readLocalTracks({
    getTracks: async () => { throw new Error("LocalFilesAPI unavailable"); },
  }, async (level, message) => messages.push({ level, message }));
  assert.equal(tracks, null);
  assert.deepEqual(messages, [{
    level: "error",
    message: "Spotify Local Files lookup failed: LocalFilesAPI unavailable",
  }]);
});

test("refuses duplicate local recordings when the queued duration is unavailable", () => {
  const tracks = [
    local("Artist", "Song", "spotify:local:one:189"),
    local("Artist", "Song", "spotify:local:two:190"),
  ];
  assert.equal(companion.findLocalTrack(tracks, {
    artist: "Artist",
    name: "Song",
  }), null);
});

test("explains ambiguous duplicate local recordings", () => {
  const tracks = [
    { ...localWithDuration("A$AP Mob", "Bath Salt (feat. Flatbush Zombies)", "spotify:local:one:252", 252074), album: { name: "ASAP Rocky & ASAP Ant", artist: { name: "A$AP Mob" } } },
    { ...localWithDuration("A$AP Mob", "Bath Salt (feat. Flatbush Zombies)", "spotify:local:two:252", 252074), album: { name: "ASAP Rocky & ASAP Ant", artist: { name: "A$AP Mob" } } },
  ];
  const match = companion.localTrackMatch(tracks, {
    artist: "A$AP Mob",
    name: "Bath Salt (feat. Flatbush Zombies)",
    album: "ASAP Rocky & ASAP Ant",
    durationMs: 252074,
  });
  assert.equal(match.track, null);
  assert.equal(match.reason, "Spotify exposed 2 matching local files with the queued duration");
});

test("uses the queued album to resolve duplicate duration matches", () => {
  const tracks = [
    { ...localWithDuration("A$AP Mob", "Bath Salt (feat. Flatbush Zombies)", "spotify:local:other:252", 252074), album: { name: "Other Album", artist: { name: "A$AP Mob" } } },
    { ...localWithDuration("A$AP Mob", "Bath Salt (feat. Flatbush Zombies)", "spotify:local:needle:252", 252074), album: { name: "ASAP Rocky & ASAP Ant", artist: { name: "A$AP Mob" } } },
  ];
  const match = companion.localTrackMatch(tracks, {
    artist: "A$AP Mob",
    name: "Bath Salt (feat. Flatbush Zombies)",
    album: "ASAP Rocky & ASAP Ant",
    durationMs: 252074,
  });
  assert.equal(match.track.uri, "spotify:local:needle:252");
  assert.equal(match.reason, null);
});

test("deduplicates repeated Spotify entries with the same URI", () => {
  const duplicate = localWithDuration("A$AP Mob", "Bath Salt (feat. Flatbush Zombies)", "spotify:local:same:252", 252074);
  const match = companion.localTrackMatch([duplicate, { ...duplicate }], {
    artist: "A$AP Mob",
    name: "Bath Salt (feat. Flatbush Zombies)",
    durationMs: 252074,
  });
  assert.equal(match.track.uri, "spotify:local:same:252");
  assert.equal(match.reason, null);
});

test("does not fall back to album tags when queued duration cannot be matched", () => {
  const tracks = [
    { ...local("Artist", "Song", "spotify:local:one:189"), album: { name: "Album", artist: { name: "Artist" } } },
  ];
  assert.equal(companion.findLocalTrack(tracks, {
    artist: "Artist",
    name: "Song",
    album: "Album",
    durationMs: 190000,
  }), null);
});

test("playlist index deduplicates both URI and cleaned tags", () => {
  const index = companion.playlistIndex([
    local("Beyoncé", "ALIEN SUPERSTAR", "spotify:local:one"),
  ]);
  assert.equal(index.uris.has("spotify:local:one"), true);
  assert.equal(index.keys.has(companion.trackKey("Beyonce", "Alien Superstar")), true);
});

test("finds an owned playlist nested in the Spotify rootlist", () => {
  const playlist = companion.findPlaylistInRootlist({
    items: [{
      type: "folder",
      name: "Local music",
      items: [{
        type: "playlist",
        name: "Needle",
        uri: "spotify:playlist:needle",
        isOwnedBySelf: true,
      }],
    }],
  }, "needle");

  assert.equal(playlist.uri, "spotify:playlist:needle");
});

test("reuses a rootlist playlist without calling the rate-limited Web API", async () => {
  const Spicetify = {
    Platform: {
      RootlistAPI: {
        getContents: async () => ({
          items: [{
            type: "playlist",
            name: "Needle",
            uri: "spotify:playlist:existing",
            isOwnedBySelf: true,
          }],
        }),
        createPlaylist: async () => assert.fail("should reuse the existing playlist"),
      },
    },
  };

  assert.equal(
    await companion.ensurePlaylist(Spicetify, "Needle"),
    "spotify:playlist:existing",
  );
});

test("does not create duplicate playlists while Spotify refreshes the rootlist", async () => {
  const name = "Needle delayed rootlist";
  let visible = false;
  let creates = 0;
  const Spicetify = {
    Platform: {
      RootlistAPI: {
        getContents: async () => ({
          items: visible ? [{ type: "playlist", name, uri: "spotify:playlist:delayed" }] : [],
        }),
        createPlaylist: async () => {
          creates += 1;
          return undefined;
        },
      },
    },
  };

  await assert.rejects(
    companion.ensurePlaylist(Spicetify, name),
    /refreshing/,
  );
  await assert.rejects(
    companion.ensurePlaylist(Spicetify, name),
    /still creating/,
  );
  assert.equal(creates, 1);

  visible = true;
  assert.equal(
    await companion.ensurePlaylist(Spicetify, name),
    "spotify:playlist:delayed",
  );
  assert.equal(creates, 1);
});

test("extracts playlist URIs from common RootlistAPI response shapes", () => {
  assert.equal(companion.playlistURI("spotify:playlist:direct"), "spotify:playlist:direct");
  assert.equal(companion.playlistURI({ uri: "spotify:playlist:object" }), "spotify:playlist:object");
  assert.equal(companion.playlistURI({ playlist: { uri: "spotify:playlist:nested" } }), "spotify:playlist:nested");
  assert.equal(companion.playlistURI({ id: "from-id" }), "spotify:playlist:from-id");
  assert.equal(companion.playlistURI({ value: "not-a-uri" }), null);
});

test("waits for Spotify to expose a newly added local track before acknowledging it", async () => {
  let reads = 0;
  let adds = 0;
  const localTrack = local("Kanye West", "Living So Italian (feat. JAY-Z)", "spotify:local:living");
  const preexistingSameTags = local("Kanye West", "Living So Italian (feat. JAY-Z)", "spotify:local:older");
  const PlaylistAPI = {
    getContents: async () => {
      reads += 1;
      return reads >= 3 ? { items: [preexistingSameTags, localTrack] } : { items: [preexistingSameTags] };
    },
    add: async () => { adds += 1; },
  };

  assert.equal(
    await companion.confirmPlaylistAddition(
      PlaylistAPI,
      "spotify:playlist:needle",
      localTrack,
      { artist: "Kanye West", name: "Living So Italian (feat. JAY-Z)" },
      async () => {},
    ),
    true,
  );
  assert.equal(adds, 1);
  assert.equal(reads, 3);
});

const row = (uri, uid) => ({ uri, uid });
function repairFixture(options = {}) {
  const old = row("spotify:local:Artist:Album:Old:190", "old-row");
  const current = { ...local("Artist", "Current", "spotify:local:Artist:Album:Current:190"), album: { name: "Album", artist: { name: "Artist" } }, duration: { milliseconds: 190000 } };
  let rows = options.rows || [row("spotify:track:first", "first"), old, row("spotify:track:last", "last")];
  const job = { id: "repair", revision: 2, tracks: [{ artist: "Artist", name: "Current", album: "Album", durationMs: 190000 }], reconcile: {
    target: { playlistUri: "spotify:playlist:exact-receipt", addedUri: old.uri, addedUid: options.preciseUID ? old.uid : null }, mutation: null,
  } };
  const messages = [], acknowledgements = [], calls = [];
  const io = {
    progress: async (_id, detail) => messages.push(detail),
    done: async (...args) => acknowledgements.push(args),
    checkpoint: async (_job, mutation) => { job.reconcile.mutation = structuredClone(mutation); },
    currentJob: async () => structuredClone(job),
  };
  const api = {
    getContents: async (uri, range) => { assert.equal(uri, job.reconcile.target.playlistUri); assert.equal(range.limit, 200); return { items: rows, totalLength: rows.length }; },
    add: async (_uri, uris, position) => { calls.push("add"); const index = rows.findIndex((item) => item.uid === position.before.uid); rows.splice(index, 0, row(uris[0], "replacement")); },
    remove: async (_uri, items) => { calls.push("remove"); assert.ok(items[0].uid); rows = rows.filter((item) => item.uid !== items[0].uid); },
    resync: async () => calls.push("resync"),
  };
  return { old, current, job, io, api, messages, acknowledgements, calls, rows: () => rows, run: () => companion.reconcileJob(api, [current], job, io) };
}

test("replacement waits for exact current tags and rejects stale normalized metadata", async () => {
  const f = repairFixture();
  const stale = { ...f.current, name: "CURRENT" };
  assert.equal(await companion.reconcileJob(f.api, [stale], f.job, f.io), false);
  assert.deepEqual(f.calls, []);
  assert.match(f.messages[0], /index.*current/);
  assert.equal(await f.run(), true);
  assert.deepEqual(f.calls, ["add", "remove"]);
  assert.deepEqual(f.rows().map((item) => item.uid), ["first", "replacement", "last"]);
});

test("case changes choose exact metadata and duplicate exact local recordings wait", () => {
  const f = repairFixture();
  const stale = { ...f.current, name: "CURRENT", uri: "spotify:local:stale:190" };
  assert.equal(companion.currentMetadataMatch([stale, f.current], f.job.tracks[0]), f.current);
  assert.equal(companion.currentMetadataMatch([f.current, { ...f.current, uri: "spotify:local:other:190" }], f.job.tracks[0]), null);
});

test("duplicate old URI without exact receipt UID never changes the playlist", async () => {
  const f = repairFixture();
  const duplicate = row(f.old.uri, "other-occurrence");
  f.rows().push(duplicate);
  assert.equal(await f.run(), false);
  assert.deepEqual(f.calls, []);
  assert.match(f.messages[0], /ambiguous/);
});

test("known old UID replaces only that occurrence and preserves duplicates", async () => {
  const f = repairFixture({ preciseUID: true });
  f.rows().push(row(f.old.uri, "other-occurrence"));
  assert.equal(await f.run(), true);
  assert.deepEqual(f.rows().map((item) => item.uid), ["first", "replacement", "last", "other-occurrence"]);
});

test("lost add response resumes after restart without adding a duplicate", async () => {
  const f = repairFixture();
  const add = f.api.add;
  f.api.add = async (...args) => { await add(...args); throw new Error("response lost"); };
  assert.equal(await f.run(), false);
  assert.deepEqual(f.calls, ["add"]);
  f.job.reconcile = JSON.parse(JSON.stringify(f.job.reconcile));
  assert.equal(await f.run(), true);
  assert.deepEqual(f.calls, ["add", "remove"]);
  assert.equal(f.rows().length, 3);
});

test("uncertain insert without visible replacement never retries add or removes old", async () => {
  const f = repairFixture();
  f.api.add = async () => { f.calls.push("add"); throw new Error("disconnected"); };
  assert.equal(await f.run(), false);
  assert.equal(await f.run(), false);
  assert.deepEqual(f.calls, ["add"]);
  assert.ok(f.rows().some((item) => item.uid === f.old.uid));
});

test("lost remove response confirms persisted final state after restart", async () => {
  const f = repairFixture();
  const remove = f.api.remove;
  f.api.remove = async (...args) => { await remove(...args); throw new Error("response lost"); };
  assert.equal(await f.run(), false);
  assert.equal(await f.run(), true);
  assert.deepEqual(f.calls, ["add", "remove"]);
  assert.equal(f.acknowledgements.length, 1);
});

test("failed removal can retry only the original exact UID", async () => {
  const f = repairFixture();
  const remove = f.api.remove;
  let fail = true;
  f.api.remove = async (...args) => { if (fail) { fail = false; throw new Error("unavailable"); } await remove(...args); };
  assert.equal(await f.run(), false);
  assert.equal(f.rows().length, 4);
  assert.equal(await f.run(), true);
  assert.deepEqual(f.calls, ["add", "remove"]);
});

test("missing original and current entries never resurrect a user-removed track", async () => {
  const f = repairFixture({ rows: [] });
  assert.equal(await f.run(), false);
  assert.deepEqual(f.calls, []);
  assert.match(f.messages[0], /will not add it again/);
});

test("manual replacement already in playlist acknowledges without mutation", async () => {
  const f = repairFixture();
  f.rows().splice(1, 1, row(f.current.uri, "manual-current"));
  assert.equal(await f.run(), true);
  assert.deepEqual(f.calls, []);
  assert.equal(f.acknowledgements[0][3].addedUid, "manual-current");
});

test("both old and preexisting new rows remain untouched without an owned insert plan", async () => {
  const f = repairFixture();
  f.rows().push(row(f.current.uri, "preexisting"));
  assert.equal(await f.run(), false);
  assert.deepEqual(f.calls, []);
});

test("external playlist edits prevent deletion after the replacement was inserted", async () => {
  const f = repairFixture();
  const add = f.api.add;
  f.api.add = async (...args) => { await add(...args); f.rows().push(row("spotify:track:external", "external")); };
  assert.equal(await f.run(), false);
  assert.deepEqual(f.calls, ["add"]);
  assert.ok(f.rows().some((item) => item.uid === f.old.uid));
});

test("generation change immediately before removal prevents deletion", async () => {
  const f = repairFixture();
  f.io.currentJob = async () => { throw new Error("new revision"); };
  await assert.rejects(f.run(), /new revision/);
  assert.deepEqual(f.calls, ["add"]);
  assert.ok(f.rows().some((item) => item.uid === f.old.uid));
});

test("artwork-only unchanged URI preserves row and reports refresh unconfirmed", async () => {
  const f = repairFixture();
  f.current.uri = f.old.uri;
  assert.equal(await f.run(), true);
  assert.deepEqual(f.calls, ["resync"]);
  assert.match(f.acknowledgements[0][3].detail, /artwork refresh is unconfirmed/);
});

test("incomplete playlist read and missing destination never mutate anything", async () => {
  const f = repairFixture();
  f.api.getContents = async () => ({ items: f.rows(), totalLength: 100 });
  await assert.rejects(f.run(), /incomplete/);
  delete f.job.reconcile.target;
  assert.equal(await f.run(), false);
  assert.deepEqual(f.calls, []);
});

test("playlist pagination advances requested offsets and retains every duplicate occurrence", async () => {
  const rows = Array.from({ length: 405 }, (_, index) => row(`spotify:local:same`, `row-${index}`));
  const offsets = [];
  const api = { getContents: async (_uri, { offset, limit }) => {
    offsets.push(offset);
    return { items: rows.slice(offset, offset + limit), offset: 0, totalLength: rows.length };
  } };
  assert.deepEqual(await companion.playlistItems(api, "spotify:playlist:paged", true), rows);
  assert.deepEqual(offsets, [0, 200, 400]);
});

test("duplicate pages and changing playlist totals are rejected before mutation", async () => {
  const rows = Array.from({ length: 200 }, (_, index) => row("spotify:track:one", `row-${index}`));
  await assert.rejects(companion.playlistItems({ getContents: async () => ({ items: rows, totalLength: 400 }) }, "spotify:playlist:repeat", true), /incomplete|changing/);
  let reads = 0;
  await assert.rejects(companion.playlistItems({ getContents: async () => ({ items: rows, totalLength: ++reads === 1 ? 400 : 401 }) }, "spotify:playlist:changing", true), /changing/);
});
