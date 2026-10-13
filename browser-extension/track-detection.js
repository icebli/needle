(function installNeedleTrackDetection(root, factory) {
  const api = factory();
  root.NeedleTrackDetection = api;
  if (typeof module === "object" && module.exports) module.exports = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function createTrackDetection() {
  "use strict";

  const SITE_SUFFIXES = [
    /\s+-\s+YouTube(?:\s+Music)?\s*$/i,
    /\s*[|·•]\s*YouTube(?:\s+Music)?\s*$/i,
    /\s*[|·•]\s*SoundCloud\s*$/i,
    /\s*[|·•]\s*Bandcamp\s*$/i,
  ];
  const NOISE_MARKERS = [
    "official video",
    "official music video",
    "official audio",
    "official lyric video",
    "lyrics",
    "lyric video",
    "audio",
    "visualizer",
    "music video",
    "hd",
    "4k",
  ];

  function compact(value) {
    return String(value || "").replace(/\s+/g, " ").trim();
  }

  function stripSiteSuffix(value) {
    const withoutSite = SITE_SUFFIXES.reduce(
      (title, pattern) => title.replace(pattern, ""),
      compact(value),
    );
    const pipeIndex = withoutSite.indexOf(" | ");
    return pipeIndex > 0 ? withoutSite.slice(0, pipeIndex) : withoutSite;
  }

  function stripNoise(value) {
    let title = stripSiteSuffix(value);
    title = title.replace(/[([]([^\])]+)[\])]/g, (whole, marker) => {
      const normalized = compact(marker).toLowerCase();
      return NOISE_MARKERS.includes(normalized) ? "" : whole;
    });
    return compact(title.replace(/\s+(?:official\s+)?(?:music\s+)?video\s*$/i, ""));
  }

  function cleanArtist(value) {
    return compact(value)
      .replace(/\s+-\s+Topic\s*$/i, "")
      .replace(/\s+VEVO\s*$/i, "")
      .replace(/^by\s+/i, "");
  }

  function splitArtistTitle(value) {
    const title = stripNoise(value);
    const byMatch = title.match(/^(.+?)\s+by\s+(.+)$/i);
    if (byMatch) {
      return { artist: cleanArtist(byMatch[2]), title: stripNoise(byMatch[1]) };
    }
    const separators = [" - ", " – ", " — ", " • "];
    for (const separator of separators) {
      const index = title.indexOf(separator);
      if (index > 0 && index < title.length - separator.length) {
        return {
          artist: cleanArtist(title.slice(0, index)),
          title: stripNoise(title.slice(index + separator.length)),
        };
      }
    }
    return { artist: "", title };
  }

  function siteFromUrl(value) {
    try {
      const host = new URL(value).hostname.replace(/^www\./, "");
      if (host === "youtu.be" || host.endsWith("youtube.com")) return "YouTube";
      if (host.endsWith("soundcloud.com")) return "SoundCloud";
      if (host.endsWith("bandcamp.com")) return "Bandcamp";
      return host;
    } catch (_) {
      return "Media page";
    }
  }

  function findMusicRecording(value) {
    const items = Array.isArray(value) ? value : [value];
    for (const item of items) {
      if (!item || typeof item !== "object") continue;
      if (item["@graph"]) {
        const nested = findMusicRecording(item["@graph"]);
        if (nested) return nested;
      }
      const types = Array.isArray(item["@type"]) ? item["@type"] : [item["@type"]];
      if (types.some((type) => /MusicRecording|MusicVideoObject/i.test(String(type)))) return item;
    }
    return null;
  }

  function artistFromStructured(recording) {
    const artist = recording && (recording.byArtist || recording.author || recording.creator);
    if (typeof artist === "string") return artist;
    if (Array.isArray(artist)) return artist.map((entry) => entry && (entry.name || entry)).filter(Boolean).join(" & ");
    return artist && artist.name;
  }

  function detectTrack(input) {
    const sourceUrl = compact(input && input.url);
    const recording = findMusicRecording(input && input.jsonLd);
    const rawTitle = compact(
      (recording && (recording.name || recording.headline)) ||
      (input && (input.linkText || input.ogTitle || input.pageTitle)),
    );
    const split = splitArtistTitle(rawTitle);
    const structuredArtist = artistFromStructured(recording);
    const artist = cleanArtist(
      (input && input.artistHint) || structuredArtist || split.artist || (input && input.channel),
    );
    const title = stripNoise(split.title || rawTitle);

    return {
      sourceUrl,
      site: (input && input.siteName) || siteFromUrl(sourceUrl),
      artist,
      title,
      complete: Boolean(sourceUrl && artist && title),
    };
  }

  return {
    cleanArtist,
    detectTrack,
    siteFromUrl,
    splitArtistTitle,
    stripNoise,
  };
});
