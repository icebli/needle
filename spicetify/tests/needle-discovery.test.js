const test = require("node:test");
const assert = require("node:assert/strict");
const companion = require("../needle-discovery.js");

test("maps top artists to the bounded desktop response shape", async () => {
  let requestedURL;
  const Spicetify = {
    CosmosAsync: {
      get: async (url) => {
        requestedURL = url;
        return { items: [{ id: "artist-1", name: "Artist", uri: "spotify:artist:artist-1", images: [{ url: "https://img.test/a.jpg" }] }] };
      },
    },
  };
  const result = await companion.spotifyRequest(Spicetify, { operation: "top-artists" });
  assert.equal(requestedURL, "https://api.spotify.com/v1/me/top/artists?time_range=medium_term&limit=50&offset=0");
  assert.deepEqual(result, { ok: true, artists: [{ id: "artist-1", name: "Artist", uri: "spotify:artist:artist-1", imageUrl: "https://img.test/a.jpg" }] });
});

test("uses Spotify's loaded GraphQL definitions for top artists", async () => {
  let variables;
  const result = await companion.spotifyRequest({
    GraphQL: {
      Definitions: { userTopContent: "top" },
      Request: async (_definition, requestVariables) => {
        variables = requestVariables;
        return { data: { me: { profile: { topArtists: { items: [{ data: { uri: "spotify:artist:a", profile: { name: "Artist" }, visuals: { avatarImage: { sources: [{ url: "https://img.test/a.jpg" }] } } } }] } } } } };
      },
    },
  }, { operation: "top-artists" });
  assert.equal(result.artists[0].id, "a");
  assert.equal(variables.topArtistsInput.timeRange, "MID_TERM");
});

test("unwraps CosmosAsync response wrappers and preserves short status diagnostics", async () => {
  const result = await companion.spotifyRequest({ CosmosAsync: { get: async () => ({ status: 200, body: { items: [{ id: "a", name: "Artist", uri: "spotify:artist:a" }] } }) } }, { operation: "top-artists" });
  assert.equal(result.artists[0].id, "a");
  assert.throws(() => companion.unwrapCosmosResponse({ status: 403, body: { error: { message: "Forbidden" } } }, "Spotify top artists"), /Spotify top artists failed \(403\): Forbidden/);
  assert.throws(() => companion.unwrapCosmosResponse({ code: "API_ERROR", message: "Top artists unavailable", stack: "private" }, "Spotify top artists"), /Spotify top artists failed \(API_ERROR\): Top artists unavailable/);
});

test("searches the Spotify catalog with an encoded artist and title", async () => {
  let requestedURL;
  const result = await companion.spotifyRequest({ CosmosAsync: { get: async (url) => {
    requestedURL = url;
    return { tracks: { items: [{ id: "track-1", name: "Song", uri: "spotify:track:track-1", artists: [{ id: "artist-1", name: "Artist" }], duration_ms: 1234 }] } };
  } } }, { operation: "catalog", artist: "Artist & Co", title: "Song / Remix" });
  assert.equal(requestedURL, "https://api.spotify.com/v1/search?type=track&limit=10&q=Artist%20%26%20Co%20Song%20%2F%20Remix");
  assert.deepEqual(result.tracks[0], { id: "track-1", name: "Song", uri: "spotify:track:track-1", artists: [{ id: "artist-1", name: "Artist" }], durationMs: 1234 });
});

test("uses Spotify's loaded GraphQL definition for catalog search", async () => {
  let variables;
  const result = await companion.spotifyRequest({
    GraphQL: {
      Definitions: { searchTracks: "search" },
      Request: async (_definition, requestVariables) => {
        variables = requestVariables;
        return { data: { searchV2: { tracksV2: { items: [{ item: { data: { uri: "spotify:track:t", name: "Song", artists: { items: [{ uri: "spotify:artist:a", profile: { name: "Artist" } }] }, duration: { totalMilliseconds: 1234 } } } }] } } } };
      },
    },
  }, { operation: "catalog", artist: "Artist", title: "Song" });
  assert.equal(result.tracks[0].id, "t");
  assert.equal(variables.searchTerm, "Artist Song");
});

test("returns an explicit error when CosmosAsync is unavailable", async () => {
  const result = await companion.spotifyRequest({}, { operation: "top-artists" }).catch((error) => ({ ok: false, error: error.message }));
  assert.deepEqual(result, { ok: false, error: "Spotify discovery API is unavailable" });
});

test("rejects malformed Spotify payloads instead of treating them as no matches", async () => {
  await assert.rejects(
    companion.spotifyRequest({ CosmosAsync: { get: async () => ({ tracks: {} }) } }, { operation: "catalog", artist: "Artist", title: "Song" }),
    /no catalog track list/,
  );
  await assert.rejects(
    companion.spotifyRequest({ CosmosAsync: { get: async () => ({ items: [{}] }) } }, { operation: "top-artists" }),
    /incomplete artist id/,
  );
});

test("posts a failed request result instead of falsely returning an empty catalog", async () => {
  let posted;
  await companion.requestOnce({}, { nonce: "nonce-error", operation: "top-artists" }, async (_url, options) => {
    posted = JSON.parse(options.body);
    return { ok: true };
  });
  assert.equal(posted.nonce, "nonce-error");
  assert.equal(posted.result.ok, false);
  assert.match(posted.result.error, /unavailable/);
});

for (const transport of ["rest", "graphql"]) {
  test(`${transport} paginates up to 100 distinct artists`, async () => {
    const offsets = [];
    const page = (offset) => Array.from({ length: 50 }, (_, index) => ({ id: `a${offset + index}`, name: `Artist ${offset + index}`, uri: `spotify:artist:a${offset + index}` }));
    const api = transport === "rest" ? { CosmosAsync: { get: async (url) => {
      const offset = Number(new URL(url).searchParams.get("offset"));
      offsets.push(offset);
      return { items: page(offset) };
    } } } : { GraphQL: { Request: async (_, variables) => {
      offsets.push(variables.topArtistsInput.offset);
      assert.equal(variables.topArtistsInput.limit, 50);
      return { data: { me: { profile: { topArtists: { items: page(variables.topArtistsInput.offset) } } } } };
    } } };
    const result = await companion.spotifyRequest(api, { operation: "top-artists" });
    assert.equal(result.artists.length, 100);
    assert.equal(result.artists[99].id, "a99");
    assert.deepEqual(offsets, [0, 50]);
  });
}

test("stops repeated artist pages and deduplicates them", async () => {
  let calls = 0;
  const items = Array.from({ length: 50 }, (_, index) => ({ id: `a${index}`, name: `Artist ${index}`, uri: `spotify:artist:a${index}` }));
  const result = await companion.spotifyRequest({ CosmosAsync: { get: async () => { calls += 1; return { items }; } } }, { operation: "top-artists" });
  assert.equal(result.artists.length, 50);
  assert.equal(calls, 2);
});

test("paginated bridge requests share one overall deadline", async (t) => {
  const schedule = global.setTimeout;
  const deadlines = [];
  t.mock.method(global, "setTimeout", (callback, milliseconds, ...args) => {
    const timer = schedule(callback, milliseconds === 25000 ? 25 : milliseconds, ...args);
    if (milliseconds === 25000) deadlines.push(timer);
    return timer;
  });
  let pages = 0;
  let posted;
  try {
    await companion.requestOnce({ CosmosAsync: { get: async () => {
      pages += 1;
      if (pages === 2) return new Promise(() => {});
      return { items: Array.from({ length: 50 }, (_, index) => ({ id: `a${index}`, name: `Artist ${index}`, uri: `spotify:artist:a${index}` })) };
    } } }, { nonce: "paginated-deadline", operation: "top-artists" }, async (_, options) => {
      posted = JSON.parse(options.body);
      return { ok: true };
    });
    assert.equal(pages, 2);
    assert.equal(posted.result.ok, false);
    assert.match(posted.result.error, /timed out/);
    assert.equal(deadlines.length, 3);
  } finally { deadlines.forEach(clearTimeout); }
});
