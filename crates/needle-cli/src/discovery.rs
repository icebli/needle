use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::io::Read;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use needle_core::search::{Candidate, SearchSource};

const RESULTS_PER_QUERY: usize = 15;
const QUERY_TIMEOUT: Duration = Duration::from_secs(20);
const QUERIES: [&str; 3] = ["audio", "unreleased", "remix"];
const MAX_CAPTURE_BYTES: usize = 8 * 1024 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Response {
    pub ok: bool,
    pub candidates: Vec<Candidate>,
    pub warnings: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct Entry {
    id: String,
    title: String,
    uploader: Option<String>,
    #[serde(default)]
    channel_is_verified: Option<bool>,
    duration: Option<f64>,
    thumbnail: Option<String>,
    #[serde(default)]
    thumbnails: Vec<Thumbnail>,
    view_count: Option<u64>,
    webpage_url: Option<String>,
    url: Option<String>,
    #[serde(default)]
    acodec: Option<String>,
    #[serde(default)]
    abr: Option<f64>,
}

#[derive(Debug, Deserialize)]
struct Thumbnail {
    url: Option<String>,
    preference: Option<i64>,
    width: Option<u64>,
}

pub fn run(artist: &str, source: SearchSource) -> Result<Response> {
    let artist = artist.trim();
    if artist.is_empty() {
        bail!("artist must not be empty");
    }
    let toolchain = needle_core::Toolchain::discover()?;
    let mut candidates = Vec::new();
    let mut warnings = Vec::new();
    let mut seen = HashSet::new();

    for provider in source.providers() {
        for suffix in QUERIES {
            let query = format!("{artist} {suffix}");
            match search_provider(
                toolchain
                    .yt_dlp_path
                    .to_str()
                    .context("yt-dlp path is not valid UTF-8")?,
                &query,
                *provider,
            ) {
                Ok(entries) => {
                    for candidate in entries {
                        if !looks_like_artist(artist, &candidate) {
                            warnings.push(format!(
                                "Skipped a likely unrelated {} result: {}",
                                candidate.provider, candidate.title
                            ));
                            continue;
                        }
                        if seen.insert(format!("{}:{}", candidate.provider, candidate.id)) {
                            candidates.push(candidate);
                        }
                    }
                }
                Err(error) => {
                    warnings.push(format!("{provider:?} search failed for {query:?}: {error}"))
                }
            }
        }
    }

    candidates.sort_by(|a, b| {
        b.view_count
            .unwrap_or(0)
            .cmp(&a.view_count.unwrap_or(0))
            .then_with(|| a.provider.cmp(&b.provider))
            .then_with(|| a.url.cmp(&b.url))
    });
    Ok(Response {
        ok: true,
        candidates,
        warnings,
    })
}

fn search_provider(
    yt_dlp: &str,
    query: &str,
    provider: needle_core::search::SearchProvider,
) -> Result<Vec<Candidate>> {
    let (prefix, label) = match provider {
        needle_core::search::SearchProvider::Youtube => ("ytsearch", "youtube"),
        needle_core::search::SearchProvider::Soundcloud => ("scsearch", "soundcloud"),
    };
    let mut child = Command::new(yt_dlp)
        .args([
            &format!("{prefix}{RESULTS_PER_QUERY}:{query}"),
            "--flat-playlist",
            "--dump-json",
            "--no-warnings",
            "--quiet",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("could not start yt-dlp for {label}"))?;
    let stdout = child
        .stdout
        .take()
        .context("yt-dlp stdout pipe was not created")?;
    let stderr = child
        .stderr
        .take()
        .context("yt-dlp stderr pipe was not created")?;
    let stdout_reader = thread::spawn(|| drain_capped(stdout));
    let stderr_reader = thread::spawn(|| drain_capped(stderr));

    let deadline = Instant::now() + QUERY_TIMEOUT;
    loop {
        if let Some(status) = child.try_wait()? {
            let output = stdout_reader
                .join()
                .map_err(|_| anyhow::anyhow!("yt-dlp stdout reader panicked"))??;
            let error = stderr_reader
                .join()
                .map_err(|_| anyhow::anyhow!("yt-dlp stderr reader panicked"))??;
            if !status.success() {
                let detail = String::from_utf8_lossy(&error).trim().to_owned();
                bail!(
                    "yt-dlp exited with {}{}",
                    status,
                    if detail.is_empty() {
                        String::new()
                    } else {
                        format!(": {detail}")
                    }
                );
            }
            return parse_entries(&String::from_utf8_lossy(&output), label, query);
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            let _ = stdout_reader.join();
            let _ = stderr_reader.join();
            bail!("timed out after {} seconds", QUERY_TIMEOUT.as_secs());
        }
        thread::sleep(Duration::from_millis(50));
    }
}

fn drain_capped<R: Read>(mut reader: R) -> std::io::Result<Vec<u8>> {
    let mut captured = Vec::with_capacity(MAX_CAPTURE_BYTES.min(64 * 1024));
    let mut buffer = [0_u8; 16 * 1024];
    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            return Ok(captured);
        }
        if captured.len() < MAX_CAPTURE_BYTES {
            let remaining = MAX_CAPTURE_BYTES - captured.len();
            captured.extend_from_slice(&buffer[..read.min(remaining)]);
        }
    }
}

fn parse_entries(stdout: &str, provider: &str, query: &str) -> Result<Vec<Candidate>> {
    let mut candidates = Vec::new();
    for line in stdout.lines().filter(|line| !line.trim().is_empty()) {
        let entry: Entry = match serde_json::from_str(line) {
            Ok(entry) => entry,
            Err(_) => continue,
        };
        let url = entry
            .webpage_url
            .or(entry.url)
            .unwrap_or_else(|| match provider {
                "youtube" => format!("https://www.youtube.com/watch?v={}", entry.id),
                _ => entry.id.clone(),
            });
        let thumbnail_url = entry.thumbnail.or_else(|| {
            entry
                .thumbnails
                .iter()
                .filter_map(|thumb| thumb.url.as_ref().map(|url| (thumb, url)))
                .max_by_key(|(thumb, _)| {
                    (
                        thumb.preference.unwrap_or(i64::MIN),
                        thumb.width.unwrap_or(0),
                    )
                })
                .map(|(_, url)| url.clone())
        });
        candidates.push(Candidate {
            provider: provider.to_owned(),
            id: entry.id,
            url,
            title: entry.title,
            uploader: entry.uploader,
            channel_is_verified: entry.channel_is_verified,
            duration_ms: entry
                .duration
                .map(|seconds| (seconds.max(0.0) * 1000.0) as u64),
            thumbnail_url,
            view_count: entry.view_count,
            audio_codec: entry.acodec.filter(|codec| !codec.trim().is_empty()),
            audio_bitrate_kbps: entry
                .abr
                .filter(|abr| abr.is_finite() && *abr > 0.0)
                .map(|abr| abr.round() as u32),
            query_origin: query.to_owned(),
        });
    }
    Ok(candidates)
}

fn looks_like_artist(artist: &str, candidate: &Candidate) -> bool {
    let artist = normalize(artist);
    let haystack = normalize(&format!(
        "{} {}",
        candidate.title,
        candidate.uploader.as_deref().unwrap_or("")
    ));
    if haystack.contains(&artist) {
        return true;
    }
    let tokens: Vec<&str> = artist
        .split_whitespace()
        .filter(|token| token.len() > 1)
        .collect();
    !tokens.is_empty() && tokens.iter().all(|token| haystack.contains(token))
}

fn normalize(value: &str) -> String {
    value
        .chars()
        .map(|ch| {
            if ch.is_alphanumeric() {
                ch.to_ascii_lowercase()
            } else {
                ' '
            }
        })
        .collect::<String>()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_candidates_without_rewriting_source_urls_and_keeps_view_counts() {
        let rows = r#"{"id":"one","title":"Artist - Popular","uploader":"Artist","webpage_url":"https://example.test/original","view_count":100}
{"id":"two","title":"Artist - Unknown","uploader":"Artist"}"#;
        let candidates = parse_entries(rows, "youtube", "Artist audio").unwrap();
        assert_eq!(candidates[0].url, "https://example.test/original");
        assert_eq!(candidates[0].view_count, Some(100));
        assert_eq!(candidates[1].url, "https://www.youtube.com/watch?v=two");
    }

    #[test]
    fn artist_filter_rejects_unrelated_results_but_allows_uploader_aliases() {
        let good = Candidate {
            provider: "youtube".into(),
            id: "1".into(),
            url: "https://example/1".into(),
            title: "Official audio".into(),
            uploader: Some("The Artist VEVO".into()),
            channel_is_verified: None,
            duration_ms: None,
            thumbnail_url: None,
            view_count: None,
            audio_codec: None,
            audio_bitrate_kbps: None,
            query_origin: "Artist audio".into(),
        };
        let bad = Candidate {
            uploader: Some("Other Channel".into()),
            ..good.clone()
        };
        assert!(looks_like_artist("The Artist", &good));
        assert!(!looks_like_artist("The Artist", &bad));
    }

    #[test]
    fn source_queries_are_bounded_to_fifteen_results() {
        assert_eq!(RESULTS_PER_QUERY, 15);
        assert_eq!(QUERIES, ["audio", "unreleased", "remix"]);
    }

    #[cfg(unix)]
    #[test]
    fn drains_large_yt_dlp_output_without_deadlocking_and_keeps_urls() {
        use std::os::unix::fs::PermissionsExt;

        let path =
            std::env::temp_dir().join(format!("needle-discovery-noisy-{}", std::process::id()));
        let script = r#"#!/bin/sh
printf '%s\n' '{"id":"kept","title":"Artist - Loud","uploader":"Artist"}'
i=0
while [ "$i" -lt 256 ]; do
  printf '{"id":"noise-%s","title":"padding","padding":"' "$i"
  j=0
  while [ "$j" -lt 256 ]; do printf 'xxxxxxxxxxxxxxxx'; j=$((j + 1)); done
  printf '"}\n'
  i=$((i + 1))
done
"#;
        std::fs::write(&path, script).unwrap();
        let mut permissions = std::fs::metadata(&path).unwrap().permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(&path, permissions).unwrap();

        let candidates = search_provider(
            path.to_str().unwrap(),
            "Artist audio",
            needle_core::search::SearchProvider::Youtube,
        )
        .unwrap();
        assert_eq!(candidates[0].url, "https://www.youtube.com/watch?v=kept");
        assert_eq!(candidates.len(), 257);
        let _ = std::fs::remove_file(path);
    }
}
