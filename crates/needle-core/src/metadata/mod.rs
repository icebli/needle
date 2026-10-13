use serde::{Deserialize, Serialize};
use anyhow::Result;
use tracing::debug;
use crate::normalize::normalize_title;

/// Authoritative metadata for a track (from MusicBrainz, Apple, etc.)
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TrackMetadata {
    pub artist: String,
    /// Featured artists (all collaborators beyond the primary artist)
    pub featured_artists: Vec<String>,
    pub title: String,
    pub possible_titles: Vec<String>,
    pub duration_ms: Option<u64>,
    pub album: Option<String>,
    pub release_date: Option<String>,
    pub track_number: Option<u32>,
    pub disc_number: Option<u32>,
    pub artwork_url: Option<String>,
    pub isrc: Option<String>,
    pub external_ids: ExternalIds,
    /// Which resolver produced this result and its plausibility score
    pub source: MetadataSource,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct MetadataSource {
    pub provider: String,
    pub plausibility_score: i32,
    pub recording_id: Option<String>,
    /// MB release MBID for the preferred (Single/Album) release — used to fetch URL relations
    #[serde(skip)]
    pub preferred_release_id: Option<String>,
    /// Canonical streaming URL from MB release URL relations
    pub canonical_url: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ExternalIds {
    pub musicbrainz_recording_id: Option<String>,
    pub spotify_id: Option<String>,
    pub apple_music_id: Option<String>,
}

/// Resolve metadata from all configured providers
pub async fn resolve_metadata(artist: &str, title: &str) -> Result<Option<TrackMetadata>> {
    let musicbrainz = match resolve_musicbrainz(artist, title).await {
        Ok(meta) => meta,
        Err(err) => {
            debug!("MusicBrainz lookup failed: {err}");
            None
        }
    };
    let apple = match resolve_apple(artist, title).await {
        Ok(meta) => meta,
        Err(err) => {
            debug!("Apple lookup failed: {err}");
            None
        }
    };

    // Prefer plausible full-length Apple/store metadata over short MusicBrainz
    // snippets/interviews. The scorer treats duration as high-trust, so bad
    // reference duration is worse than missing duration.
    let chosen = match (musicbrainz, apple) {
        (Some(mb), Some(ap)) => {
            let mb_score = metadata_plausibility_score(artist, title, &mb);
            let ap_score = metadata_plausibility_score(artist, title, &ap);
            if ap_score > mb_score { ap } else { mb }
        }
        (Some(mb), None) => mb,
        (None, Some(ap)) => ap,
        (None, None) => return Ok(None),
    };

    debug!("metadata resolved: {} - {}", chosen.artist, chosen.title);
    Ok(Some(chosen))
}

fn metadata_plausibility_score(request_artist: &str, request_title: &str, meta: &TrackMetadata) -> i32 {
    let req = normalize_title(request_title);
    let got = normalize_title(&meta.title);

    // Hard reject: metadata title has negative markers (remix, waowmix, reaction, etc.)
    if !got.negative_markers.is_empty() {
        return -100;
    }

    let mut score = 0;
    if meta.artist.to_ascii_lowercase().contains(&request_artist.to_ascii_lowercase()) {
        score += 30;
    }
    if got.base_title.contains(&req.base_title) || req.base_title.contains(&got.base_title) {
        score += 30;
    }
    match (&req.series_marker, &got.series_marker) {
        (Some(r), Some(g)) if r.kind == g.kind && r.value == g.value => score += 25,
        (Some(r), Some(g)) if r.kind == g.kind && r.value != g.value => score -= 100,
        (Some(_), None) => score -= 10,
        _ => {}
    }
    if meta.album.is_some() { score += 5; }
    if meta.track_number.is_some() { score += 5; }
    if meta.artwork_url.is_some() { score += 5; }
    match meta.duration_ms {
        Some(ms) if (120_000..=900_000).contains(&ms) => score += 20,
        Some(ms) if ms < 120_000 => score -= 60,
        Some(ms) if ms > 900_000 => score -= 20,
        None => score -= 5,
        _ => {}
    }
    score
}

// ─── MusicBrainz ─────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
struct MbRecording {
    title: String,
    #[serde(rename = "artist-credit")]
    artist_credit: Vec<MbArtistCredit>,
    #[serde(default)]
    length: Option<u64>,
    #[serde(default)]
    releases: Vec<MbRelease>,
    #[serde(default)]
    isrcs: Vec<String>,
    id: String,
}

#[derive(Debug, Deserialize)]
struct MbArtistCredit {
    name: String,
    // join phrase between artists, e.g. " feat. " — we don't use it but need to deserialize
    #[serde(default)]
    #[allow(dead_code)]
    joinphrase: Option<String>,
}

#[allow(dead_code)]
#[derive(Debug, Deserialize)]
struct MbRelease {
    id: String,
    title: String,
    #[serde(default)]
    date: Option<String>,
    #[serde(default)]
    #[serde(rename = "track-count")]
    track_count: Option<u32>,
    #[serde(default)]
    #[serde(rename = "media")]
    media: Vec<MbMedia>,
    #[serde(default)]
    #[serde(rename = "release-group")]
    release_group: Option<MbReleaseGroup>,
}

#[allow(dead_code)]
#[derive(Debug, Deserialize)]
struct MbReleaseGroup {
    #[serde(default)]
    #[serde(rename = "primary-type")]
    primary_type: Option<String>,
}

#[derive(Debug, Deserialize)]
struct MbMedia {
    #[serde(default)]
    tracks: Vec<MbTrack>,
}

#[derive(Debug, Deserialize)]
struct MbTrack {
    #[serde(default)]
    number: Option<String>,
}

#[derive(Debug, Deserialize)]
struct MbSearchResult {
    recordings: Vec<MbRecording>,
}

#[derive(Debug, Deserialize)]
struct MbReleaseUrlResult {
    #[serde(default)]
    relations: Vec<MbUrlRelation>,
}

#[derive(Debug, Deserialize)]
struct MbUrlRelation {
    #[serde(rename = "type")]
    rel_type: String,
    url: MbUrl,
}

#[derive(Debug, Deserialize)]
struct MbUrl {
    resource: String,
}

/// Fetch streaming URL relations for a MB release ID.
/// Returns the first "free streaming" or "streaming" URL found.
async fn fetch_release_canonical_url(client: &reqwest::Client, release_id: &str) -> Option<String> {
    let url = format!(
        "https://musicbrainz.org/ws/2/release/{}?fmt=json&inc=url-rels",
        release_id
    );
    let resp = client.get(&url)
        .header("User-Agent", "needle/0.1.0 (needle@example.com)")
        .send().await.ok()?;
    if !resp.status().is_success() { return None; }
    let result: MbReleaseUrlResult = resp.json().await.ok()?;
    // Prefer "free streaming" then "streaming" then any audio source
    let priority = ["free streaming", "streaming", "download for free", "purchase for download"];
    for ptype in priority {
        if let Some(rel) = result.relations.iter().find(|r| r.rel_type == ptype) {
            return Some(rel.url.resource.clone());
        }
    }
    None
}

async fn resolve_musicbrainz(artist: &str, title: &str) -> Result<Option<TrackMetadata>> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()?;
    let query = format!("artist:\"{artist}\" AND recording:\"{title}\"");
    let url = format!(
        "https://musicbrainz.org/ws/2/recording/?query={}&fmt=json&limit=15&inc=releases+artist-credits",
        urlencoding::encode(&query),
    );

    // Retry with exponential backoff on transient errors and 429 rate limiting
    let max_retries = 3;
    let mut last_err = None;
    for attempt in 0..max_retries {
        let resp = client
            .get(&url)
            .header("User-Agent", "needle/0.1.0 (needle@example.com)")
            .send()
            .await;

        match resp {
            Ok(r) if r.status().is_success() => {
                // Success — proceed with processing
                let result: MbSearchResult = r.json().await?;
                let best = result.recordings
                    .into_iter()
                    .map(|rec| {
                        let mut meta = mb_recording_to_metadata(artist, title, rec);
                        let score = metadata_plausibility_score(artist, title, &meta);
                        meta.source.plausibility_score = score;
                        (score, meta)
                    })
                    .filter(|(score, _)| *score >= 35)
                    .max_by_key(|(score, _)| *score)
                    .map(|(_, meta)| meta);

                // If we got a match, try to fetch canonical streaming URL from the preferred release
                let best = if let Some(mut meta) = best {
                    if let Some(ref release_id) = meta.source.preferred_release_id.clone() {
                        meta.source.canonical_url = fetch_release_canonical_url_with_retry(
                            &client, release_id, 2
                        ).await;
                        if let Some(ref url) = meta.source.canonical_url {
                            debug!("MB canonical URL: {}", url);
                        }
                    }
                    Some(meta)
                } else {
                    None
                };

                return Ok(best);
            }
            Ok(r) if r.status().as_u16() == 429 => {
                // Rate limited — extract Retry-After header, or backoff exponentially
                let wait = r.headers()
                    .get("retry-after")
                    .and_then(|v| v.to_str().ok())
                    .and_then(|v| v.parse::<u64>().ok())
                    .unwrap_or(2u64.pow(attempt as u32));
                debug!("MB rate limited (attempt {}), waiting {}s", attempt + 1, wait);
                tokio::time::sleep(std::time::Duration::from_secs(wait)).await;
                last_err = Some(anyhow::anyhow!("rate limited (429)"));
            }
            Ok(r) => {
                let status = r.status();
                debug!("MB returned {} (attempt {})", status, attempt + 1);
                if attempt + 1 < max_retries {
                    tokio::time::sleep(std::time::Duration::from_secs(2u64.pow(attempt as u32))).await;
                }
                last_err = Some(anyhow::anyhow!("HTTP {}", status));
            }
            Err(e) => {
                debug!("MB network error (attempt {}): {}", attempt + 1, e);
                if attempt + 1 < max_retries {
                    tokio::time::sleep(std::time::Duration::from_secs(2u64.pow(attempt as u32))).await;
                }
                last_err = Some(anyhow::anyhow!("{}", e));
            }
        }
    }

    debug!("MB all retries exhausted: {}", last_err.as_ref().map(|e| e.to_string()).unwrap_or_default());
    Ok(None)
}

/// Fetch release canonical URL with retry for 429 handling
async fn fetch_release_canonical_url_with_retry(
    client: &reqwest::Client,
    release_id: &str,
    max_retries: u32,
) -> Option<String> {
    for attempt in 0..max_retries {
        match fetch_release_canonical_url(client, release_id).await {
            Some(url) => return Some(url),
            None => {
                // fetch_release_canonical_url returns None on non-200, so retry
                if attempt + 1 < max_retries {
                    tokio::time::sleep(std::time::Duration::from_millis(500 * (attempt as u64 + 1))).await;
                }
            }
        }
    }
    None
}

fn mb_recording_to_metadata(artist: &str, title: &str, rec: MbRecording) -> TrackMetadata {
    // Best release: prefer Single/Album/EP by release-group type.
    // Fallback heuristics when release_group is missing:
    //   - prefer release title ≈ recording title (likely a single)
    //   - prefer fewer tracks (single > compilation)
    let preferred_release = {
        let mut best: Option<&MbRelease> = None;
        for rel in &rec.releases {
            let rg_type = rel.release_group.as_ref().and_then(|g| g.primary_type.as_deref());
            // Does this release beat current best?
            best = match best {
                None => Some(rel),
                Some(current) => {
                    let cur_type = current.release_group.as_ref().and_then(|g| g.primary_type.as_deref());
                    // Rank: Single/Album/EP > known other > unknown > compilation/live
                    let rank = |t: Option<&str>| match t {
                        Some("Single") => 5,
                        Some("Album") => 4,
                        Some("EP") => 3,
                        Some("Compilation") | Some("Live") => 1,
                        Some(_) => 2,
                        None => 2, // unknown — use tiebreakers below
                    };
                    let rel_r = rank(rg_type);
                    let cur_r = rank(cur_type);
                    if rel_r > cur_r {
                        Some(rel)
                    } else if rel_r == cur_r && cur_r <= 2 {
                        // Same tier (unknown or low) — prefer recording-title match & fewer tracks
                        let rec_title_lower = rec.title.to_ascii_lowercase();
                        let rel_match = rel.title.to_ascii_lowercase().contains(&rec_title_lower)
                            || rec_title_lower.contains(&rel.title.to_ascii_lowercase());
                        let cur_match = current.title.to_ascii_lowercase().contains(&rec_title_lower)
                            || rec_title_lower.contains(&current.title.to_ascii_lowercase());
                        if rel_match && !cur_match {
                            Some(rel)
                        } else if rel_match == cur_match {
                            // Prefer fewer tracks (single vs compilation)
                            let rel_tc = rel.track_count.unwrap_or(99);
                            let cur_tc = current.track_count.unwrap_or(99);
                            if rel_tc < cur_tc { Some(rel) } else { Some(current) }
                        } else {
                            Some(current)
                        }
                    } else {
                        Some(current)
                    }
                }
            };
        }
        best
    };

    let album = preferred_release.map(|r| r.title.clone());
    let release_date = preferred_release.and_then(|r| r.date.clone());
    let track_number = preferred_release
        .and_then(|r| r.media.first())
        .and_then(|m| m.tracks.first())
        .and_then(|t| t.number.as_ref())
        .and_then(|n| n.parse::<u32>().ok());

    // Primary artist = first credit; featured = rest
    let primary_artist = rec.artist_credit.first()
        .map(|a| a.name.clone())
        .unwrap_or_else(|| artist.to_string());
    let featured_artists: Vec<String> = rec.artist_credit.iter().skip(1)
        .filter(|a| !a.name.trim().is_empty())
        .map(|a| a.name.clone())
        .collect();

    let mb_id = rec.id.clone();
    let preferred_release_id = preferred_release.map(|r| r.id.clone());
    TrackMetadata {
        artist: primary_artist,
        featured_artists,
        title: rec.title,
        possible_titles: vec![title.to_string()],
        duration_ms: rec.length,
        album,
        release_date,
        track_number,
        disc_number: None,
        artwork_url: None,
        isrc: rec.isrcs.into_iter().next(),
        external_ids: ExternalIds {
            musicbrainz_recording_id: Some(rec.id),
            ..Default::default()
        },
        source: MetadataSource {
            provider: "musicbrainz".into(),
            recording_id: Some(mb_id),
            preferred_release_id,
            plausibility_score: 0,
            canonical_url: None,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_recording(title: &str, releases: Vec<MbRelease>) -> MbRecording {
        MbRecording {
            title: title.to_string(),
            artist_credit: vec![MbArtistCredit { name: "TestArtist".into(), joinphrase: None }],
            length: Some(200_000),
            releases,
            isrcs: vec![],
            id: "test-rec-id".into(),
        }
    }

    fn release(id: &str, title: &str, track_count: Option<u32>, rg_type: Option<&str>) -> MbRelease {
        MbRelease {
            id: id.into(),
            title: title.into(),
            date: None,
            track_count,
            media: vec![],
            release_group: rg_type.map(|t| MbReleaseGroup {
                primary_type: Some(t.to_string()),
            }),
        }
    }

    #[test]
    fn prefers_known_single_over_unknown() {
        let rec = make_recording("My Song", vec![
            release("rel-1", "Compilation Album", Some(20), None),
            release("rel-2", "Best of 2024", Some(15), Some("Single")),
        ]);
        let meta = mb_recording_to_metadata("TestArtist", "My Song", rec);
        assert_eq!(meta.source.preferred_release_id.as_deref(), Some("rel-2"));
        assert_eq!(meta.album.as_deref(), Some("Best of 2024"));
    }

    #[test]
    fn prefers_recording_title_match_when_rg_missing() {
        let rec = make_recording("Look Out for Detox", vec![
            release("rel-comp", "Compton State of Mind, Vol. 2", Some(11), None),
            release("rel-single", "Look Out for Detox", Some(1), None),
        ]);
        let meta = mb_recording_to_metadata("TestArtist", "Look Out for Detox", rec);
        assert_eq!(meta.source.preferred_release_id.as_deref(), Some("rel-single"));
        assert_eq!(meta.album.as_deref(), Some("Look Out for Detox"));
    }

    #[test]
    fn fewer_tracks_wins_when_neither_title_matches() {
        let rec = make_recording("X", vec![
            release("rel-1", "Various Artists", Some(15), None),
            release("rel-2", "Summer Hits", Some(5), None)]);
        let meta = mb_recording_to_metadata("TestArtist", "X", rec);
        assert_eq!(meta.source.preferred_release_id.as_deref(), Some("rel-2"));
    }

    #[test]
    fn prefers_album_rg_over_ep() {
        let rec = make_recording("Song", vec![
            release("rel-ep", "Songs EP", Some(4), Some("EP")),
            release("rel-album", "The Album", Some(12), Some("Album")),
        ]);
        let meta = mb_recording_to_metadata("TestArtist", "Song", rec);
        assert_eq!(meta.source.preferred_release_id.as_deref(), Some("rel-album"));
    }

    #[test]
    fn prefers_single_over_compilation_rg() {
        let rec = make_recording("A", vec![
            release("rel-comp", "Hits", Some(20), Some("Compilation")),
            release("rel-single", "A", Some(1), Some("Single")),
        ]);
        let meta = mb_recording_to_metadata("TestArtist", "A", rec);
        assert_eq!(meta.source.preferred_release_id.as_deref(), Some("rel-single"));
    }

    #[test]
    fn picks_only_release() {
        let rec = make_recording("Lonely", vec![
            release("only", "Only Release", Some(5), None),
        ]);
        let meta = mb_recording_to_metadata("TestArtist", "Lonely", rec);
        assert_eq!(meta.source.preferred_release_id.as_deref(), Some("only"));
    }
}

// ─── Apple iTunes Search ─────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
struct ItunesResult {
    results: Vec<ItunesTrack>,
}

#[allow(non_snake_case, dead_code)]
#[derive(Debug, Deserialize)]
struct ItunesTrack {
    trackName: String,
    artistName: String,
    collectionName: Option<String>,
    #[serde(default)]
    trackTimeMillis: Option<u64>,
    #[serde(default)]
    trackNumber: Option<u32>,
    #[serde(default)]
    discNumber: Option<u32>,
    #[serde(default)]
    releaseDate: Option<String>,
    #[serde(default)]
    artworkUrl100: Option<String>,
    #[serde(default)]
    trackViewUrl: Option<String>,
    #[serde(default)]
    collectionId: Option<u64>,
}

async fn resolve_apple(artist: &str, title: &str) -> Result<Option<TrackMetadata>> {
    let client = reqwest::Client::new();

    // Query 1: title-focused (most precise)
    let title_url = format!(
        "https://itunes.apple.com/search?term={}&attribute=songTerm&entity=song&limit=5",
        urlencoding::encode(title)
    );
    // Query 2: combined artist+title fallback
    let combined_url = format!(
        "https://itunes.apple.com/search?term={}&entity=song&limit=5",
        urlencoding::encode(&format!("{} {}", artist, title))
    );

    let mut all_results: Vec<ItunesTrack> = Vec::new();
    for url in [&title_url, &combined_url] {
        let resp = client.get(url.as_str()).send().await?;
        if resp.status().is_success() {
            if let Ok(result) = resp.json::<ItunesResult>().await {
                all_results.extend(result.results);
            }
        }
    }

    let best = all_results
        .into_iter()
        .map(|track| {
            let mut meta = itunes_track_to_metadata(title, track);
            let score = metadata_plausibility_score(artist, title, &meta);
            meta.source.plausibility_score = score;
            (score, meta)
        })
        .filter(|(score, _)| *score >= 35)
        .max_by_key(|(score, _)| *score)
        .map(|(_, meta)| meta);

    Ok(best)
}

fn itunes_track_to_metadata(title: &str, track: ItunesTrack) -> TrackMetadata {
    TrackMetadata {
        artist: track.artistName,
        featured_artists: vec![],
        title: track.trackName.clone(),
        possible_titles: vec![track.trackName, title.to_string()],
        duration_ms: track.trackTimeMillis,
        album: track.collectionName,
        release_date: track.releaseDate,
        track_number: track.trackNumber,
        disc_number: track.discNumber,
        artwork_url: track.artworkUrl100,
        isrc: None,
        external_ids: ExternalIds {
            apple_music_id: track.trackViewUrl,
            ..Default::default()
        },
        source: MetadataSource {
            provider: "itunes".into(),
            plausibility_score: 0,
            recording_id: None,
            preferred_release_id: None,
            canonical_url: None,
        },
    }
}

