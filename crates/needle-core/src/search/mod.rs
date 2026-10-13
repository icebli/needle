use serde::{Deserialize, Serialize};
use anyhow::{Result, bail};
use std::process::Command;
use tracing::debug;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SearchSource {
    Auto,
    Youtube,
    Soundcloud,
}

impl SearchSource {
    pub fn providers(self) -> &'static [SearchProvider] {
        match self {
            SearchSource::Auto => &[SearchProvider::Youtube, SearchProvider::Soundcloud],
            SearchSource::Youtube => &[SearchProvider::Youtube],
            SearchSource::Soundcloud => &[SearchProvider::Soundcloud],
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SearchProvider {
    Youtube,
    Soundcloud,
}

impl SearchProvider {
    fn label(self) -> &'static str {
        match self {
            SearchProvider::Youtube => "youtube",
            SearchProvider::Soundcloud => "soundcloud",
        }
    }

    fn search_prefix(self) -> &'static str {
        match self {
            SearchProvider::Youtube => "ytsearch",
            SearchProvider::Soundcloud => "scsearch",
        }
    }
}

/// A single candidate audio source from a search provider
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Candidate {
    pub provider: String,
    pub id: String,
    pub url: String,
    pub title: String,
    pub uploader: Option<String>,
    /// Milliseconds
    pub duration_ms: Option<u64>,
    pub thumbnail_url: Option<String>,
    pub view_count: Option<u64>,
    /// Audio codec reported by the source, when yt-dlp provides one.
    #[serde(default)]
    pub audio_codec: Option<String>,
    /// Audio bitrate in kbps reported by the source, when available.
    #[serde(default)]
    pub audio_bitrate_kbps: Option<u32>,
    pub query_origin: String,
}

impl Candidate {
    /// Short source-quality label, such as `opus 160kbps`.
    ///
    /// This describes the upload needle would download. It is not the quality
    /// of a later MP3 conversion.
    pub fn source_quality_label(&self) -> Option<String> {
        format_source_quality(self.audio_codec.as_deref(), self.audio_bitrate_kbps)
    }
}

pub fn format_source_quality(codec: Option<&str>, bitrate_kbps: Option<u32>) -> Option<String> {
    let codec = codec.map(str::trim).filter(|value| {
        let lower = value.to_ascii_lowercase();
        !lower.is_empty() && lower != "none" && lower != "unknown"
    });
    match (codec, bitrate_kbps) {
        (Some(codec), Some(bitrate)) => Some(format!("{codec} {bitrate}kbps")),
        (Some(codec), None) => Some(codec.to_string()),
        (None, Some(bitrate)) => Some(format!("{bitrate}kbps")),
        (None, None) => None,
    }
}

/// A search query with intent/weight metadata
#[derive(Debug, Clone)]
pub struct SearchQuery {
    pub query: String,
    pub intent: QueryIntent,
    pub weight: f32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QueryIntent {
    ExactTitle,
    NormalizedTitle,
    AlbumHinted,
    Broad,
}

/// Build multiple search queries for a request
pub fn build_queries(artist: &str, title: &str, album: Option<&str>) -> Vec<SearchQuery> {
    use crate::normalize::normalize_title;
    let norm = normalize_title(title);

    let mut queries = Vec::new();

    // 1. Exact as given
    queries.push(SearchQuery {
        query: format!("{artist} {title}"),
        intent: QueryIntent::ExactTitle,
        weight: 1.0,
    });

    // 2. Normalized (pt. → part)
    let normalized_q = format!("{artist} {}", norm.normalized);
    if normalized_q != queries[0].query {
        queries.push(SearchQuery {
            query: normalized_q,
            intent: QueryIntent::NormalizedTitle,
            weight: 0.95,
        });
    }

    // 3. With "audio" suffix to get cleaner uploads
    queries.push(SearchQuery {
        query: format!("{artist} {title} audio"),
        intent: QueryIntent::NormalizedTitle,
        weight: 0.85,
    });

    // 4. Album-hinted if available
    if let Some(album) = album {
        queries.push(SearchQuery {
            query: format!("{artist} {title} {album}"),
            intent: QueryIntent::AlbumHinted,
            weight: 0.8,
        });
    }

    queries
}

/// yt-dlp flat search JSON shape (subset)
#[derive(Debug, Deserialize)]
struct YtdlpEntry {
    id: String,
    url: Option<String>,
    title: String,
    uploader: Option<String>,
    duration: Option<f64>,
    #[serde(alias = "thumbnail_url", alias = "thumbnailUrl")]
    thumbnail: Option<String>,
    #[serde(default)]
    thumbnails: Vec<YtdlpThumbnail>,
    view_count: Option<u64>,
    webpage_url: Option<String>,
    #[serde(default)]
    acodec: Option<String>,
    #[serde(default)]
    abr: Option<f64>,
}

#[derive(Debug, Deserialize)]
struct YtdlpThumbnail {
    url: Option<String>,
    preference: Option<i64>,
    width: Option<u64>,
}

/// Search YouTube via yt-dlp and return candidates
pub fn search_youtube(
    yt_dlp_path: &str,
    queries: &[SearchQuery],
    max_per_query: usize,
) -> Result<Vec<Candidate>> {
    search_sources(yt_dlp_path, queries, max_per_query, SearchSource::Youtube)
}

/// Search configured yt-dlp providers and return merged candidates.
pub fn search_sources(
    yt_dlp_path: &str,
    queries: &[SearchQuery],
    max_per_query: usize,
    source: SearchSource,
) -> Result<Vec<Candidate>> {
    let mut candidates: Vec<Candidate> = Vec::new();
    let mut seen_ids = std::collections::HashSet::new();

    for provider in source.providers() {
        search_provider(yt_dlp_path, queries, max_per_query, *provider, &mut seen_ids, &mut candidates)?;
    }

    Ok(candidates)
}

fn search_provider(
    yt_dlp_path: &str,
    queries: &[SearchQuery],
    max_per_query: usize,
    provider: SearchProvider,
    seen_ids: &mut std::collections::HashSet<String>,
    candidates: &mut Vec<Candidate>,
) -> Result<()> {
    for sq in queries {
        let search_arg = format!("{}{max_per_query}:{}", provider.search_prefix(), sq.query);
        debug!("yt-dlp search: {search_arg}");

        let output = Command::new(yt_dlp_path)
            .args([
                &search_arg,
                "--flat-playlist",
                "--dump-json",
                "--no-warnings",
                "--quiet",
            ])
            .output()?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            tracing::warn!("yt-dlp search failed: {stderr}");
            continue;
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        for line in stdout.lines() {
            if line.is_empty() { continue; }
            match serde_json::from_str::<YtdlpEntry>(line) {
                Ok(entry) => {
                    let seen_key = format!("{}:{}", provider.label(), entry.id);
                    if seen_ids.contains(&seen_key) { continue; }
                    seen_ids.insert(seen_key);

                    let thumbnail_url = thumbnail_url(&entry, provider);
                    let url = entry.webpage_url
                        .or(entry.url)
                        .unwrap_or_else(|| provider_fallback_url(provider, &entry.id));

                    candidates.push(Candidate {
                        provider: provider.label().into(),
                        id: entry.id,
                        url,
                        title: entry.title,
                        uploader: entry.uploader,
                        duration_ms: entry.duration.map(|d| (d * 1000.0) as u64),
                        thumbnail_url,
                        view_count: entry.view_count,
                        audio_codec: clean_codec(entry.acodec.as_deref()),
                        audio_bitrate_kbps: bitrate_kbps(entry.abr),
                        query_origin: sq.query.clone(),
                    });
                }
                Err(e) => {
                    tracing::debug!("parse error on yt-dlp entry: {e}");
                }
            }
        }
    }

    Ok(())
}

fn provider_fallback_url(provider: SearchProvider, id: &str) -> String {
    match provider {
        SearchProvider::Youtube => format!("https://www.youtube.com/watch?v={id}"),
        SearchProvider::Soundcloud => id.to_string(),
    }
}

fn thumbnail_url(entry: &YtdlpEntry, provider: SearchProvider) -> Option<String> {
    entry.thumbnail.clone()
        .or_else(|| entry.thumbnails.iter()
            .filter_map(|thumbnail| thumbnail.url.as_ref().map(|url| (thumbnail, url)))
            .max_by_key(|(thumbnail, _)| (thumbnail.preference.unwrap_or(i64::MIN), thumbnail.width.unwrap_or(0)))
            .map(|(_, url)| url.clone()))
        .or_else(|| match provider {
            SearchProvider::Youtube => Some(format!("https://i.ytimg.com/vi/{}/hqdefault.jpg", entry.id)),
            SearchProvider::Soundcloud => None,
        })
}

/// Resolve a direct URL (not a search) via yt-dlp and return it as a Candidate.

fn is_supported_direct_url(url: &str) -> bool {
    let Some((scheme, rest)) = url.split_once("://") else {
        return false;
    };
    if !matches!(scheme, "http" | "https") {
        return false;
    }
    let host = rest.split(['/', '?', '#']).next().unwrap_or("");
    !host.is_empty() && !host.contains(' ')
}


fn clean_codec(value: Option<&str>) -> Option<String> {
    value.map(str::trim).filter(|codec| {
        let lower = codec.to_ascii_lowercase();
        !lower.is_empty() && lower != "none" && lower != "unknown"
    }).map(str::to_string)
}

fn bitrate_kbps(value: Option<f64>) -> Option<u32> {
    value.filter(|bitrate| bitrate.is_finite() && *bitrate > 0.0).map(|bitrate| bitrate.round() as u32)
}

pub fn resolve_url(yt_dlp_path: &str, url: &str) -> Result<Option<Candidate>> {
    if !is_supported_direct_url(url) {
        bail!("direct URL must be an HTTP(S) media page");
    }
    let output = Command::new(yt_dlp_path)
        .args([url, "--dump-json", "--skip-download", "--no-playlist", "--format", "bestaudio/best", "--no-warnings", "--quiet"])
        .output()?;

    if !output.status.success() {
        return Ok(None);
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let line = stdout.lines().next().unwrap_or("").trim();
    if line.is_empty() { return Ok(None); }

    let entry: YtdlpEntry = serde_json::from_str(line)?;
    let thumbnail_url = thumbnail_url(&entry, if url.contains("soundcloud.com") { SearchProvider::Soundcloud } else { SearchProvider::Youtube });

    // Infer provider from URL
    let provider = if url.contains("soundcloud.com") { "soundcloud" } else { "youtube" };
    let resolved_url = entry.webpage_url.or(entry.url.clone()).unwrap_or_else(|| url.to_string());

    Ok(Some(Candidate {
        provider: provider.into(),
        id: entry.id,
        url: resolved_url,
        title: entry.title,
        uploader: entry.uploader,
        duration_ms: entry.duration.map(|d| (d * 1000.0) as u64),
        thumbnail_url,
        view_count: entry.view_count,
        audio_codec: clean_codec(entry.acodec.as_deref()),
        audio_bitrate_kbps: bitrate_kbps(entry.abr),
        query_origin: "canonical".into(),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_non_http_direct_urls_before_launching_yt_dlp() {
        let error = resolve_url("false", "file:///tmp/secret.mp3").unwrap_err();
        assert!(error.to_string().contains("HTTP(S)"));
    }

    #[test]
    fn source_quality_label_keeps_codec_and_bitrate_visible() {
        assert_eq!(format_source_quality(Some("opus"), Some(160)), Some("opus 160kbps".into()));
        assert_eq!(format_source_quality(Some("none"), Some(128)), Some("128kbps".into()));
        assert_eq!(format_source_quality(None, None), None);
    }

    #[test]
    fn bitrate_rounds_yt_dlp_abr_and_ignores_missing_codec() {
        assert_eq!(bitrate_kbps(Some(159.6)), Some(160));
        assert_eq!(clean_codec(Some(" none ")), None);
        assert_eq!(clean_codec(Some("opus")).as_deref(), Some("opus"));
    }

    #[test]
    fn parses_thumbnail_url_alias_and_prefers_explicit_thumbnail() {
        let entry: YtdlpEntry = serde_json::from_str(r#"{
            "id":"abc",
            "title":"Song",
            "thumbnail_url":"https://cdn.example/thumb.jpg",
            "thumbnails":[{"url":"https://cdn.example/low.jpg","width":120}]
        }"#).unwrap();
        assert_eq!(thumbnail_url(&entry, SearchProvider::Youtube).as_deref(), Some("https://cdn.example/thumb.jpg"));
    }

    #[test]
    fn selects_best_available_thumbnail_before_provider_fallback() {
        let entry: YtdlpEntry = serde_json::from_str(r#"{
            "id":"abc",
            "title":"Song",
            "thumbnails":[
                {"url":"https://cdn.example/low.jpg","preference":1,"width":120},
                {"url":"https://cdn.example/high.jpg","preference":2,"width":640}
            ]
        }"#).unwrap();
        assert_eq!(thumbnail_url(&entry, SearchProvider::Soundcloud).as_deref(), Some("https://cdn.example/high.jpg"));
    }

    #[test]
    fn derives_youtube_thumbnail_when_flat_result_has_no_artwork() {
        let entry: YtdlpEntry = serde_json::from_str(r#"{"id":"abc123","title":"Song"}"#).unwrap();
        assert_eq!(thumbnail_url(&entry, SearchProvider::Youtube).as_deref(), Some("https://i.ytimg.com/vi/abc123/hqdefault.jpg"));
        assert_eq!(thumbnail_url(&entry, SearchProvider::Soundcloud), None);
    }
}
