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
