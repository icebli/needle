(function installNeedleDiscovery(root, factory) {
  const companion = factory();
  if (typeof module === "object" && module.exports) module.exports = companion;
  if (root.Spicetify) void companion.start(root.Spicetify);
})(typeof globalThis !== "undefined" ? globalThis : this, function createNeedleDiscovery() {
  "use strict";

  const DISCOVERY_SERVER = "http://127.0.0.1:29879";
  const SPOTIFY_API = "https://api.spotify.com/v1";
  const POLL_INTERVAL_MS = 750;
  const MAX_ARTISTS = 20;
  const MAX_TRACKS = 10;
  const API_DEADLINE_MS = 25000;
  const GRAPHQL_DEFINITIONS = {
    userTopContent: { name: "userTopContent", operation: "query", sha256Hash: "49ee15704de4a7fdeac65a02db20604aa11e46f02e809c55d9a89f6db9754356", value: null },
    searchTracks: { name: "searchTracks", operation: "query", sha256Hash: "b02683192a98dde7966b5e6655a79eeb62713eab703eda9902c932818dd52751", value: null },
  };
  const activeRequests = new Set();

  function responseError(error) {
    return { ok: false, error: String(error?.message || error || "Spotify discovery failed").slice(0, 200) };
  }

  function schemaKeys(value) {
    return value && typeof value === "object" ? Object.keys(value).slice(0, 8).sort().join(",") : typeof value;
  }

  function unwrapCosmosResponse(response, label) {
    const body = response?.body ?? response?.data ?? response;
    const error = response?.error || body?.error;
    const status = response?.status ?? error?.status;
    const code = response?.code ?? error?.code;
    // CosmosAsync can return an error envelope directly instead of rejecting.
    // Treat that envelope as a failure even when it has no numeric HTTP status.
    const errorEnvelope = Boolean(error || response?.message || (code && !response?.items && !response?.tracks));
    if (errorEnvelope || (Number.isInteger(status) && status >= 400)) {
      const message = typeof error === "string"
        ? error
        : error?.message || error?.error || response?.message || (Number(status) === 429 ? "rate limited by Spotify" : "request failed");
      const diagnostic = status || code;
      throw new Error(`${label} failed${diagnostic ? ` (${diagnostic})` : ""}: ${String(message).slice(0, 160)}`);
    }
    return body;
  }

  function artistResult(item) {
    const images = item?.images?.items || item?.images || [];
    return {
      id: String(item?.id || ""),
      name: String(item?.name || ""),
      uri: String(item?.uri || ""),
      ...(images?.[0]?.url ? { imageUrl: String(images[0].url) } : {}),
    };
  }

  function trackResult(item) {
    const artists = item?.artists?.items || item?.artists || [];
    const duration = item?.duration_ms ?? item?.durationMs ?? item?.duration?.milliseconds;
    return {
      id: String(item?.id || ""),
      name: String(item?.name || ""),
      uri: String(item?.uri || ""),
      artists: artists.slice(0, 10).map((artist) => ({
        id: String(artist?.id || ""),
        name: String(artist?.name || ""),
      })),
      ...(Number.isFinite(duration) ? { durationMs: duration } : {}),
    };
  }

  function uriId(uri) {
    const value = String(uri || "");
    return value.slice(value.lastIndexOf(":") + 1);
  }

  function normalizeGraphQLArtist(item) {
    const data = item?.data || item || {};
    const image = data?.visuals?.avatarImage?.sources?.[0]?.url;
    return {
      id: String(data.id || uriId(data.uri)),
      name: String(data.name || data.profile?.name || ""),
      uri: String(data.uri || ""),
      ...(image ? { images: [{ url: String(image) }] } : {}),
    };
  }

  function normalizeGraphQLTrack(item) {
    const data = item?.item?.data || item?.data || item || {};
    return {
      id: String(data.id || uriId(data.uri)),
      name: String(data.name || ""),
      uri: String(data.uri || ""),
      artists: (data.artists?.items || []).map((artist) => ({
        id: String(artist.id || uriId(artist.uri)),
        name: String(artist.name || artist.profile?.name || ""),
      })),
      durationMs: data.duration?.totalMilliseconds,
    };
  }

  function requireArray(value, field, body) {
    if (!Array.isArray(value)) throw new Error(`Spotify returned no ${field} list (schema: ${schemaKeys(body)})`);
    return value;
  }

  function requireText(value, field) {
    if (typeof value !== "string" || !value.trim()) throw new Error(`Spotify returned an incomplete ${field}`);
    return value;
  }

  function withDeadline(promise) {
    let timer;
    const timeout = new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error("Spotify discovery timed out")), API_DEADLINE_MS);
    });
    return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
  }

  async function graphqlRequest(Spicetify, request) {
    const graphql = Spicetify?.GraphQL;
    const definitions = graphql?.Definitions;
    if (!graphql?.Request) return null;
    if (request.operation === "top-artists" && (definitions?.userTopContent || GRAPHQL_DEFINITIONS.userTopContent)) {
      const response = await withDeadline(graphql.Request(definitions?.userTopContent || GRAPHQL_DEFINITIONS.userTopContent, {
        includeTopArtists: true,
        topArtistsInput: { offset: 0, limit: MAX_ARTISTS, sortBy: "AFFINITY", timeRange: "MID_TERM" },
        includeTopTracks: false,
        topTracksInput: { offset: 0, limit: 1, sortBy: "AFFINITY", timeRange: "MID_TERM" },
      }));
      const items = response?.data?.me?.profile?.topArtists?.items;
      return requireArray(items, "top artist", response?.data?.me?.profile?.topArtists).slice(0, MAX_ARTISTS).map((item) => validateArtist(normalizeGraphQLArtist(item)));
    }
    if (request.operation === "catalog" && (definitions?.searchTracks || GRAPHQL_DEFINITIONS.searchTracks)) {
      const artist = String(request.artist || "").trim();
      const title = String(request.title || "").trim();
      if (!artist || !title) throw new Error("Catalog discovery requires artist and title");
      const response = await withDeadline(graphql.Request(definitions?.searchTracks || GRAPHQL_DEFINITIONS.searchTracks, {
        searchTerm: `${artist} ${title}`,
        offset: 0,
        limit: MAX_TRACKS,
        includePreReleases: false,
        includeAlbumPreReleases: false,
        numberOfTopResults: 20,
        includeAudiobooks: true,
        includeAuthors: false,
        includeEpisodeContentRatingsV2: false,
      }));
      const items = response?.data?.searchV2?.tracksV2?.items;
      return requireArray(items, "catalog track", response?.data?.searchV2?.tracksV2).slice(0, MAX_TRACKS).map((item) => validateTrack(normalizeGraphQLTrack(item)));
    }
    return null;
  }

  function validateArtist(item) {
    requireText(item?.id, "artist id");
    requireText(item?.name, "artist name");
    requireText(item?.uri, "artist URI");
    return artistResult(item);
  }

  function validateTrack(item) {
    requireText(item?.id, "track id");
    requireText(item?.name, "track name");
    requireText(item?.uri, "track URI");
    const artists = requireArray(item?.artists?.items || item?.artists, "track artist");
    if (!artists.length || artists.length > 10) throw new Error("Spotify returned an invalid track artist list");
    artists.forEach((artist) => {
      requireText(artist?.id, "track artist id");
      requireText(artist?.name, "track artist name");
    });
    return trackResult(item);
  }

  async function spotifyRequest(Spicetify, request) {
    const CosmosAsync = Spicetify?.CosmosAsync;
    const graphql = Spicetify?.GraphQL;
    if (!CosmosAsync?.get && !graphql?.Request) throw new Error("Spotify discovery API is unavailable");
    if (graphql?.Request) {
      const result = await graphqlRequest(Spicetify, request);
      if (result) return request.operation === "top-artists" ? { ok: true, artists: result } : { ok: true, tracks: result };
    }
    if (!CosmosAsync?.get) throw new Error("Spotify discovery API is unavailable");
    if (request.operation === "top-artists") {
      const response = await withDeadline(CosmosAsync.get(`${SPOTIFY_API}/me/top/artists?time_range=medium_term&limit=${MAX_ARTISTS}`));
      const body = unwrapCosmosResponse(response, "Spotify top artists");
      const items = requireArray(body?.items, "top artist", body);
      return { ok: true, artists: items.slice(0, MAX_ARTISTS).map(validateArtist) };
    }
    if (request.operation === "catalog") {
      const artist = String(request.artist || "").trim();
      const title = String(request.title || "").trim();
      if (!artist || !title) throw new Error("Catalog discovery requires artist and title");
      const query = encodeURIComponent(`${artist} ${title}`);
      const response = await withDeadline(CosmosAsync.get(`${SPOTIFY_API}/search?type=track&limit=${MAX_TRACKS}&q=${query}`));
      const body = unwrapCosmosResponse(response, "Spotify catalog search");
      const items = requireArray(body?.tracks?.items, "catalog track", body);
      return { ok: true, tracks: items.slice(0, MAX_TRACKS).map(validateTrack) };
    }
    throw new Error("Unsupported Spotify discovery operation");
  }

  async function requestOnce(Spicetify, request, fetchImpl = fetch) {
    if (!request?.nonce || activeRequests.has(request.nonce)) return;
    activeRequests.add(request.nonce);
    try {
      let result;
      try {
        result = await spotifyRequest(Spicetify, request);
      } catch (error) {
        result = responseError(error);
      }
      await fetchImpl(`${DISCOVERY_SERVER}/result`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ nonce: request.nonce, result }),
      });
    } finally {
      activeRequests.delete(request.nonce);
    }
  }

  async function poll(Spicetify, fetchImpl = fetch) {
    let response;
    try {
      response = await fetchImpl(`${DISCOVERY_SERVER}/request`);
      if (!response.ok) return;
      const payload = await response.json();
      if (payload?.request) await requestOnce(Spicetify, payload.request, fetchImpl);
    } catch (_) {
      // Needle may not be waiting for a request. Avoid noisy Spotify UI errors.
    }
  }

  async function start(Spicetify) {
    await poll(Spicetify);
    setInterval(() => { void poll(Spicetify); }, POLL_INTERVAL_MS);
  }

  return { artistResult, poll, requestOnce, schemaKeys, spotifyRequest, start, trackResult, unwrapCosmosResponse };
});
