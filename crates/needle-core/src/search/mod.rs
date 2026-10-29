use anyhow::{bail, Result};
use serde::{Deserialize, Serialize};
use tracing::debug;

use crate::toolchain::{yt_dlp_command, yt_dlp_error_message};

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
    /// Whether the provider reports the uploader channel as verified.
    #[serde(default)]
    pub channel_is_verified: Option<bool>,
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
    #[serde(default)]
    channel_is_verified: Option<bool>,
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
    let mut failures = Vec::new();
    let mut provider_succeeded = false;

    for provider in source.providers() {
        match search_provider(
            yt_dlp_path,
            queries,
            max_per_query,
            *provider,
            &mut seen_ids,
            &mut candidates,
        ) {
            Ok(()) => provider_succeeded = true,
            Err(error) => failures.push(error.to_string()),
        }
    }
    if !provider_succeeded && !failures.is_empty() {
        bail!("media search failed: {}", failures.join("; "));
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
    let mut query_succeeded = false;
    let mut last_failure = None;
    for sq in queries {
        let search_arg = format!("{}{max_per_query}:{}", provider.search_prefix(), sq.query);
        debug!("yt-dlp search: {search_arg}");

        let output = yt_dlp_command(yt_dlp_path)
            .args([
                &search_arg,
                "--flat-playlist",
                "--dump-json",
                "--no-warnings",
                "--quiet",
            ])
            .output();

        let output = match output {
            Ok(output) => output,
            Err(error) => {
                last_failure = Some(format!(
                    "could not start yt-dlp for {}: {error}",
                    provider.label()
                ));
                continue;
            }
        };

        if !output.status.success() {
            let message = yt_dlp_error_message(&output.stderr);
            tracing::warn!("{} search failed: {message}", provider.label());
            last_failure = Some(format!("{}: {message}", provider.label()));
            continue;
        }
        query_succeeded = true;

        let stdout = String::from_utf8_lossy(&output.stdout);
        for line in stdout.lines() {
            if line.is_empty() {
                continue;
            }
            match serde_json::from_str::<YtdlpEntry>(line) {
                Ok(entry) => {
                    let seen_key = format!("{}:{}", provider.label(), entry.id);
                    if seen_ids.contains(&seen_key) {
                        continue;
                    }
                    seen_ids.insert(seen_key);

                    let thumbnail_url = thumbnail_url(&entry, provider);
                    let url = entry
                        .webpage_url
                        .or(entry.url)
                        .unwrap_or_else(|| provider_fallback_url(provider, &entry.id));

                    candidates.push(Candidate {
                        provider: provider.label().into(),
                        id: entry.id,
                        url,
                        title: entry.title,
                        uploader: entry.uploader,
                        channel_is_verified: entry.channel_is_verified,
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

    if !query_succeeded {
        if let Some(failure) = last_failure {
            bail!("{failure}");
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
    entry
        .thumbnail
        .clone()
        .or_else(|| {
            entry
                .thumbnails
                .iter()
                .filter_map(|thumbnail| thumbnail.url.as_ref().map(|url| (thumbnail, url)))
                .max_by_key(|(thumbnail, _)| {
                    (
                        thumbnail.preference.unwrap_or(i64::MIN),
                        thumbnail.width.unwrap_or(0),
                    )
                })
                .map(|(_, url)| url.clone())
        })
        .or_else(|| match provider {
            SearchProvider::Youtube => {
                Some(format!("https://i.ytimg.com/vi/{}/hqdefault.jpg", entry.id))
            }
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
    value
        .map(str::trim)
        .filter(|codec| {
            let lower = codec.to_ascii_lowercase();
            !lower.is_empty() && lower != "none" && lower != "unknown"
        })
        .map(str::to_string)
}

fn bitrate_kbps(value: Option<f64>) -> Option<u32> {
    value
        .filter(|bitrate| bitrate.is_finite() && *bitrate > 0.0)
        .map(|bitrate| bitrate.round() as u32)
}

pub fn resolve_url(yt_dlp_path: &str, url: &str) -> Result<Option<Candidate>> {
    if !is_supported_direct_url(url) {
        bail!("direct URL must be an HTTP(S) media page");
    }
    let output = yt_dlp_command(yt_dlp_path)
        .args([
            url,
            "--dump-json",
            "--skip-download",
            "--no-playlist",
            "--format",
            "bestaudio/best",
            "--no-warnings",
            "--quiet",
        ])
        .output()?;

    if !output.status.success() {
        bail!(
            "could not resolve this recording: {}",
            yt_dlp_error_message(&output.stderr)
        );
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let line = stdout.lines().next().unwrap_or("").trim();
    if line.is_empty() {
        return Ok(None);
    }

    let entry: YtdlpEntry = serde_json::from_str(line)?;
    let thumbnail_url = thumbnail_url(
        &entry,
        if url.contains("soundcloud.com") {
            SearchProvider::Soundcloud
        } else {
            SearchProvider::Youtube
        },
    );

    // Infer provider from URL
    let provider = if url.contains("soundcloud.com") {
        "soundcloud"
    } else {
        "youtube"
    };
    let resolved_url = entry
        .webpage_url
        .or(entry.url.clone())
        .unwrap_or_else(|| url.to_string());

    Ok(Some(Candidate {
        provider: provider.into(),
        id: entry.id,
        url: resolved_url,
        title: entry.title,
        uploader: entry.uploader,
        channel_is_verified: entry.channel_is_verified,
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

    #[cfg(unix)]
    fn fake_yt_dlp(name: &str, script: &str) -> std::path::PathBuf {
        use std::os::unix::fs::PermissionsExt;

        let path =
            std::env::temp_dir().join(format!("needle-search-{name}-{}", std::process::id()));
        std::fs::write(&path, format!("#!/bin/sh\n{script}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    #[cfg(unix)]
    #[test]
    fn direct_url_auth_failure_is_actionable_without_provider_secrets() {
        let path = fake_yt_dlp(
            "auth",
            "printf '%s\\n' 'ERROR: [youtube] Sign in to confirm you are not a bot. secret-cookie=value /private/browser/profile' >&2\nexit 1",
        );
        let error = resolve_url(
            path.to_str().unwrap(),
            "https://www.youtube.com/watch?v=exact",
        )
        .unwrap_err()
        .to_string();
        assert!(error.contains("signed-in browser session"));
        assert!(error.contains("Needle Settings"));
        assert!(!error.contains("secret-cookie"));
        assert!(!error.contains("/private/browser"));
        let _ = std::fs::remove_file(path);
    }

    #[cfg(unix)]
    #[test]
    fn search_errors_when_every_provider_fails() {
        let path = fake_yt_dlp(
            "all-failed",
            "printf '%s\\n' 'ERROR: Sign in to confirm you are not a bot' >&2\nexit 1",
        );
        let queries = build_queries("Artist", "Song", None);
        let error = search_sources(path.to_str().unwrap(), &queries, 2, SearchSource::Auto)
            .unwrap_err()
            .to_string();
        assert!(error.contains("youtube:"));
        assert!(error.contains("soundcloud:"));
        assert!(error.contains("signed-in browser session"));
        let _ = std::fs::remove_file(path);
    }

    #[cfg(unix)]
    #[test]
    fn search_keeps_other_provider_results_after_auth_failure() {
        let path = fake_yt_dlp(
            "partial",
            r#"for arg in "$@"; do
  case "$arg" in
    ytsearch*) printf '%s\n' 'ERROR: Sign in to confirm you are not a bot' >&2; exit 1 ;;
    scsearch*) printf '%s\n' '{"id":"kept","title":"Artist - Song","webpage_url":"https://soundcloud.com/artist/song"}'; exit 0 ;;
  esac
done
exit 2"#,
        );
        let candidates = search_sources(
            path.to_str().unwrap(),
            &build_queries("Artist", "Song", None),
            2,
            SearchSource::Auto,
        )
        .unwrap();
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].provider, "soundcloud");
        assert_eq!(candidates[0].url, "https://soundcloud.com/artist/song");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn source_quality_label_keeps_codec_and_bitrate_visible() {
        assert_eq!(
            format_source_quality(Some("opus"), Some(160)),
            Some("opus 160kbps".into())
        );
        assert_eq!(
            format_source_quality(Some("none"), Some(128)),
            Some("128kbps".into())
        );
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
        let entry: YtdlpEntry = serde_json::from_str(
            r#"{
            "id":"abc",
            "title":"Song",
            "thumbnail_url":"https://cdn.example/thumb.jpg",
            "thumbnails":[{"url":"https://cdn.example/low.jpg","width":120}]
        }"#,
        )
        .unwrap();
        assert_eq!(
            thumbnail_url(&entry, SearchProvider::Youtube).as_deref(),
            Some("https://cdn.example/thumb.jpg")
        );
    }

    #[test]
    fn selects_best_available_thumbnail_before_provider_fallback() {
        let entry: YtdlpEntry = serde_json::from_str(
            r#"{
            "id":"abc",
            "title":"Song",
            "thumbnails":[
                {"url":"https://cdn.example/low.jpg","preference":1,"width":120},
                {"url":"https://cdn.example/high.jpg","preference":2,"width":640}
            ]
        }"#,
        )
        .unwrap();
        assert_eq!(
            thumbnail_url(&entry, SearchProvider::Soundcloud).as_deref(),
            Some("https://cdn.example/high.jpg")
        );
    }

    #[test]
    fn derives_youtube_thumbnail_when_flat_result_has_no_artwork() {
        let entry: YtdlpEntry = serde_json::from_str(r#"{"id":"abc123","title":"Song"}"#).unwrap();
        assert_eq!(
            thumbnail_url(&entry, SearchProvider::Youtube).as_deref(),
            Some("https://i.ytimg.com/vi/abc123/hqdefault.jpg")
        );
        assert_eq!(thumbnail_url(&entry, SearchProvider::Soundcloud), None);
    }

    #[test]
    fn preserves_provider_channel_verification() {
        let entry: YtdlpEntry = serde_json::from_str(
            r#"{
            "id":"abc123",
            "title":"Wanderlust",
            "uploader":"The Weeknd",
            "channel_is_verified":true
        }"#,
        )
        .unwrap();
        assert_eq!(entry.channel_is_verified, Some(true));

        let unknown: YtdlpEntry = serde_json::from_str(r#"{"id":"other","title":"Song"}"#).unwrap();
        assert_eq!(unknown.channel_is_verified, None);
    }
}
