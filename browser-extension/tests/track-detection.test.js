const test = require("node:test");
const assert = require("node:assert/strict");
const detection = require("../track-detection.js");

test("parses and cleans a YouTube artist-title", () => {
  const track = detection.detectTrack({
    url: "https://www.youtube.com/watch?v=abc",
    pageTitle: "Kendrick Lamar - The Heart Pt. 2 (Official Audio) - YouTube",
    channel: "Kendrick Lamar - Topic",
  });
  assert.deepEqual(track, {
    sourceUrl: "https://www.youtube.com/watch?v=abc",
    site: "YouTube",
    artist: "Kendrick Lamar",
    title: "The Heart Pt. 2",
    complete: true,
  });
});

test("uses a SoundCloud byline", () => {
  const track = detection.detectTrack({
    url: "https://soundcloud.com/artist/song",
    ogTitle: "Song Name by Artist Name",
  });
  assert.equal(track.artist, "Artist Name");
  assert.equal(track.title, "Song Name");
  assert.equal(track.site, "SoundCloud");
});

test("prefers structured MusicRecording metadata", () => {
  const track = detection.detectTrack({
    url: "https://artist.bandcamp.com/track/song",
    pageTitle: "fallback",
    jsonLd: {
      "@type": "MusicRecording",
      name: "Exact Song",
      byArtist: { "@type": "MusicGroup", name: "Exact Artist" },
    },
  });
  assert.equal(track.artist, "Exact Artist");
  assert.equal(track.title, "Exact Song");
  assert.equal(track.complete, true);
});

test("keeps meaningful parentheses while removing upload noise", () => {
  const parsed = detection.splitArtistTitle("Artist - Song (Live at Red Rocks) [Official Video]");
  assert.equal(parsed.artist, "Artist");
  assert.equal(parsed.title, "Song (Live at Red Rocks)");
});

test("marks a title-only link incomplete so the user can correct it", () => {
  const track = detection.detectTrack({
    url: "https://www.youtube.com/watch?v=abc",
    linkText: "The Heart Pt. 2",
  });
  assert.equal(track.complete, false);
  assert.equal(track.artist, "");
});

test("drops a channel suffix after a pipe", () => {
  const parsed = detection.splitArtistTitle("Artist - Song | Artist Channel");
  assert.equal(parsed.artist, "Artist");
  assert.equal(parsed.title, "Song");
});

