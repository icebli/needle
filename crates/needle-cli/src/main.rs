use anyhow::{bail, Result};
use clap::{Parser, Subcommand};
use console::style;
use indicatif::{ProgressBar, ProgressStyle};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::time::Duration;
use strsim::jaro_winkler;

mod discovery;
mod library_scan;

#[derive(Parser)]
#[command(name = "needle")]
#[command(about = "Strict recording resolver — get the exact song you asked for")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Resolve, score, and download a track
    Get {
        /// Artist name
        #[arg(required = true)]
        artist: String,
        /// Track title
        #[arg(required = true)]
        title: String,
        /// Album hint
        #[arg(short, long)]
        album: Option<String>,
        /// Direct URL (skip search)
        #[arg(short, long)]
        url: Option<String>,
        /// Output format
        #[arg(short, long, default_value = "mp3")]
        format: String,
        /// Output profile
        #[arg(short, long, default_value = "default")]
        profile: String,
        /// JSON output
        #[arg(long)]
        json: bool,
        /// Skip metadata lookup; use request text and candidate duration only
        #[arg(long)]
        no_metadata: bool,
        /// Override expected duration, e.g. 4:54 or 294
        #[arg(long)]
        duration_override: Option<String>,
        /// Auto-accept first non-rejected candidate and start download
        #[arg(short = 'y', long, alias = "auto-accept")]
        yes: bool,
        /// Refuse rejected candidates, including explicitly supplied URLs
        #[arg(long)]
        strict: bool,
        /// Search source: auto, youtube, or soundcloud
        #[arg(long, default_value = "auto")]
        source: String,
        /// Emit newline-delimited progress events on stderr
        #[arg(long)]
        events: bool,
        #[arg(long)]
        approved_tags: Option<String>,
    },
    /// Preview metadata for a selected source before downloading it
    Prepare {
        artist: String,
        title: String,
        #[arg(long)]
        source_title: String,
        #[arg(long)]
        url: String,
        #[arg(short, long)]
        album: Option<String>,
        #[arg(long)]
        no_metadata: bool,
    },
    /// Search only, show candidates
    Search {
        artist: String,
        title: String,
        #[arg(short, long)]
        album: Option<String>,
        #[arg(short, long)]
        url: Option<String>,
        /// Skip metadata lookup; use request text and candidate duration only
        #[arg(long)]
        no_metadata: bool,
        /// Override expected duration, e.g. 4:54 or 294
        #[arg(long)]
        duration_override: Option<String>,
        /// Search source: auto, youtube, or soundcloud
        #[arg(long, default_value = "auto")]
        source: String,
        /// Emit one structured JSON response
        #[arg(long)]
        json: bool,
    },
    /// Check toolchain health
    Doctor {
        /// Emit one structured JSON response
        #[arg(long)]
        json: bool,
    },
    /// Inspect tags and embedded artwork in an existing audio file
    Inspect {
        path: PathBuf,
        #[arg(long)]
        artwork_dir: Option<PathBuf>,
        #[arg(long)]
        json: bool,
    },
    /// Repair tags and/or embedded artwork in place without downloading audio
    Repair {
        path: PathBuf,
        #[arg(long)]
        artist: Option<String>,
        #[arg(long)]
        title: Option<String>,
        #[arg(long)]
        album: Option<String>,
        #[arg(long)]
        clear_album: bool,
        #[arg(long)]
        album_artist: Option<String>,
        #[arg(long, alias = "artwork-file")]
        artwork: Option<PathBuf>,
        /// Download artwork from this explicitly approved URL (max 10 MiB)
        #[arg(long)]
        artwork_url: Option<String>,
        #[arg(long)]
        json: bool,
    },
    /// Resolve authoritative metadata suggestions for an existing recording
    RepairSuggestions {
        path: PathBuf,
        #[arg(long)]
        json: bool,
    },
    /// Resolve a source URL into editable artist/title fields without searching or downloading
    IdentifyUrl {
        url: String,
        #[arg(long)]
        json: bool,
    },
    /// Inventory existing audio files without changing them
    LibraryScan {
        root: PathBuf,
        #[arg(long)]
        json: bool,
    },
    /// Find popular and unreleased recordings for an artist
    Discover {
        /// Artist name
        artist: String,
        /// Search source: auto, youtube, or soundcloud
        #[arg(long, default_value = "auto")]
        source: String,
        /// Emit one structured JSON response
        #[arg(long)]
        json: bool,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    // Structured stdout modes reserve stdout for their single JSON response.
    // Keep diagnostics from tracing on stderr so GUI callers can parse stdout.
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .init();
    let cli = Cli::parse();

    match cli.command {
        Commands::Get {
            artist,
            title,
            album,
            url,
            format,
            profile,
            json,
            no_metadata,
            duration_override,
            yes,
            strict,
            source,
            events,
            approved_tags,
        } => {
            cmd_get(GetOptions {
                artist,
                title,
                album,
                url,
                format,
                profile,
                json,
                no_metadata,
                duration_override,
                yes,
                strict,
                source,
                events,
                approved_tags_json: approved_tags,
            })
            .await
        }
        Commands::Prepare {
            artist,
            title,
            source_title,
            url,
            album,
            no_metadata,
        } => cmd_prepare(artist, title, source_title, url, album, no_metadata).await,
        Commands::Search {
            artist,
            title,
            album,
            url,
            no_metadata,
            duration_override,
            source,
            json,
        } => {
            cmd_search(SearchOptions {
                artist,
                title,
                album,
                url,
                no_metadata,
                duration_override,
                source,
                json,
            })
            .await
        }
        Commands::Doctor { json } => cmd_doctor(json).await,
        Commands::Inspect {
            path,
            artwork_dir,
            json,
        } => cmd_inspect(path, artwork_dir, json),
        Commands::Repair {
            path,
            artist,
            title,
            album,
            clear_album,
            album_artist,
            artwork,
            artwork_url,
            json,
        } => {
            cmd_repair(
                path,
                artist,
                title,
                album,
                clear_album,
                album_artist,
                artwork,
                artwork_url,
                json,
            )
            .await
        }
        Commands::RepairSuggestions { path, json } => cmd_repair_suggestions(path, json).await,
        Commands::IdentifyUrl { url, json } => cmd_identify_url(url, json),
        Commands::LibraryScan { root, json } => cmd_library_scan(root, json),
        Commands::Discover {
            artist,
            source,
            json,
        } => cmd_discover(&artist, &source, json),
    }
}

fn cmd_discover(artist: &str, source: &str, json: bool) -> Result<()> {
    let source = parse_source(source)?;
    let response = discovery::run(artist, source)?;
    if json {
        println!("{}", serde_json::to_string(&response)?);
    } else {
        println!(
            "Found {} candidate recordings for {artist}",
            response.candidates.len()
        );
        for candidate in &response.candidates {
            let views = candidate
                .view_count
                .map(|count| count.to_string())
                .unwrap_or_else(|| "unknown views".into());
            println!(
                "{} — {} · {} views · {}",
                candidate.uploader.as_deref().unwrap_or("Unknown uploader"),
                candidate.title,
                views,
                candidate.url
            );
        }
        for warning in &response.warnings {
            eprintln!("Warning: {warning}");
        }
    }
    Ok(())
}

fn cmd_library_scan(root: PathBuf, json: bool) -> Result<()> {
    let response = library_scan::run(&root)?;
    if json {
        println!("{}", serde_json::to_string(&response)?);
    } else {
        println!(
            "Found {} audio files in {}",
            response.tracks.len(),
            root.display()
        );
        for track in &response.tracks {
            println!(
                "{} — {}",
                track.artist.as_deref().unwrap_or("Unknown artist"),
                track.title.as_deref().unwrap_or("Unknown title")
            );
        }
        for warning in &response.warnings {
            eprintln!("Warning: {warning}");
        }
    }
    Ok(())
}

fn cmd_inspect(path: PathBuf, artwork_dir: Option<PathBuf>, json: bool) -> Result<()> {
    let inspected = needle_core::tag::inspect_tags(&path, artwork_dir.as_deref())?;
    if json {
        println!(
            "{}",
            serde_json::to_string(&serde_json::json!({"ok": true, "track": inspected}))?
        );
    } else {
        println!("{}", path.display());
        println!(
            "  {} — {}",
            inspected.artist.as_deref().unwrap_or("Unknown artist"),
            inspected.title.as_deref().unwrap_or("Unknown title")
        );
        println!(
            "  Album: {}",
            inspected.album.as_deref().unwrap_or("(none)")
        );
        println!("  Artwork: {}", inspected.artwork.len());
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn cmd_repair(
    path: PathBuf,
    artist: Option<String>,
    title: Option<String>,
    album: Option<String>,
    clear_album: bool,
    album_artist: Option<String>,
    artwork: Option<PathBuf>,
    artwork_url: Option<String>,
    json: bool,
) -> Result<()> {
    if album.is_some() && clear_album {
        bail!("use either --album or --clear-album, not both");
    }
    if artwork_url.is_some() && artwork.is_some() {
        bail!("use either --artwork or --artwork-url, not both");
    }
    let mut artwork_data = artwork
        .map(|p| -> Result<Vec<u8>> { Ok(std::fs::read(p)?) })
        .transpose()?;
    let mut artwork_mime = None;
    if let Some(url) = artwork_url {
        if !url.starts_with("https://") && !url.starts_with("http://") {
            bail!("artwork URL must use HTTP(S)");
        }
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(30))
            .build()?;
        let response = client.get(&url).send().await?.error_for_status()?;
        if response
            .content_length()
            .is_some_and(|length| length > 10 * 1024 * 1024)
        {
            bail!("artwork exceeds 10 MiB limit");
        }
        let content_type = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .map(str::to_owned);
        artwork_mime = None;
        if content_type
            .as_deref()
            .is_some_and(|mime| !mime.to_ascii_lowercase().starts_with("image/"))
        {
            bail!("artwork URL did not return an image");
        }
        let mut bytes = Vec::new();
        let mut response = response;
        while let Some(chunk) = response.chunk().await? {
            if bytes.len().saturating_add(chunk.len()) > 10 * 1024 * 1024 {
                bail!("artwork exceeds 10 MiB limit");
            }
            bytes.extend_from_slice(&chunk);
        }
        artwork_data = Some(bytes);
    }
    if artist.is_none()
        && title.is_none()
        && album.is_none()
        && !clear_album
        && album_artist.is_none()
        && artwork_data.is_none()
    {
        bail!("provide at least one field to repair");
    }
    let updated = needle_core::tag::repair_tags_with_backup(
        &path,
        &needle_core::tag::TagRepair {
            artist,
            title,
            album,
            clear_album,
            album_artist,
            artwork: artwork_data,
            artwork_mime,
        },
    )?;
    if json {
        println!(
            "{}",
            serde_json::to_string(
                &serde_json::json!({"ok": true, "track": updated.track, "backup_path": updated.backup_path})
            )?
        );
    } else {
        println!("Repaired {}", path.display());
    }
    Ok(())
}

async fn cmd_repair_suggestions(path: PathBuf, json: bool) -> Result<()> {
    let current = needle_core::tag::inspect_tags(&path, None)?;
    let artist = current
        .artist
        .as_deref()
        .ok_or_else(|| anyhow::anyhow!("file has no artist tag"))?;
    let title = current
        .title
        .as_deref()
        .ok_or_else(|| anyhow::anyhow!("file has no title tag"))?;
    let metadata = needle_core::metadata::resolve_metadata(artist, title)
        .await?
        .ok_or_else(|| anyhow::anyhow!("no authoritative metadata found"))?;
    let warning = metadata_variant_warning(title, &metadata.title);
    let response = serde_json::json!({"ok": true, "path": path, "current": current, "suggestion": metadata, "warning": warning});
    if json {
        println!("{}", response);
    } else {
        println!("Suggested: {} — {}", metadata.artist, metadata.title);
    }
    Ok(())
}

fn cmd_identify_url(url: String, json: bool) -> Result<()> {
    if !url.starts_with("https://") && !url.starts_with("http://") {
        bail!("source URL must use HTTP(S)");
    }
    let toolchain = needle_core::Toolchain::discover()?;
    let candidate =
        needle_core::search::resolve_url(toolchain.yt_dlp_path.to_str().unwrap(), &url)?
            .ok_or_else(|| anyhow::anyhow!("source URL could not be resolved"))?;
    let (artist, title, uncertain) = identify_candidate(&candidate);
    let response = serde_json::json!({"ok": true, "artist": artist, "title": title, "source_url": candidate.url, "uncertain": uncertain});
    if json {
        println!("{}", response);
    } else {
        println!(
            "{} — {}",
            response["artist"].as_str().unwrap_or("Unknown artist"),
            response["title"].as_str().unwrap_or("Unknown title")
        );
    }
    Ok(())
}

fn identify_candidate(candidate: &needle_core::Candidate) -> (String, String, bool) {
    let uploader = candidate
        .uploader
        .clone()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| "Unknown artist".into());
    let title = candidate.title.trim().to_owned();
    // Uploaders may be remixers or channels rather than the recording artist.
    // Use a conventional title prefix as a hint, retaining uncertainty whenever
    // it disagrees with the uploader so approval never implies verified tags.
    for separator in [" - ", " — ", " – "] {
        if let Some((prefix, rest)) = title.split_once(separator) {
            let artist = prefix.trim();
            let song = rest.trim();
            if !artist.is_empty() && !song.is_empty() {
                return (
                    artist.to_owned(),
                    song.to_owned(),
                    !artist.eq_ignore_ascii_case(uploader.trim()),
                );
            }
        }
    }
    (uploader, title, true)
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct ApprovedTags {
    artist: String,
    title: String,
    #[serde(default)]
    album: String,
    #[serde(default)]
    album_artist: String,
    #[serde(default)]
    featured_artists: Vec<String>,
    #[serde(default)]
    artwork_url: String,
    source_url: String,
}

fn parse_approved_tags(value: &str) -> Result<ApprovedTags> {
    let tags: ApprovedTags = serde_json::from_str(value)
        .map_err(|error| anyhow::anyhow!("invalid --approved-tags JSON: {error}"))?;
    if tags.artist.trim().is_empty() || tags.title.trim().is_empty() {
        bail!("approved tags must include non-empty artist and title");
    }
    if tags.source_url.trim().is_empty() {
        bail!("approved tags must include source_url");
    }
    Ok(tags)
}

fn approved_tags_metadata(tags: &ApprovedTags) -> needle_core::TrackMetadata {
    needle_core::TrackMetadata {
        artist: tags.artist.clone(),
        featured_artists: tags.featured_artists.clone(),
        title: tags.title.clone(),
        album: (!tags.album.trim().is_empty()).then(|| tags.album.clone()),
        artwork_url: (!tags.artwork_url.trim().is_empty()).then(|| tags.artwork_url.clone()),
        source: needle_core::metadata::MetadataSource {
            provider: "approved".into(),
            ..Default::default()
        },
        ..Default::default()
    }
}

async fn download_approved_artwork(url: &str) -> Result<PathBuf> {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        bail!("approved artwork URL must use HTTP(S)");
    }
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()?;
    let response = client.get(url).send().await?.error_for_status()?;
    if response
        .content_length()
        .is_some_and(|length| length > 10 * 1024 * 1024)
    {
        bail!("approved artwork exceeds 10 MiB limit");
    }
    let declared = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .split(';')
        .next()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    let mut response = response;
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await? {
        if bytes.len().saturating_add(chunk.len()) > 10 * 1024 * 1024 {
            bail!("approved artwork exceeds 10 MiB limit");
        }
        bytes.extend_from_slice(&chunk);
    }
    let (mime, extension) = detect_artwork_type(&bytes)
        .ok_or_else(|| anyhow::anyhow!("approved artwork URL did not return a recognized image"))?;
    if !declared.is_empty()
        && declared != mime
        && !(mime == "image/jpeg" && declared == "image/jpg")
    {
        bail!("approved artwork MIME type {declared:?} does not match image bytes ({mime})");
    }
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or_default();
    let path = std::env::temp_dir().join(format!("needle-approved-artwork-{nonce}.{extension}"));
    std::fs::write(&path, &bytes)?;
    Ok(path)
}

fn detect_artwork_type(bytes: &[u8]) -> Option<(&'static str, &'static str)> {
    if bytes.starts_with(&[0xff, 0xd8, 0xff]) {
        Some(("image/jpeg", "jpg"))
    } else if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some(("image/png", "png"))
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        Some(("image/gif", "gif"))
    } else {
        None
    }
}

fn preview_title_with_features(
    base: String,
    source_title: &str,
    featured_artists: &[String],
) -> String {
    if !featured_artists.is_empty() {
        return format!(
            "{base} (feat. {})",
            normalize_featured_artists_list_pub(featured_artists)
        );
    }
    let source = source_title
        .split_once(" - ")
        .map(|(_, title)| clean_title_fragment(title))
        .unwrap_or_else(|| clean_title_fragment(source_title));
    if source.to_ascii_lowercase().contains("(feat.") {
        source
    } else {
        base
    }
}

async fn cmd_prepare(
    artist: String,
    title: String,
    source_title: String,
    source_url: String,
    album: Option<String>,
    no_metadata: bool,
) -> Result<()> {
    if !(source_url.starts_with("https://") || source_url.starts_with("http://")) {
        bail!("source URL must use http:// or https://");
    }
    let resolved = if no_metadata {
        None
    } else {
        filter_compatible_metadata(
            needle_core::metadata::resolve_metadata(&artist, &title).await?,
            &artist,
            &title,
        )
    };
    let inferred_title = source_title_for_preview(&source_title, &artist);
    let mut warnings = Vec::new();
    let tags = if let Some(metadata) = resolved {
        let conflict = requested_variant_conflicts_with_metadata(&title, &metadata.title);
        if conflict {
            warnings.push(metadata_variant_warning(&title, &metadata.title).unwrap_or("Metadata does not match the requested variant; source wording was retained.").to_string());
        }
        let mut tags =
            metadata_for_tagging(Some(&metadata), &title, album.as_deref()).unwrap_or(metadata);
        if conflict {
            tags.artwork_url = None;
            if !inferred_title.is_empty() {
                tags.title = inferred_title.clone();
            }
        }
        tags.title = preview_title_with_features(tags.title, &source_title, &tags.featured_artists);
        tags
    } else {
        warnings.push(
            "No compatible authoritative metadata found; review all fields before saving.".into(),
        );
        needle_core::TrackMetadata {
            artist: artist.clone(),
            title: inferred_title,
            album: album.filter(|v| !v.trim().is_empty()),
            source: needle_core::metadata::MetadataSource {
                provider: "none".into(),
                ..Default::default()
            },
            ..Default::default()
        }
    };
    let response = serde_json::json!({
        "artist": tags.artist, "title": tags.title, "album": tags.album.unwrap_or_default(),
        "album_artist": tags.artist, "artwork_url": tags.artwork_url.unwrap_or_default(),
        "source": tags.source.provider, "warnings": warnings, "source_url": source_url,
    });
    println!("{}", serde_json::to_string(&response)?);
    Ok(())
}

fn source_title_for_preview(source_title: &str, artist: &str) -> String {
    let candidate = source_title
        .split_once(" - ")
        .filter(|(prefix, _)| contains_or_close(prefix, artist, 0.86))
        .map(|(_, title)| title)
        .unwrap_or(source_title);
    let variant = candidate
        .find('(')
        .and_then(|start| {
            candidate[start + 1..]
                .find(')')
                .map(|end| candidate[start + 1..start + 1 + end].trim().to_owned())
        })
        .filter(|value| has_mix_variant(value));
    let base = clean_title_fragment(candidate);
    if let Some(variant) = variant {
        if !base
            .to_ascii_lowercase()
            .contains(&variant.to_ascii_lowercase())
        {
            return format!("{base} ({variant})");
        }
    }
    base
}

struct GetOptions {
    artist: String,
    title: String,
    album: Option<String>,
    url: Option<String>,
    format: String,
    profile: String,
    json: bool,
    no_metadata: bool,
    duration_override: Option<String>,
    yes: bool,
    strict: bool,
    source: String,
    events: bool,
    approved_tags_json: Option<String>,
}

async fn cmd_get(options: GetOptions) -> Result<()> {
    let GetOptions {
        artist,
        title,
        album,
        url,
        format,
        profile,
        json,
        no_metadata,
        duration_override,
        yes,
        strict,
        source,
        events,
        approved_tags_json,
    } = options;
    use needle_core::*;
    let approved_tags = approved_tags_json
        .as_deref()
        .map(parse_approved_tags)
        .transpose()?;

    let toolchain = Toolchain::discover()?;
    let direct_url_provided = url.is_some();
    let req = ParsedRequest {
        artist: artist.clone(),
        title: title.clone(),
        album,
        url,
        format: parse_format(&format),
        profile,
    };

    // 1. Resolve metadata
    progress_event(events, "metadata");
    let pb = spinner("Resolving metadata...");
    let metadata = if let Some(ref tags) = approved_tags {
        Some(approved_tags_metadata(tags))
    } else if no_metadata {
        None
    } else {
        let resolved = metadata::resolve_metadata(&req.artist, &req.title).await?;
        filter_compatible_metadata(resolved, &req.artist, &req.title)
    };
    pb.finish_and_clear();

    if !json {
        if let Some(ref m) = metadata {
            println!(
                "{} {} — {}",
                style("✓").green(),
                style(&m.artist).bold(),
                style(&m.title).bold()
            );
            if let Some(ref album) = m.album {
                println!("  Album: {}", album);
            }
            if let Some(dur) = m.duration_ms {
                println!("  Duration: {}", fmt_duration(dur));
            }
        } else {
            println!(
                "{} No metadata found — using request tags only",
                style("⚠").yellow()
            );
        }
    }

    // 2. Build queries + search
    progress_event(events, "search");
    let queries = search::build_queries(&req.artist, &req.title, req.album.as_deref());
    let pb = spinner(if req.url.is_some() {
        "Resolving selected source..."
    } else {
        "Searching sources..."
    });
    let mut candidates = resolve_requested_candidates(
        toolchain.yt_dlp_path.to_str().unwrap(),
        &queries,
        parse_source(&source)?,
        req.url.as_deref(),
    )?;
    pb.finish_and_clear();

    // 2b. If MB gave us a canonical URL, resolve it via yt-dlp and prepend as top candidate
    if req.url.is_none() {
        if let Some(ref canonical_url) = metadata
            .as_ref()
            .and_then(|m| m.source.canonical_url.clone())
        {
            let pb = spinner("Resolving canonical source URL...");
            match search::resolve_url(toolchain.yt_dlp_path.to_str().unwrap(), canonical_url) {
                Ok(Some(canonical_candidate)) => {
                    if !json {
                        println!(
                            "{} Canonical source: {} · {}",
                            style("✓").green(),
                            style(&canonical_candidate.title).bold(),
                            canonical_candidate.uploader.as_deref().unwrap_or("?"),
                        );
                    }
                    // Prepend — scorer will rank it, but it gets first position as tiebreak
                    candidates.insert(0, canonical_candidate);
                }
                Ok(None) => {}
                Err(e) => {
                    eprintln!("[debug] canonical URL resolve failed: {e}");
                }
            }
            pb.finish_and_clear();
        }
    }

    if !json {
        println!(
            "{} Found {} candidates\n",
            style("✓").green(),
            candidates.len()
        );
    }

    if candidates.is_empty() {
        bail!("no candidates found");
    }

    // 3. Score candidates
    let req_norm = normalize::normalize_title(&req.title);
    let consensus_dur = score::infer_consensus_duration_ms(&req.artist, &req_norm, &candidates);
    let expected_dur = choose_expected_duration(
        parse_duration_override(duration_override.as_deref())?,
        metadata.as_ref().and_then(|m| m.duration_ms),
        consensus_dur,
    );
    let config = score::ScorerConfig::default();

    let mut scored: Vec<(search::Candidate, score::CandidateScore)> = candidates
        .into_iter()
        .map(|c| {
            let s = score::score_candidate(&req.artist, &req_norm, &c, expected_dur, &config);
            (c, s)
        })
        .collect();

    scored.sort_by_key(|a| std::cmp::Reverse(a.1.confidence));

    // 4. Display
    if !json {
        display_candidates(&scored, &req, metadata.as_ref(), expected_dur);
    }

    // 5. Select
    let selection = if yes {
        auto_select_candidate(&scored, direct_url_provided, json)?
    } else {
        select_candidate(&scored, direct_url_provided)?
    };
    let (selected, selected_score) = &scored[selection];
    guard_selected_candidate(strict, selected_score)?;
    if let Some(ref approved) = approved_tags {
        if approved.source_url != selected.url {
            bail!("approved metadata source_url does not match selected source URL");
        }
    }

    if !json {
        println!("\nDownloading: {}\n", style(&selected.title).bold());
    }

    // 6a. Post-selection metadata upgrade: if initial lookup missed or has no album,
    //     re-query with the clean inferred title extracted from the selected source.
    //     This handles mixtapes/singles where raw request title differs from canonical.
    let mut meta_re_queried = false;
    let metadata = if approved_tags.is_some() {
        metadata
    } else if !no_metadata {
        let inferred_clean = infer_title_from_source_title(&selected.title, &req.artist);
        let needs_upgrade = metadata.as_ref().map(|m| m.album.is_none()).unwrap_or(true);
        if needs_upgrade {
            if let Some(clean_title) = inferred_clean.as_deref() {
                if clean_title != req.title {
                    let pb = spinner("Re-resolving metadata with inferred title...");
                    let upgraded = metadata::resolve_metadata(&req.artist, clean_title)
                        .await
                        .ok()
                        .flatten()
                        .and_then(|m| {
                            filter_compatible_metadata(Some(m), &req.artist, clean_title)
                        });
                    pb.finish_and_clear();
                    if let Some(ref m) = upgraded {
                        meta_re_queried = true;
                        if !json {
                            println!(
                                "{} Upgraded metadata: {} — {}{}",
                                style("✓").green(),
                                style(&m.artist).bold(),
                                style(&m.title).bold(),
                                m.album
                                    .as_deref()
                                    .map(|a| format!(" ({})", a))
                                    .unwrap_or_default(),
                            );
                        }
                    }
                    upgraded.or(metadata)
                } else {
                    metadata
                }
            } else {
                metadata
            }
        } else {
            metadata
        }
    } else {
        metadata
    };

    // 6. Download
    progress_event(events, "download");
    let tmp_dir = std::env::temp_dir().join("needle").join(&selected.id);
    let plan = download::DownloadPlan {
        provider: selected.provider.clone(),
        id: selected.id.clone(),
        url: selected.url.clone(),
        title: selected.title.clone(),
        target_format: "best".into(),
        output_dir: tmp_dir.clone(),
    };

    let pb = spinner("Downloading audio...");
    let downloaded = download::download_audio(toolchain.yt_dlp_path.to_str().unwrap(), &plan)?;
    pb.finish_and_clear();

    // 7. Convert
    progress_event(events, "convert");
    let ext = req.format.extension();
    let converted = tmp_dir.join(format!("final.{ext}"));
    let pb = spinner("Converting audio...");
    download::convert_audio(
        toolchain.ffmpeg_path.to_str().unwrap(),
        &downloaded,
        &converted,
        req.format.ffmpeg_codec(),
        Some("320k"),
    )?;
    pb.finish_and_clear();

    // 8. Tag
    progress_event(events, "tag");
    let pb = spinner("Writing tags...");
    let remix_variant_conflict = metadata
        .as_ref()
        .is_some_and(|m| requested_variant_conflicts_with_metadata(&req.title, &m.title));
    let tag_metadata = if approved_tags.is_some() {
        metadata.clone()
    } else {
        metadata_for_tagging(metadata.as_ref(), &req.title, req.album.as_deref())
    };
    let approved_artwork_path = if let Some(ref approved) = approved_tags {
        if approved.artwork_url.trim().is_empty() {
            None
        } else {
            Some(download_approved_artwork(&approved.artwork_url).await?)
        }
    } else {
        None
    };
    let fallback_album = if let Some(ref approved) = approved_tags {
        (!approved.album.trim().is_empty()).then(|| approved.album.clone())
    } else if remix_variant_conflict {
        req.album.clone()
    } else {
        tag_metadata
            .as_ref()
            .and_then(|m| m.album.clone())
            .or_else(|| req.album.clone())
            .or_else(|| infer_album_from_source_title(&selected.title))
            .or_else(|| infer_album_from_scored_candidates(&scored))
    };

    // Build canonical title: use metadata title, append (feat. X & Y) if featured_artists present
    let meta_title_raw = tag_metadata.as_ref().map(|m| {
        let base = m.title.clone();
        if m.featured_artists.is_empty() {
            base
        } else {
            let feats = normalize_featured_artists_list_pub(&m.featured_artists);
            format!("{} (feat. {})", base, feats)
        }
    });
    let fallback_title = approved_tags
        .as_ref()
        .map(|tags| tags.title.clone())
        .unwrap_or_else(|| {
            meta_title_raw.unwrap_or_else(|| {
                infer_title_from_source_title(&selected.title, &req.artist)
                    .unwrap_or_else(|| title_case_fallback(&req.title))
            })
        });
    let fallback_artist = approved_tags
        .as_ref()
        .map(|tags| tags.artist.clone())
        .unwrap_or_else(|| {
            tag_metadata
                .as_ref()
                .map(|m| m.artist.clone())
                .unwrap_or_else(|| title_case_fallback(&req.artist))
        });

    let library_artist = canonical_library_artist(tag_metadata.as_ref(), &req.artist);
    let approved_album_artist = approved_tags.as_ref().map(|tags| tags.album_artist.clone());
    let tag_plan = tag::TagPlan {
        title: fallback_title,
        artist: fallback_artist,
        album: fallback_album,
        album_artist: approved_album_artist.or_else(|| Some(library_artist.to_string())),
        track: if approved_tags.is_some() {
            None
        } else {
            tag_metadata.as_ref().and_then(|m| m.track_number)
        },
        disc: if approved_tags.is_some() {
            None
        } else {
            tag_metadata.as_ref().and_then(|m| m.disc_number)
        },
        date: if approved_tags.is_some() {
            None
        } else {
            tag_metadata.as_ref().and_then(|m| m.release_date.clone())
        },
        artwork_path: approved_artwork_path.clone(),
        source_url: Some(selected.url.clone()),
        ..Default::default()
    };
    tag::write_tags(&converted, &tag_plan)?;
    if let Some(path) = approved_artwork_path {
        let _ = std::fs::remove_file(path);
    }
    pb.finish_and_clear();

    // 9. Move to library
    progress_event(events, "save");
    let mut profile = library::OutputProfile::default();
    // The default profile asks interactively, but this command is already past
    // candidate selection. Keep both copies so a repeat download cannot replace
    // an existing recording without an explicit collision strategy.
    if matches!(profile.collision, library::CollisionStrategy::Ask) {
        profile.collision = library::CollisionStrategy::KeepBoth;
    }
    // Keep the library directory and album artist aligned with authoritative metadata.
    // Fall back to the request artist when metadata was unavailable.
    let dir_artist = library_artist;
    let out_path = library::build_output_path(
        &profile,
        dir_artist,
        &tag_plan.title,
        tag_plan.album.as_deref(),
        tag_plan.track,
        ext,
    );
    let Some(out_path) = library::resolve_destination(&out_path, profile.collision)? else {
        if json {
            println!(
                "{}",
                serde_json::to_string(&serde_json::json!({
                    "ok": true,
                    "skipped": true,
                    "saved_path": out_path,
                    "artist": tag_plan.artist,
                    "title": tag_plan.title,
                    "album": tag_plan.album,
                    "source_url": &selected.url,
                }))?
            );
        } else {
            println!(
                "{} skipped existing file: {}",
                style("•").yellow(),
                out_path.display()
            );
        }
        return Ok(());
    };
    if let Some(parent) = out_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::rename(&converted, &out_path)?;

    // 10. Provenance
    let prov = provenance::Provenance {
        requested: provenance::RequestedTrack {
            artist: req.artist,
            title: req.title,
            album: req.album,
        },
        selected_source: provenance::SelectedSource {
            provider: selected.provider.clone(),
            id: selected.id.clone(),
            title: selected.title.clone(),
            duration_ms: selected.duration_ms,
            url: selected.url.clone(),
        },
        scoring: provenance::ScoringRecord {
            confidence: selected_score.confidence,
            reasons: selected_score.positives.clone(),
        },
        metadata: provenance::MetadataRecord {
            provider: metadata
                .as_ref()
                .map(|m| m.source.provider.clone())
                .unwrap_or_else(|| "none".into()),
            plausibility_score: metadata.as_ref().map(|m| m.source.plausibility_score),
            recording_id: metadata
                .as_ref()
                .and_then(|m| m.source.recording_id.clone()),
            resolved_artist: metadata.as_ref().map(|m| m.artist.clone()),
            resolved_title: metadata.as_ref().map(|m| m.title.clone()),
            resolved_album: metadata.as_ref().and_then(|m| m.album.clone()),
            featured_artists: metadata
                .as_ref()
                .map(|m| m.featured_artists.clone())
                .unwrap_or_default(),
            re_queried: meta_re_queried,
            canonical_url: metadata
                .as_ref()
                .and_then(|m| m.source.canonical_url.clone()),
        },
        created_by: "needle 0.1.0".into(),
    };
    let prov_path = out_path.with_extension("json");
    prov.write(&prov_path)?;

    if json {
        println!(
            "{}",
            serde_json::to_string(&serde_json::json!({
                "ok": true,
                "saved_path": out_path,
                "artist": tag_plan.artist,
                "title": tag_plan.title,
                "album": tag_plan.album,
                "source_url": &selected.url,
            }))?
        );
    } else {
        println!("\n{} Saved: {}", style("✓").green(), out_path.display());
    }

    Ok(())
}

struct SearchOptions {
    artist: String,
    title: String,
    album: Option<String>,
    url: Option<String>,
    no_metadata: bool,
    duration_override: Option<String>,
    source: String,
    json: bool,
}

async fn cmd_search(options: SearchOptions) -> Result<()> {
    let SearchOptions {
        artist,
        title,
        album,
        url,
        no_metadata,
        duration_override,
        source,
        json,
    } = options;
    use needle_core::*;

    let toolchain = Toolchain::discover()?;
    let req = ParsedRequest {
        artist: artist.clone(),
        title: title.clone(),
        album,
        url,
        format: request::OutputFormat::Mp3,
        profile: "default".into(),
    };

    let metadata = if no_metadata {
        None
    } else {
        let resolved = metadata::resolve_metadata(&req.artist, &req.title).await?;
        filter_compatible_metadata(resolved, &req.artist, &req.title)
    };
    let queries = search::build_queries(&req.artist, &req.title, req.album.as_deref());
    let candidates = resolve_requested_candidates(
        toolchain.yt_dlp_path.to_str().unwrap(),
        &queries,
        parse_source(&source)?,
        req.url.as_deref(),
    )?;

    let req_norm = normalize::normalize_title(&req.title);
    let consensus_dur = score::infer_consensus_duration_ms(&req.artist, &req_norm, &candidates);
    let expected_dur = choose_expected_duration(
        parse_duration_override(duration_override.as_deref())?,
        metadata.as_ref().and_then(|m| m.duration_ms),
        consensus_dur,
    );
    let config = score::ScorerConfig::default();

    let mut scored: Vec<(search::Candidate, score::CandidateScore)> = candidates
        .into_iter()
        .map(|c| {
            let s = score::score_candidate(&req.artist, &req_norm, &c, expected_dur, &config);
            (c, s)
        })
        .collect();

    scored.sort_by_key(|a| std::cmp::Reverse(a.1.confidence));
    if json {
        println!(
            "{}",
            serde_json::to_string(&search_json_response(&req, metadata.as_ref(), &scored))?
        );
    } else {
        display_candidates(&scored, &req, metadata.as_ref(), expected_dur);
    }

    Ok(())
}

async fn cmd_doctor(json: bool) -> Result<()> {
    use needle_core::*;

    if json {
        let response = match Toolchain::discover() {
            Ok(tc) => {
                let tools = tc.verify()?;
                let ok = tools.iter().all(|status| status.ok || status.optional);
                serde_json::json!({ "ok": ok, "tools": tools })
            }
            Err(error) => serde_json::json!({
                "ok": false,
                "tools": [{
                    "name": "toolchain",
                    "ok": false,
                    "optional": false,
                    "message": error.to_string(),
                }],
            }),
        };
        println!("{}", serde_json::to_string(&response)?);
        return Ok(());
    }

    println!("{}", style("Needle toolchain check").bold().underlined());
    println!();

    let tc = match Toolchain::discover() {
        Ok(t) => t,
        Err(e) => {
            println!("{} {}", style("✗").red(), e);
            return Ok(());
        }
    };

    for status in tc.verify()? {
        if status.optional && status.path.is_none() {
            println!(
                "{} {:20} {}",
                style("•").yellow(),
                status.name,
                status.message
            );
        } else if status.ok {
            println!(
                "{} {:20} {}",
                style("✓").green(),
                status.name,
                status.message
            );
        } else {
            println!("{} {:20} {}", style("✗").red(), status.name, status.message);
        }
    }

    Ok(())
}

// ─── Display helpers ──────────────────────────────────────────────────────────

fn search_json_response(
    req: &needle_core::ParsedRequest,
    metadata: Option<&needle_core::TrackMetadata>,
    scored: &[(
        needle_core::search::Candidate,
        needle_core::score::CandidateScore,
    )],
) -> serde_json::Value {
    let candidates: Vec<_> = scored
        .iter()
        .map(|(candidate, score)| serde_json::json!({ "candidate": candidate, "score": score }))
        .collect();
    serde_json::json!({
        "ok": true,
        "request": {
            "artist": req.artist,
            "title": req.title,
            "album": req.album,
        },
        "metadata": metadata,
        "candidates": candidates,
    })
}

fn display_candidates(
    scored: &[(
        needle_core::search::Candidate,
        needle_core::score::CandidateScore,
    )],
    req: &needle_core::ParsedRequest,
    metadata: Option<&needle_core::TrackMetadata>,
    expected_duration_ms: Option<u64>,
) {
    println!(
        "Requested: {} — {}",
        style(&req.artist).bold(),
        style(&req.title).bold()
    );
    if let Some(dur) = expected_duration_ms {
        println!("Expected duration: {}", fmt_duration(dur));
    } else if let Some(m) = metadata {
        if let Some(dur) = m.duration_ms {
            println!("Expected duration: {}", fmt_duration(dur));
        }
    }
    println!();

    let groups = [
        ("Recommended", needle_core::score::ScoreStatus::Recommended),
        ("Uncertain", needle_core::score::ScoreStatus::Uncertain),
        ("Rejected", needle_core::score::ScoreStatus::Rejected),
    ];

    for (label, status) in groups {
        let group: Vec<_> = scored
            .iter()
            .enumerate()
            .filter(|(_, (_, s))| s.status == status)
            .collect();
        if group.is_empty() {
            continue;
        }

        println!("{}", style(label).bold().underlined());
        for (i, (cand, score)) in group {
            let dur = cand
                .duration_ms
                .map(fmt_duration)
                .unwrap_or_else(|| "??:??".into());
            let up = cand.uploader.as_deref().unwrap_or("unknown");
            let conf = style(format!("{:3}", score.confidence));
            let conf_styled = match status {
                needle_core::score::ScoreStatus::Recommended => conf.green(),
                needle_core::score::ScoreStatus::Uncertain => conf.yellow(),
                needle_core::score::ScoreStatus::Rejected => conf.red(),
            };

            println!(
                "  [{}] {}%  {}",
                i + 1,
                conf_styled,
                style(&cand.title).bold()
            );
            let quality = cand.source_quality_label();
            if let Some(quality) = quality {
                println!(
                    "      {} · {} · {} · {}",
                    dur,
                    style(&cand.provider).dim(),
                    style(up).dim(),
                    style(quality).dim()
                );
            } else {
                println!(
                    "      {} · {} · {}",
                    dur,
                    style(&cand.provider).dim(),
                    style(up).dim()
                );
            }
            for p in &score.positives {
                println!("      {} {}", style("+").green(), p);
            }
            for w in &score.warnings {
                println!("      {} {}", style("-").yellow(), w);
            }
            for r in &score.rejects {
                println!("      {} {}", style("×").red(), r);
            }
            println!();
        }
    }
}

fn select_candidate(
    scored: &[(
        needle_core::search::Candidate,
        needle_core::score::CandidateScore,
    )],
    direct_url_provided: bool,
) -> Result<usize> {
    use dialoguer::Input;

    let valid: Vec<usize> = scored
        .iter()
        .enumerate()
        .filter(|(_, (_, s))| s.status != needle_core::score::ScoreStatus::Rejected)
        .map(|(i, _)| i)
        .collect();

    if valid.is_empty() {
        if direct_url_provided && !scored.is_empty() {
            // User explicitly selected this source (e.g. via the browser extension);
            // scoring heuristics are advisory only in that case, never a hard blocker.
            eprintln!(
                "{} Scorer flagged the requested URL as a mismatch, but proceeding anyway since a source URL was explicitly provided.",
                style("⚠").yellow(),
            );
            return Ok(0);
        }
        bail!("all candidates were rejected");
    }

    let idx: usize = Input::new()
        .with_prompt("Choose candidate")
        .validate_with(|input: &String| -> Result<(), String> {
            let n: usize = input.parse().map_err(|_| "enter a number".to_string())?;
            if n == 0 || n > scored.len() {
                Err("invalid candidate number".to_string())
            } else if scored[n - 1].1.status == needle_core::score::ScoreStatus::Rejected {
                Err("that candidate was rejected".to_string())
            } else {
                Ok(())
            }
        })
        .interact_text()
        .map_err(|e| anyhow::anyhow!("{e}"))?
        .parse::<usize>()
        .map_err(|_| anyhow::anyhow!("invalid number"))?;

    Ok(idx - 1)
}

fn auto_select_candidate(
    scored: &[(
        needle_core::search::Candidate,
        needle_core::score::CandidateScore,
    )],
    direct_url_provided: bool,
    quiet: bool,
) -> Result<usize> {
    let Some((idx, (candidate, score))) = scored
        .iter()
        .enumerate()
        .find(|(_, (_, s))| s.status != needle_core::score::ScoreStatus::Rejected)
    else {
        if direct_url_provided {
            if let Some((candidate, score)) = scored.first() {
                // User explicitly selected this source (e.g. via the browser extension);
                // scoring heuristics are advisory only in that case, never a hard blocker.
                eprintln!(
                    "{} Scorer flagged the requested URL as a mismatch ({}% confidence), but proceeding anyway since a source URL was explicitly provided.",
                    style("⚠").yellow(),
                    score.confidence,
                );
                if !quiet {
                    println!(
                        "{} Using explicitly requested source: {}",
                        style("✓").green(),
                        style(&candidate.title).bold(),
                    );
                }
                return Ok(0);
            }
        }
        bail!("all candidates were rejected");
    };

    if !quiet {
        println!(
            "{} Auto-accepted [{}] {}% {}",
            style("✓").green(),
            idx + 1,
            score.confidence,
            style(&candidate.title).bold(),
        );
    }

    Ok(idx)
}

fn guard_selected_candidate(
    strict: bool,
    score: &needle_core::score::CandidateScore,
) -> Result<()> {
    if strict && score.status == needle_core::score::ScoreStatus::Rejected {
        let reasons = if score.rejects.is_empty() {
            "no rejection reason provided".to_string()
        } else {
            score.rejects.join("; ")
        };
        bail!("selected candidate was rejected in strict mode: {reasons}");
    }
    Ok(())
}

fn spinner(msg: &str) -> ProgressBar {
    let pb = ProgressBar::new_spinner();
    pb.set_style(
        ProgressStyle::default_spinner()
            .template("{spinner:.green} {msg}")
            .unwrap(),
    );
    pb.set_message(msg.to_string());
    pb.enable_steady_tick(Duration::from_millis(100));
    pb
}

fn progress_event(enabled: bool, stage: &str) {
    if enabled {
        eprintln!(
            "{}",
            serde_json::json!({ "event": "progress", "stage": stage })
        );
    }
}

fn fmt_duration(ms: u64) -> String {
    let total_sec = ms / 1000;
    let m = total_sec / 60;
    let s = total_sec % 60;
    format!("{}:{:02}", m, s)
}

fn parse_duration_override(value: Option<&str>) -> Result<Option<u64>> {
    let Some(value) = value else {
        return Ok(None);
    };
    let value = value.trim();
    if value.is_empty() {
        return Ok(None);
    }

    let seconds = if let Some((minutes, seconds)) = value.split_once(':') {
        let minutes: u64 = minutes.parse()?;
        let seconds: u64 = seconds.parse()?;
        minutes * 60 + seconds
    } else {
        value.parse::<u64>()?
    };

    Ok(Some(seconds * 1000))
}

fn choose_expected_duration(
    override_duration: Option<u64>,
    metadata_duration: Option<u64>,
    consensus_duration: Option<u64>,
) -> Option<u64> {
    if override_duration.is_some() {
        return override_duration;
    }

    match (metadata_duration, consensus_duration) {
        (Some(metadata), Some(consensus)) => {
            let delta = metadata.abs_diff(consensus);
            if delta > 30_000 {
                Some(consensus)
            } else {
                Some(metadata)
            }
        }
        (None, Some(consensus)) => Some(consensus),
        (Some(metadata), None) => Some(metadata),
        (None, None) => None,
    }
}

fn canonical_library_artist<'a>(
    metadata: Option<&'a needle_core::TrackMetadata>,
    requested_artist: &'a str,
) -> &'a str {
    metadata
        .map(|m| m.artist.as_str())
        .unwrap_or(requested_artist)
}

fn requested_variant_conflicts_with_metadata(request_title: &str, metadata_title: &str) -> bool {
    has_mix_variant(request_title)
        && normalize_for_metadata_match(request_title)
            != normalize_for_metadata_match(metadata_title)
}

fn metadata_variant_warning(request_title: &str, metadata_title: &str) -> Option<&'static str> {
    requested_variant_conflicts_with_metadata(request_title, metadata_title).then_some(
        "This suggestion appears to describe the original release, not the current remix or variant. Review the title and album before applying it.",
    )
}

fn has_mix_variant(value: &str) -> bool {
    normalize_for_metadata_match(value)
        .split_whitespace()
        .any(|word| word == "mix" || word == "remix" || word.ends_with("mix"))
}

fn metadata_for_tagging(
    metadata: Option<&needle_core::TrackMetadata>,
    request_title: &str,
    request_album: Option<&str>,
) -> Option<needle_core::TrackMetadata> {
    let mut metadata = metadata?.clone();
    if requested_variant_conflicts_with_metadata(request_title, &metadata.title) {
        metadata.title = clean_title_fragment(request_title);
        metadata.album = request_album.map(str::to_owned);
        metadata.track_number = None;
        metadata.disc_number = None;
        metadata.release_date = None;
    }
    Some(metadata)
}

fn filter_compatible_metadata(
    metadata: Option<needle_core::TrackMetadata>,
    request_artist: &str,
    request_title: &str,
) -> Option<needle_core::TrackMetadata> {
    let metadata = metadata?;
    let primary_artist_ok = contains_or_close(&metadata.artist, request_artist, 0.86);
    let featured_artist_ok = metadata
        .featured_artists
        .iter()
        .any(|artist| contains_or_close(artist, request_artist, 0.86));
    let artist_ok = primary_artist_ok || featured_artist_ok;
    let title_ok = contains_or_close(&metadata.title, request_title, 0.90)
        || contains_or_close(
            &normalize_for_metadata_match(&metadata.title),
            &normalize_for_metadata_match(request_title),
            0.90,
        );

    if artist_ok && title_ok {
        Some(metadata)
    } else {
        eprintln!(
            "{} Ignoring mismatched metadata: {} — {}",
            style("⚠").yellow(),
            metadata.artist,
            metadata.title,
        );
        None
    }
}

fn contains_or_close(a: &str, b: &str, threshold: f64) -> bool {
    let a = normalize_for_metadata_match(a);
    let b = normalize_for_metadata_match(b);
    a.contains(&b) || b.contains(&a) || jaro_winkler(&a, &b) >= threshold
}

fn normalize_for_metadata_match(value: &str) -> String {
    value
        .to_ascii_lowercase()
        .replace('&', "and")
        .replace("pt.", "part")
        .replace("pt ", "part ")
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || c.is_ascii_whitespace())
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn infer_album_from_source_title(source_title: &str) -> Option<String> {
    let mut candidates = Vec::new();
    collect_bracketed_segments(source_title, '(', ')', &mut candidates);
    collect_bracketed_segments(source_title, '[', ']', &mut candidates);

    candidates
        .into_iter()
        .map(|s| s.trim().to_string())
        .find(|s| is_likely_album_hint(s))
}

fn infer_album_from_scored_candidates(
    scored: &[(
        needle_core::search::Candidate,
        needle_core::score::CandidateScore,
    )],
) -> Option<String> {
    let mut counts = std::collections::BTreeMap::<String, usize>::new();
    for (candidate, score) in scored {
        if score.status == needle_core::score::ScoreStatus::Rejected {
            continue;
        }
        if let Some(album) = infer_album_from_source_title(&candidate.title) {
            *counts.entry(album).or_default() += 1;
        }
    }

    // Require at least 2 votes — single noisy candidate not trustworthy
    counts
        .into_iter()
        .filter(|(_, count)| *count >= 2)
        .max_by_key(|(_, count)| *count)
        .map(|(album, _)| album)
}

fn infer_title_from_source_title(source_title: &str, request_artist: &str) -> Option<String> {
    let cleaned = strip_bracketed_noise(source_title);
    let parts: Vec<_> = cleaned
        .split(" - ")
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .collect();
    if parts.len() >= 2 {
        let req_artist_norm = normalize_for_metadata_match(request_artist);
        let first_norm = normalize_for_metadata_match(parts[0]);
        let last_norm = normalize_for_metadata_match(parts[parts.len() - 1]);

        if first_norm.contains(&req_artist_norm) || req_artist_norm.contains(&first_norm) {
            return Some(clean_title_fragment(&parts[1..].join(" - ")));
        }
        if last_norm.contains(&req_artist_norm) || req_artist_norm.contains(&last_norm) {
            if parts[parts.len() - 1].to_ascii_lowercase().contains("feat") {
                return Some(clean_title_fragment(parts[parts.len() - 1]));
            }
            return Some(clean_title_fragment(&parts[..parts.len() - 1].join(" - ")));
        }

        // A requested featured artist may only appear in the source suffix,
        // while the primary artist owns the first dash-separated segment.
        // In that case the middle segment is still the unambiguous title.
        let source_norm = normalize_for_metadata_match(source_title);
        if source_title.to_ascii_lowercase().contains("feat")
            && source_norm.contains(&req_artist_norm)
            && parts.len() == 2
        {
            return Some(clean_title_fragment(parts[1]));
        }
    }

    // No dash separator — can't reliably split artist from title; return None
    None
}

fn strip_bracketed_noise(source_title: &str) -> String {
    let mut out = source_title.to_string();
    // Also strip curly-brace segments (common in SoundCloud tags like {#!.!.!#})
    for (open, close) in [('(', ')'), ('[', ']'), ('{', '}')] {
        while let Some(start) = out.find(open) {
            let Some(end_rel) = out[start + open.len_utf8()..].find(close) else {
                break;
            };
            let end = start + open.len_utf8() + end_rel;
            let segment = &out[start + open.len_utf8()..end];
            if is_likely_album_hint(segment) || is_title_noise(segment) {
                out.replace_range(start..=end, "");
            } else {
                break;
            }
        }
    }
    out.trim().to_string()
}

fn clean_title_fragment(value: &str) -> String {
    let mut title = value.trim().to_string();
    // Strip phrase-level noise first (order matters: longer phrases before subwords)
    let phrase_markers = [
        "with lyrics!",
        "with lyrics",
        "w/ lyrics",
        "▼download▼",
        "download",
        "lyric video",
        "lyrics",
        "lyric",
        "official audio",
        "official video",
        "official music video",
        "audio only",
    ];
    for marker in phrase_markers {
        title = remove_case_insensitive(&title, marker);
    }
    // Phrase removal above can leave an empty "()"/"[]" behind, e.g.
    // "Song (Official Music Video)" becomes "Song ()". Collapse those
    // before any further cleanup runs.
    title = collapse_empty_brackets(&title);
    // A trailing "| Channel Name" is an uploader attribution suffix on
    // YouTube, never part of the actual track title.
    if let Some(pos) = title.find(" | ") {
        title.truncate(pos);
    }
    // Normalize feat syntax including (Ft. X) / (feat X) inside parens
    let title = normalize_feat_in_parens(&title);
    let title = normalize_feat_syntax(&title);
    // Strip trailing junk punctuation left by removals
    let title = title.trim_end_matches(['!', ',', '.', '-', '/']);
    title
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .trim_matches('-')
        .trim()
        .to_string()
}

/// Remove bracket pairs that are empty (or whitespace-only) after other
/// noise-phrase removal has hollowed them out.
fn collapse_empty_brackets(value: &str) -> String {
    let mut out = value.to_string();
    let pairs = [('(', ')'), ('[', ']'), ('{', '}')];
    loop {
        let mut changed = false;
        for (open, close) in pairs {
            let mut search_from = 0;
            while let Some(rel_start) = out[search_from..].find(open) {
                let start = search_from + rel_start;
                let Some(rel_end) = out[start + open.len_utf8()..].find(close) else {
                    break;
                };
                let end = start + open.len_utf8() + rel_end;
                let segment = &out[start + open.len_utf8()..end];
                if segment.trim().is_empty() {
                    out.replace_range(start..=end, "");
                    changed = true;
                    break;
                } else {
                    search_from = end + close.len_utf8();
                }
            }
            if changed {
                break;
            }
        }
        if !changed {
            break;
        }
    }
    out
}

/// Handles feat inside existing parens: "(Ft. Young Jeezy)" → "(feat. Young Jeezy)"
fn normalize_feat_in_parens(value: &str) -> String {
    let lower = value.to_ascii_lowercase();
    // Find "(ft." or "(feat" or "(featuring" patterns
    let paren_variants = [
        "(featuring ",
        "(featured ",
        "(feat. ",
        "(feat ",
        "(ft. ",
        "(ft ",
    ];
    for variant in paren_variants {
        if let Some(pos) = lower.find(variant) {
            let after_start = pos + variant.len();
            // find closing paren
            if let Some(close_rel) = value[after_start..].find(')') {
                let artists_raw = value[after_start..after_start + close_rel].trim();
                let artists = normalize_featured_artists_list(artists_raw);
                let before = &value[..pos];
                let after = &value[after_start + close_rel + 1..];
                return format!("{}(feat. {}){}", before, artists, after);
            }
        }
    }
    value.to_string()
}

fn normalize_feat_syntax(value: &str) -> String {
    // Regex-free replacement: find feat/ft/featuring variant and normalize to (feat. ...)
    // Patterns to match (case-insensitive, must be word boundary before):
    //   " ft. ", " ft ", " feat ", " feat. ", " featuring ", " Feat. ", etc.
    let lower = value.to_ascii_lowercase();

    let variants = [
        " featuring ",
        " featured ",
        " feat ",
        " feat. ",
        " ft. ",
        " ft ",
    ];
    for variant in variants {
        if let Some(pos) = lower.find(variant) {
            let before = value[..pos].trim_end().to_string();
            let after_raw = value[pos + variant.len()..].trim_start().to_string();
            let after = strip_trailing_paren_if_unmatched(&after_raw);
            let after_normalized = normalize_featured_artists_list(after.trim());
            return format!("{} (feat. {})", before, after_normalized);
        }
    }

    value.to_string()
}

fn normalize_featured_artists_list_pub(artists: &[String]) -> String {
    // Join Vec<String> and apply same Oxford-& normalization
    normalize_featured_artists_list(&artists.join(", "))
}

fn normalize_featured_artists_list(artists: &str) -> String {
    // "Ab-Soul, Punch" → "Ab-Soul & Punch"
    // "Ab-Soul, Punch, Jay Rock" → "Ab-Soul, Punch & Jay Rock"
    // "Ab-Soul and Punch" → "Ab-Soul & Punch"
    // Single artist: unchanged
    let normalized = artists.replace(" and ", ", ").replace(" & ", ", ");
    let parts: Vec<&str> = normalized
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .collect();
    match parts.len() {
        0 => artists.to_string(),
        1 => parts[0].to_string(),
        _ => {
            let (last, rest) = parts.split_last().unwrap();
            format!("{} & {}", rest.join(", "), last)
        }
    }
}

fn strip_trailing_paren_if_unmatched(value: &str) -> String {
    // If input was "Ab-Soul, Punch)" from stripping "(feat." bracket, drop the trailing )
    if value.ends_with(')') && !value.contains('(') {
        value[..value.len() - 1].trim_end().to_string()
    } else {
        value.to_string()
    }
}

fn is_title_noise(value: &str) -> bool {
    let normalized = value.trim().to_ascii_lowercase();
    // Exact matches
    if [
        "lyrics",
        "lyric",
        "official audio",
        "official video",
        "audio",
        "video",
        "hq",
        "hd",
        "clean",
        "explicit",
    ]
    .iter()
    .any(|marker| normalized == *marker)
    {
        return true;
    }
    // Suffix patterns: anything ending in "mix" or "remix" is a remix variant, not the track
    if normalized.ends_with("mix") || normalized.ends_with("remix") {
        return true;
    }
    // Compound bracket phrases composed entirely of noise words, e.g.
    // "Music Video", "Official Music Video", "Audio HQ", "HD Video", etc.
    let words: Vec<&str> = normalized.split_whitespace().collect();
    if words.len() >= 2
        && words.iter().all(|w| {
            [
                "official", "audio", "video", "music", "lyrics", "lyric", "hq", "hd", "clean",
                "explicit",
            ]
            .contains(w)
        })
    {
        return true;
    }
    false
}

fn remove_case_insensitive(value: &str, needle: &str) -> String {
    let lower = value.to_ascii_lowercase();
    if let Some(pos) = lower.find(needle) {
        let end = pos + needle.len();
        let mut out = value.to_string();
        out.replace_range(pos..end, "");
        out
    } else {
        value.to_string()
    }
}

fn title_case_fallback(value: &str) -> String {
    value
        .split_whitespace()
        .map(|word| {
            let lower = word.to_ascii_lowercase();
            if word.contains('$') {
                word.to_string()
            } else if matches!(lower.as_str(), "ft" | "feat" | "and" | "of" | "the") {
                lower
            } else {
                let mut chars = lower.chars();
                match chars.next() {
                    Some(first) => format!("{}{}", first.to_ascii_uppercase(), chars.as_str()),
                    None => String::new(),
                }
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn collect_bracketed_segments(input: &str, open: char, close: char, out: &mut Vec<String>) {
    let mut rest = input;
    while let Some(start) = rest.find(open) {
        let after_open = &rest[start + open.len_utf8()..];
        let Some(end) = after_open.find(close) else {
            break;
        };
        out.push(after_open[..end].to_string());
        rest = &after_open[end + close.len_utf8()..];
    }
}

fn is_likely_album_hint(value: &str) -> bool {
    let normalized = value.trim().to_ascii_lowercase();
    if normalized.is_empty() || normalized.len() > 60 {
        return false;
    }
    // Upload-quality labels are not release titles.
    if matches!(normalized.as_str(), "cdq" | "cd quality" | "quality") {
        return false;
    }
    // Reject if contains special chars typical of SoundCloud junk tags or emoji separators
    if value
        .chars()
        .any(|c| matches!(c, '#' | '!' | '{' | '}' | '|' | '~' | '@'))
    {
        return false;
    }

    let junk = [
        "official",
        "audio",
        "lyrics",
        "lyric",
        "video",
        "hq",
        "hd",
        "clean",
        "explicit",
        "feat",
        "ft",
        "featuring",
        "prod",
        "remix",
        "mix",
        "download",
        // Descriptive suffixes that appear in YouTube titles but never in real album names
        "song",
        "music",
        "track",
        "freestyle",
        "edit",
        "cover",
        "live",
        "leak",
        "reaction",
        "interview",
        "snippet",
        "session",
        "performance",
        "visualizer",
        "slowed",
        "reverb",
        "chopped",
        "sped up",
        "bass boosted",
    ];
    !junk.iter().any(|marker| normalized.contains(marker))
}

fn parse_format(s: &str) -> needle_core::request::OutputFormat {
    match s.to_ascii_lowercase().as_str() {
        "mp3" => needle_core::request::OutputFormat::Mp3,
        "m4a" | "aac" => needle_core::request::OutputFormat::M4a,
        "opus" => needle_core::request::OutputFormat::Opus,
        "flac" => needle_core::request::OutputFormat::Flac,
        _ => needle_core::request::OutputFormat::Mp3,
    }
}

fn parse_source(s: &str) -> Result<needle_core::search::SearchSource> {
    match s.to_ascii_lowercase().as_str() {
        "auto" => Ok(needle_core::search::SearchSource::Auto),
        "youtube" | "yt" => Ok(needle_core::search::SearchSource::Youtube),
        "soundcloud" | "sc" => Ok(needle_core::search::SearchSource::Soundcloud),
        other => bail!("unknown source '{other}' (expected auto, youtube, or soundcloud)"),
    }
}

fn resolve_requested_candidates(
    yt_dlp_path: &str,
    queries: &[needle_core::search::SearchQuery],
    source: needle_core::search::SearchSource,
    direct_url: Option<&str>,
) -> Result<Vec<needle_core::search::Candidate>> {
    if let Some(url) = direct_url {
        return needle_core::search::resolve_url(yt_dlp_path, url)?
            .map(|candidate| vec![candidate])
            .ok_or_else(|| {
                anyhow::anyhow!("selected URL did not resolve to a supported audio source")
            });
    }

    needle_core::search::search_sources(yt_dlp_path, queries, 10, source)
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    #[test]
    fn structured_cli_flags_parse_without_changing_defaults() {
        let cli = Cli::try_parse_from(["needle", "search", "Artist", "Title", "--json"]).unwrap();
        match cli.command {
            Commands::Search {
                artist,
                title,
                album,
                url,
                no_metadata,
                duration_override,
                source,
                json,
            } => {
                assert_eq!(artist, "Artist");
                assert_eq!(title, "Title");
                assert!(album.is_none());
                assert!(url.is_none());
                assert!(!no_metadata);
                assert!(duration_override.is_none());
                assert_eq!(source, "auto");
                assert!(json);
            }
            _ => panic!("expected search command"),
        }

        let cli = Cli::try_parse_from(["needle", "get", "Artist", "Title", "--events"]).unwrap();
        match cli.command {
            Commands::Get {
                json,
                events,
                source,
                ..
            } => {
                assert!(!json);
                assert!(events);
                assert_eq!(source, "auto");
            }
            _ => panic!("expected get command"),
        }

        let cli = Cli::try_parse_from(["needle", "doctor", "--json"]).unwrap();
        assert!(matches!(cli.command, Commands::Doctor { json: true }));
        let cli = Cli::try_parse_from(["needle", "discover", "Artist", "--json"]).unwrap();
        assert!(matches!(cli.command, Commands::Discover { json: true, .. }));
    }

    #[test]
    fn identify_url_only_splits_a_title_when_uploader_agrees() {
        let candidate = needle_core::Candidate {
            provider: "soundcloud".into(),
            id: "1".into(),
            url: "https://soundcloud.test/1".into(),
            title: "Whethan - Nissan Altima (Whethan Remix)".into(),
            uploader: Some("Whethan".into()),
            channel_is_verified: None,
            duration_ms: None,
            thumbnail_url: None,
            view_count: None,
            audio_codec: None,
            audio_bitrate_kbps: None,
            query_origin: "canonical".into(),
        };
        assert_eq!(
            identify_candidate(&candidate),
            (
                "Whethan".into(),
                "Nissan Altima (Whethan Remix)".into(),
                false
            )
        );
    }

    #[test]
    fn identify_url_marks_untrusted_title_shape_uncertain() {
        let candidate = needle_core::Candidate {
            provider: "soundcloud".into(),
            id: "1".into(),
            url: "https://soundcloud.test/1".into(),
            title: "Nissan Altima (Whethan Remix)".into(),
            uploader: Some("Whethan".into()),
            channel_is_verified: None,
            duration_ms: None,
            thumbnail_url: None,
            view_count: None,
            audio_codec: None,
            audio_bitrate_kbps: None,
            query_origin: "canonical".into(),
        };
        assert!(identify_candidate(&candidate).2);
    }

    #[test]
    fn identify_url_uses_artist_prefix_when_the_remixer_uploaded_it() {
        let candidate = needle_core::Candidate {
            provider: "soundcloud".into(),
            id: "1".into(),
            url: "https://soundcloud.test/1".into(),
            title: "Doechii - Nissan Altima (Whethan Remix)".into(),
            uploader: Some("Whethan".into()),
            channel_is_verified: None,
            duration_ms: None,
            thumbnail_url: None,
            view_count: None,
            audio_codec: None,
            audio_bitrate_kbps: None,
            query_origin: "canonical".into(),
        };
        assert_eq!(
            identify_candidate(&candidate),
            (
                "Doechii".into(),
                "Nissan Altima (Whethan Remix)".into(),
                true
            )
        );
    }

    #[test]
    fn search_json_response_preserves_candidate_url_and_shape() {
        let req = needle_core::ParsedRequest {
            artist: "Artist".into(),
            title: "Title".into(),
            album: None,
            url: Some("https://example.test/selected".into()),
            format: needle_core::request::OutputFormat::Mp3,
            profile: "default".into(),
        };
        let (candidate, score) = rejected_candidate();
        let response = search_json_response(&req, None, &[(candidate, score)]);
        assert_eq!(response["ok"], true);
        assert_eq!(response["request"]["artist"], "Artist");
        assert!(response["metadata"].is_null());
        assert_eq!(
            response["candidates"][0]["candidate"]["url"],
            "https://example.test/abc"
        );
        assert_eq!(response["candidates"][0]["score"]["status"], "rejected");
    }

    #[test]
    fn strict_mode_rejects_scored_candidate_but_default_preserves_legacy_behavior() {
        let (_, rejected) = rejected_candidate();
        assert!(guard_selected_candidate(false, &rejected).is_ok());
        let error = guard_selected_candidate(true, &rejected)
            .unwrap_err()
            .to_string();
        assert!(error.contains("strict mode"));
        assert!(error.contains("reaction video"));
    }

    #[cfg(unix)]
    #[test]
    fn direct_url_resolution_does_not_run_a_search() {
        use std::os::unix::fs::PermissionsExt;

        let dir = std::env::temp_dir().join(format!("needle-cli-url-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let fake_yt_dlp = dir.join("yt-dlp");
        std::fs::write(
            &fake_yt_dlp,
            r#"#!/bin/sh
case "$1" in
  https://example.test/song)
    printf '%s\n' '{"id":"direct-1","title":"Artist - Song","webpage_url":"https://example.test/song","duration":180,"uploader":"Artist"}'
    ;;
  *)
    echo "search should not run" >&2
    exit 91
    ;;
esac
"#,
        ).unwrap();
        let mut permissions = std::fs::metadata(&fake_yt_dlp).unwrap().permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(&fake_yt_dlp, permissions).unwrap();

        let candidates = resolve_requested_candidates(
            fake_yt_dlp.to_str().unwrap(),
            &needle_core::search::build_queries("Artist", "Song", None),
            needle_core::search::SearchSource::Auto,
            Some("https://example.test/song"),
        )
        .unwrap();

        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].id, "direct-1");
        assert_eq!(candidates[0].url, "https://example.test/song");
        let _ = std::fs::remove_dir_all(dir);
    }
    use needle_core::metadata::TrackMetadata;

    fn metadata(artist: &str, title: &str) -> TrackMetadata {
        TrackMetadata {
            artist: artist.into(),
            featured_artists: vec![],
            title: title.into(),
            album: None,
            duration_ms: Some(224_000),
            release_date: None,
            track_number: None,
            disc_number: None,
            isrc: None,
            artwork_url: None,
            possible_titles: Vec::new(),
            external_ids: Default::default(),
            source: Default::default(),
        }
    }

    #[test]
    fn strips_official_music_video_leaving_no_empty_parens() {
        // Regression: "Song (Official Music Video)" -> "Song ()" was a bug
        assert_eq!(
            clean_title_fragment("H00DBYAIR (Official Music Video)"),
            "H00DBYAIR"
        );
        assert_eq!(
            clean_title_fragment("Rella (Official Music Video)"),
            "Rella"
        );
    }

    #[test]
    fn strips_with_lyrics_and_collapses_empty_parens() {
        // "Chain Heavy (With Lyrics)" -> "Chain Heavy ()" was a bug
        assert_eq!(
            clean_title_fragment("Chain Heavy (With Lyrics)"),
            "Chain Heavy"
        );
    }

    #[test]
    fn strips_audio_hq_bracket_noise() {
        // "[Audio HQ]" should be stripped as noise
        assert_eq!(
            strip_bracketed_noise("Big Pimpin' [Audio HQ]"),
            "Big Pimpin'"
        );
    }

    #[test]
    fn strips_music_video_bracket_noise() {
        // "[Music Video]" should be stripped as noise
        assert_eq!(
            strip_bracketed_noise("Stay With It [Music Video]"),
            "Stay With It"
        );
    }

    #[test]
    fn truncates_pipe_channel_suffix() {
        // "Stay With It | Link Up TV" -> "Stay With It"
        assert_eq!(
            clean_title_fragment("Stay With It | Link Up TV"),
            "Stay With It"
        );
    }

    #[test]
    fn infer_title_from_source_title_handles_official_music_video() {
        // End-to-end: source title with (Official Music Video) should yield clean title
        assert_eq!(
            infer_title_from_source_title(
                "Playboi Carti - H00DBYAIR (Official Music Video)",
                "Playboi Carti"
            ),
            Some("H00DBYAIR".to_string())
        );
        assert_eq!(
            infer_title_from_source_title("OFWGKTA - Rella (Official Music Video)", "OFWGKTA"),
            Some("Rella".to_string())
        );
    }

    #[test]
    fn infer_title_from_source_title_handles_with_lyrics() {
        assert_eq!(
            infer_title_from_source_title(
                "Chain Heavy (With Lyrics) - Kanye West ft Talib Kweli",
                "Kanye West"
            ),
            Some("Chain Heavy".to_string())
        );
    }

    #[test]
    fn infer_title_from_source_title_truncates_pipe_suffix() {
        assert_eq!(
            infer_title_from_source_title("Risky Roadz x Skepta x Suspect x Shailan - Stay With It [Music Video] | Link Up TV", "Skepta"),
            Some("Stay With It".to_string())
        );
    }

    #[test]
    fn uses_authoritative_primary_artist_for_library() {
        let meta = metadata("Theophilus London", "Big Spender");
        assert_eq!(
            canonical_library_artist(Some(&meta), "A$AP ROCKY"),
            "Theophilus London"
        );
        assert_eq!(canonical_library_artist(None, "A$AP ROCKY"), "A$AP ROCKY");
    }

    #[test]
    fn preserves_dollar_style_artist_casing() {
        assert_eq!(title_case_fallback("A$AP ROCKY"), "A$AP Rocky");
    }

    #[test]
    fn rejects_mismatched_metadata_artist() {
        let result = filter_compatible_metadata(
            Some(metadata("NEEDTOBREATHE", "The Heart")),
            "Kendrick Lamar",
            "The Heart Pt. 2",
        );
        assert!(result.is_none());
    }

    #[test]
    fn accepts_compatible_metadata_part_spelling() {
        let result = filter_compatible_metadata(
            Some(metadata("Kendrick Lamar", "The Heart Part 2")),
            "Kendrick Lamar",
            "The Heart Pt. 2",
        );
        assert!(result.is_some());
    }

    #[test]
    fn accepts_metadata_when_request_artist_is_featured() {
        let mut meta = metadata("Theophilus London", "Big Spender");
        meta.featured_artists = vec!["A$AP Rocky".into()];
        let result = filter_compatible_metadata(Some(meta), "A$AP ROCKY", "Big Spender");
        assert!(result.is_some());
    }

    #[test]
    fn preserves_explicit_remix_variant_over_base_metadata() {
        assert!(requested_variant_conflicts_with_metadata(
            "Nissan Altima (Whethan Remix)",
            "Nissan Altima",
        ));
        assert!(!requested_variant_conflicts_with_metadata(
            "Nissan Altima (Whethan Remix)",
            "Nissan Altima (Whethan Remix)",
        ));
        assert!(requested_variant_conflicts_with_metadata(
            "Nissan Altima (Whethan Remix)",
            "Nissan Altima (Skream Remix)",
        ));

        let mut base = metadata("Doechii", "Nissan Altima");
        base.album = Some("Alligator Bites Never Heal Extended".into());
        base.track_number = Some(13);
        base.disc_number = Some(1);
        base.release_date = Some("2024-08-09".into());
        let tagged =
            metadata_for_tagging(Some(&base), "Nissan Altima (Whethan Remix)", None).unwrap();

        assert_eq!(tagged.title, "Nissan Altima (Whethan Remix)");
        assert_eq!(tagged.album, None);
        assert_eq!(tagged.track_number, None);
        assert_eq!(tagged.disc_number, None);
        assert_eq!(tagged.release_date, None);
    }

    #[test]
    fn variant_tagging_preserves_authoritative_featured_artists() {
        let mut base = metadata("Fabolous", "Throw It in the Bag");
        base.featured_artists = vec!["Drake".into()];
        let tagged = metadata_for_tagging(Some(&base), "Throw It in the Bag Remix", None).unwrap();
        assert_eq!(tagged.title, "Throw It in the Bag Remix");
        assert_eq!(tagged.featured_artists, vec!["Drake"]);
    }

    #[test]
    fn approved_tags_round_trip_with_empty_optional_fields() {
        let json = r#"{"artist":"The Weeknd","title":"Wanderlust (Snakehips Remix)","album":"","album_artist":"The Weeknd","artwork_url":"","source_url":"https://youtube.test/watch?v=1"}"#;
        let tags = parse_approved_tags(json).unwrap();
        assert_eq!(tags.album, "");
        assert_eq!(tags.artwork_url, "");
        assert_eq!(approved_tags_metadata(&tags).album, None);
        assert_eq!(approved_tags_metadata(&tags).artwork_url, None);
    }

    #[test]
    fn approved_tags_never_carry_unreviewed_release_fields() {
        let tags = ApprovedTags {
            artist: "Artist".into(),
            title: "Song (Remix)".into(),
            album: "".into(),
            album_artist: "Artist".into(),
            featured_artists: vec![],
            artwork_url: "".into(),
            source_url: "https://youtube.test/watch?v=1".into(),
        };
        let metadata = approved_tags_metadata(&tags);
        assert_eq!(metadata.track_number, None);
        assert_eq!(metadata.disc_number, None);
        assert_eq!(metadata.release_date, None);
        assert_eq!(metadata.title, "Song (Remix)");
    }

    #[test]
    fn preview_preserves_selected_remix_wording() {
        assert_eq!(
            source_title_for_preview("The Weeknd - Wanderlust (Snakehips Remix)", "The Weeknd"),
            "Wanderlust (Snakehips Remix)"
        );
    }

    #[test]
    fn preview_adds_authoritative_featured_artists() {
        assert_eq!(
            preview_title_with_features(
                "Throw It in the Bag".into(),
                "Fabolous - Throw It in the Bag Remix",
                &["Drake".into()]
            ),
            "Throw It in the Bag (feat. Drake)"
        );
        assert_eq!(
            detect_artwork_type(b"\x89PNG\r\n\x1a\nrest"),
            Some(("image/png", "png"))
        );
        assert_eq!(detect_artwork_type(b"RIFFxxxxWEBP"), None);
        assert_eq!(detect_artwork_type(b"not-an-image"), None);
    }

    #[test]
    fn repair_suggestion_warns_when_metadata_drops_variant_marker() {
        let warning = metadata_variant_warning("Nissan Altima (Whethan Remix)", "Nissan Altima");
        assert!(warning.is_some());
        assert!(warning.unwrap().contains("original release"));
        assert!(metadata_variant_warning("Nissan Altima", "Nissan Altima").is_none());
    }

    #[test]
    fn infers_title_for_featured_artist_source_title() {
        assert_eq!(
            infer_title_from_source_title(
                "Theophilus London - Big Spender (feat. A$AP Rocky)",
                "A$AP ROCKY",
            ),
            Some("Big Spender (feat. A$AP Rocky)".to_string()),
        );
    }

    #[test]
    fn rejects_cdq_as_album_hint() {
        assert_eq!(
            infer_album_from_source_title(
                "Theophilus London - Big Spender (feat. A$AP Rocky) (CDQ)",
            ),
            None,
        );
    }

    #[test]
    fn infers_album_from_selected_source_title() {
        assert_eq!(
            infer_album_from_source_title(
                "West Coast Wu-Tang ft. Punch and Ab-Soul - Kendrick Lamar (C4)"
            ),
            Some("C4".to_string()),
        );
    }

    #[test]
    fn ignores_non_album_bracket_markers() {
        assert_eq!(
            infer_album_from_source_title("Kendrick Lamar - West Coast Wu-Tang (Lyrics)"),
            None,
        );
    }

    #[test]
    fn infers_album_from_other_ranked_candidates() {
        let scored = vec![
            (
                needle_core::search::Candidate {
                    provider: "youtube".into(),
                    id: "1".into(),
                    url: "https://example.test/1".into(),
                    title: "Kendrick Lamar - West Coast Wu-Tang Ft. Ab-Soul, Punch (Lyrics)".into(),
                    uploader: None,
                    channel_is_verified: None,
                    duration_ms: None,
                    thumbnail_url: None,
                    view_count: None,
                    audio_codec: None,
                    audio_bitrate_kbps: None,
                    query_origin: "test".into(),
                },
                needle_core::score::CandidateScore {
                    confidence: 85,
                    status: needle_core::score::ScoreStatus::Recommended,
                    positives: Vec::new(),
                    warnings: Vec::new(),
                    rejects: Vec::new(),
                },
            ),
            (
                needle_core::search::Candidate {
                    provider: "youtube".into(),
                    id: "2".into(),
                    url: "https://example.test/2".into(),
                    title: "West Coast Wu-Tang ft. Punch and Ab-Soul - Kendrick Lamar (C4)".into(),
                    uploader: None,
                    channel_is_verified: None,
                    duration_ms: None,
                    thumbnail_url: None,
                    view_count: None,
                    audio_codec: None,
                    audio_bitrate_kbps: None,
                    query_origin: "test".into(),
                },
                needle_core::score::CandidateScore {
                    confidence: 85,
                    status: needle_core::score::ScoreStatus::Recommended,
                    positives: Vec::new(),
                    warnings: Vec::new(),
                    rejects: Vec::new(),
                },
            ),
            (
                needle_core::search::Candidate {
                    provider: "youtube".into(),
                    id: "3".into(),
                    url: "https://example.test/3".into(),
                    title: "Kendrick Lamar - West Coast Wu-Tang (C4)".into(),
                    uploader: None,
                    channel_is_verified: None,
                    duration_ms: None,
                    thumbnail_url: None,
                    view_count: None,
                    audio_codec: None,
                    audio_bitrate_kbps: None,
                    query_origin: "test".into(),
                },
                needle_core::score::CandidateScore {
                    confidence: 80,
                    status: needle_core::score::ScoreStatus::Recommended,
                    positives: Vec::new(),
                    warnings: Vec::new(),
                    rejects: Vec::new(),
                },
            ),
        ];

        assert_eq!(
            infer_album_from_scored_candidates(&scored),
            Some("C4".to_string())
        );
    }

    #[test]
    fn infers_clean_title_from_artist_first_source_title() {
        assert_eq!(
            infer_title_from_source_title(
                "Kendrick Lamar - West Coast Wu-Tang Ft. Ab-Soul, Punch (Lyrics)",
                "kendrick"
            ),
            Some("West Coast Wu-Tang (feat. Ab-Soul & Punch)".to_string()),
        );
    }

    #[test]
    fn infers_clean_title_from_artist_last_source_title() {
        assert_eq!(
            infer_title_from_source_title(
                "West Coast Wu-Tang ft. Punch and Ab-Soul - Kendrick Lamar (C4)",
                "kendrick"
            ),
            Some("West Coast Wu-Tang (feat. Punch & Ab-Soul)".to_string()),
        );
    }

    #[test]
    fn normalizes_ft_to_feat_with_parens() {
        assert_eq!(
            normalize_feat_syntax("West Coast Wu-Tang ft. Punch and Ab-Soul"),
            "West Coast Wu-Tang (feat. Punch & Ab-Soul)".to_string(),
        );
    }

    #[test]
    fn normalizes_featuring_to_feat_with_parens() {
        assert_eq!(
            normalize_feat_syntax("The Heart Pt. 2 featuring Dash Snow"),
            "The Heart Pt. 2 (feat. Dash Snow)".to_string(),
        );
    }

    #[test]
    fn leaves_already_parenthesized_feat_alone() {
        assert_eq!(
            normalize_feat_syntax("The Heart Pt. 2 (feat. Dash Snow)"),
            "The Heart Pt. 2 (feat. Dash Snow)".to_string(),
        );
    }

    #[test]
    fn full_fallback_title_has_feat_parens() {
        assert_eq!(
            infer_title_from_source_title(
                "Kendrick Lamar - West Coast Wu-Tang Ft. Ab-Soul, Punch (Lyrics)",
                "kendrick"
            ),
            Some("West Coast Wu-Tang (feat. Ab-Soul & Punch)".to_string()),
        );
    }

    #[test]
    fn strips_with_lyrics_exclamation_and_normalizes_paren_feat() {
        // Regression: "with Lyrics!" was leaving "with !" and "(Ft. X)" wasn't normalized
        let result = infer_title_from_source_title(
            "Kendrick Lamar - Westside, Right On Time (Ft. Young Jeezy) (Prod. by Canei Finch) with Lyrics!",
            "kendrick",
        );
        assert_eq!(
            result,
            Some("Westside, Right On Time (feat. Young Jeezy) (Prod. by Canei Finch)".to_string()),
        );
    }

    fn rejected_candidate() -> (
        needle_core::search::Candidate,
        needle_core::score::CandidateScore,
    ) {
        let candidate = needle_core::search::Candidate {
            provider: "youtube".into(),
            id: "abc".into(),
            title: "Some Cover (Reaction)".into(),
            url: "https://example.test/abc".into(),
            uploader: Some("Someone".into()),
            channel_is_verified: None,
            duration_ms: Some(200_000),
            thumbnail_url: None,
            view_count: None,
            audio_codec: None,
            audio_bitrate_kbps: None,
            query_origin: "direct".into(),
        };
        let score = needle_core::score::CandidateScore {
            confidence: 0,
            status: needle_core::score::ScoreStatus::Rejected,
            positives: Vec::new(),
            warnings: Vec::new(),
            rejects: vec!["reaction video".to_string()],
        };
        (candidate, score)
    }

    #[test]
    fn auto_select_bails_when_no_direct_url_and_all_rejected() {
        let scored = vec![rejected_candidate()];
        assert!(auto_select_candidate(&scored, false, false).is_err());
    }

    #[test]
    fn auto_select_forces_choice_when_direct_url_provided_and_all_rejected() {
        // A user-supplied source URL (e.g. via the browser extension) has already
        // been vetted by the human; scoring must never hard-block that download.
        let scored = vec![rejected_candidate()];
        let idx = auto_select_candidate(&scored, true, false).unwrap();
        assert_eq!(idx, 0);
    }
}
