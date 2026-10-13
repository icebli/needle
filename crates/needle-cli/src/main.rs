use clap::{Parser, Subcommand};
use anyhow::{Result, bail};
use console::style;
use indicatif::{ProgressBar, ProgressStyle};
use std::time::Duration;
use strsim::jaro_winkler;

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
        Commands::Get { artist, title, album, url, format, profile, json, no_metadata, duration_override, yes, strict, source, events } => {
            cmd_get(artist, title, album, url, format, profile, json, no_metadata, duration_override, yes, strict, source, events).await
        }
        Commands::Search { artist, title, album, url, no_metadata, duration_override, source, json } => {
            cmd_search(artist, title, album, url, no_metadata, duration_override, source, json).await
        }
        Commands::Doctor { json } => cmd_doctor(json).await,
    }
}

async fn cmd_get(
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
) -> Result<()> {
    use needle_core::*;

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
    let metadata = if no_metadata {
        None
    } else {
        let resolved = metadata::resolve_metadata(&req.artist, &req.title).await?;
        filter_compatible_metadata(resolved, &req.artist, &req.title)
    };
    pb.finish_and_clear();

    if !json {
        if let Some(ref m) = metadata {
            println!("{} {} — {}",
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
            println!("{} No metadata found — using request tags only", style("⚠").yellow());
        }
    }

    // 2. Build queries + search
    progress_event(events, "search");
    let queries = search::build_queries(&req.artist, &req.title, req.album.as_deref());
    let pb = spinner(if req.url.is_some() { "Resolving selected source..." } else { "Searching sources..." });
    let mut candidates = resolve_requested_candidates(
        toolchain.yt_dlp_path.to_str().unwrap(),
        &queries,
        parse_source(&source)?,
        req.url.as_deref(),
    )?;
    pb.finish_and_clear();

    // 2b. If MB gave us a canonical URL, resolve it via yt-dlp and prepend as top candidate
    if req.url.is_none() {
        if let Some(ref canonical_url) = metadata.as_ref().and_then(|m| m.source.canonical_url.clone()) {
            let pb = spinner("Resolving canonical source URL...");
            match search::resolve_url(toolchain.yt_dlp_path.to_str().unwrap(), canonical_url) {
                Ok(Some(canonical_candidate)) => {
                    if !json {
                        println!("{} Canonical source: {} · {}",
                            style("✓").green(),
                            style(&canonical_candidate.title).bold(),
                            canonical_candidate.uploader.as_deref().unwrap_or("?"),
                        );
                    }
                    // Prepend — scorer will rank it, but it gets first position as tiebreak
                    candidates.insert(0, canonical_candidate);
                }
                Ok(None) => {}
                Err(e) => { eprintln!("[debug] canonical URL resolve failed: {e}"); }
            }
            pb.finish_and_clear();
        }
    }

    if !json {
        println!("{} Found {} candidates\n", style("✓").green(), candidates.len());
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

    scored.sort_by(|a, b| b.1.confidence.cmp(&a.1.confidence));

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

    if !json {
        println!("\nDownloading: {}\n", style(&selected.title).bold());
    }

    // 6a. Post-selection metadata upgrade: if initial lookup missed or has no album,
    //     re-query with the clean inferred title extracted from the selected source.
    //     This handles mixtapes/singles where raw request title differs from canonical.
    let mut meta_re_queried = false;
    let metadata = if !no_metadata {
        let inferred_clean = infer_title_from_source_title(&selected.title, &req.artist);
        let needs_upgrade = metadata.as_ref().map(|m| m.album.is_none()).unwrap_or(true);
        if needs_upgrade {
            if let Some(clean_title) = inferred_clean.as_deref() {
                if clean_title != req.title {
                    let pb = spinner("Re-resolving metadata with inferred title...");
                    let upgraded = metadata::resolve_metadata(&req.artist, clean_title).await
                        .ok()
                        .flatten()
                        .and_then(|m| filter_compatible_metadata(Some(m), &req.artist, clean_title));
                    pb.finish_and_clear();
                    if let Some(ref m) = upgraded {
                        meta_re_queried = true;
                        if !json {
                            println!("{} Upgraded metadata: {} — {}{}",
                                style("✓").green(),
                                style(&m.artist).bold(),
                                style(&m.title).bold(),
                                m.album.as_deref().map(|a| format!(" ({})", a)).unwrap_or_default(),
                            );
                        }
                    }
                    upgraded.or(metadata)
                } else { metadata }
            } else { metadata }
        } else { metadata }
    } else { metadata };

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
    let downloaded = download::download_audio(
        toolchain.yt_dlp_path.to_str().unwrap(),
        &plan,
    )?;
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
    let fallback_album = metadata.as_ref()
        .and_then(|m| m.album.clone())
        .or_else(|| req.album.clone())
        .or_else(|| infer_album_from_source_title(&selected.title))
        .or_else(|| infer_album_from_scored_candidates(&scored));

    // Build canonical title: use metadata title, append (feat. X & Y) if featured_artists present
    let meta_title_raw = metadata.as_ref().map(|m| {
        let base = m.title.clone();
        if m.featured_artists.is_empty() { base }
        else {
            let feats = normalize_featured_artists_list_pub(&m.featured_artists);
            format!("{} (feat. {})", base, feats)
        }
    });
    let fallback_title = meta_title_raw
        .unwrap_or_else(|| infer_title_from_source_title(&selected.title, &req.artist)
            .unwrap_or_else(|| title_case_fallback(&req.title)));
    let fallback_artist = metadata.as_ref()
        .map(|m| m.artist.clone())
        .unwrap_or_else(|| title_case_fallback(&req.artist));

    let library_artist = canonical_library_artist(metadata.as_ref(), &req.artist);
    let tag_plan = tag::TagPlan {
        title: fallback_title,
        artist: fallback_artist,
        album: fallback_album,
        album_artist: Some(library_artist.to_string()),
        track: metadata.as_ref().and_then(|m| m.track_number),
        disc: metadata.as_ref().and_then(|m| m.disc_number),
        date: metadata.as_ref().and_then(|m| m.release_date.clone()),
        source_url: Some(selected.url.clone()),
        ..Default::default()
    };
    tag::write_tags(&converted, &tag_plan)?;
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
            println!("{}", serde_json::to_string(&serde_json::json!({
                "ok": true,
                "skipped": true,
                "saved_path": out_path,
                "artist": tag_plan.artist,
                "title": tag_plan.title,
                "album": tag_plan.album,
                "source_url": &selected.url,
            }))?);
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
            provider: metadata.as_ref().map(|m| m.source.provider.clone()).unwrap_or_else(|| "none".into()),
            plausibility_score: metadata.as_ref().map(|m| m.source.plausibility_score),
            recording_id: metadata.as_ref().and_then(|m| m.source.recording_id.clone()),
            resolved_artist: metadata.as_ref().map(|m| m.artist.clone()),
            resolved_title: metadata.as_ref().map(|m| m.title.clone()),
            resolved_album: metadata.as_ref().and_then(|m| m.album.clone()),
            featured_artists: metadata.as_ref().map(|m| m.featured_artists.clone()).unwrap_or_default(),
            re_queried: meta_re_queried,
            canonical_url: metadata.as_ref().and_then(|m| m.source.canonical_url.clone()),
        },
        created_by: "needle 0.1.0".into(),
    };
    let prov_path = out_path.with_extension("json");
    prov.write(&prov_path)?;

    if json {
        println!("{}", serde_json::to_string(&serde_json::json!({
            "ok": true,
            "saved_path": out_path,
            "artist": tag_plan.artist,
            "title": tag_plan.title,
            "album": tag_plan.album,
            "source_url": &selected.url,
        }))?);
    } else {
        println!("\n{} Saved: {}", style("✓").green(), out_path.display());
    }

    Ok(())
}

async fn cmd_search(
    artist: String,
    title: String,
    album: Option<String>,
    url: Option<String>,
    no_metadata: bool,
    duration_override: Option<String>,
    source: String,
    json: bool,
) -> Result<()> {
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

    scored.sort_by(|a, b| b.1.confidence.cmp(&a.1.confidence));
    if json {
        println!("{}", serde_json::to_string(&search_json_response(&req, metadata.as_ref(), &scored))?);
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
            println!("{} {:20} {}", style("•").yellow(), status.name, status.message);
        } else if status.ok {
            println!("{} {:20} {}", style("✓").green(), status.name, status.message);
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
    scored: &[(needle_core::search::Candidate, needle_core::score::CandidateScore)],
) -> serde_json::Value {
    let candidates: Vec<_> = scored.iter().map(|(candidate, score)| {
        serde_json::json!({ "candidate": candidate, "score": score })
    }).collect();
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
    scored: &[(needle_core::search::Candidate, needle_core::score::CandidateScore)],
    req: &needle_core::ParsedRequest,
    metadata: Option<&needle_core::TrackMetadata>,
    expected_duration_ms: Option<u64>,
) {
    println!("Requested: {} — {}", style(&req.artist).bold(), style(&req.title).bold());
    if let Some(dur) = expected_duration_ms {
        println!("Expected duration: {}", fmt_duration(dur));
    } else if let Some(m) = metadata {
        if let Some(dur) = m.duration_ms { println!("Expected duration: {}", fmt_duration(dur)); }
    }
    println!();

    let groups = [("Recommended", needle_core::score::ScoreStatus::Recommended),
                  ("Uncertain", needle_core::score::ScoreStatus::Uncertain),
                  ("Rejected", needle_core::score::ScoreStatus::Rejected)];

    for (label, status) in groups {
        let group: Vec<_> = scored.iter().enumerate()
            .filter(|(_, (_, s))| s.status == status)
            .collect();
        if group.is_empty() { continue; }

        println!("{}", style(label).bold().underlined());
        for (i, (cand, score)) in group {
            let dur = cand.duration_ms.map(fmt_duration).unwrap_or_else(|| "??:??".into());
            let up = cand.uploader.as_deref().unwrap_or("unknown");
            let conf = style(format!("{:3}", score.confidence));
            let conf_styled = match status {
                needle_core::score::ScoreStatus::Recommended => conf.green(),
                needle_core::score::ScoreStatus::Uncertain => conf.yellow(),
                needle_core::score::ScoreStatus::Rejected => conf.red(),
            };

            println!("  [{}] {}%  {}", i + 1, conf_styled, style(&cand.title).bold());
            let quality = cand.source_quality_label();
            if let Some(quality) = quality {
                println!("      {} · {} · {} · {}", dur, style(&cand.provider).dim(), style(up).dim(), style(quality).dim());
            } else {
                println!("      {} · {} · {}", dur, style(&cand.provider).dim(), style(up).dim());
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
    scored: &[(needle_core::search::Candidate, needle_core::score::CandidateScore)],
    direct_url_provided: bool,
) -> Result<usize> {
    use dialoguer::Input;

    let valid: Vec<usize> = scored.iter().enumerate()
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
    scored: &[(needle_core::search::Candidate, needle_core::score::CandidateScore)],
    direct_url_provided: bool,
    quiet: bool,
) -> Result<usize> {
    let Some((idx, (candidate, score))) = scored.iter().enumerate()
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
    pb.set_style(ProgressStyle::default_spinner()
        .template("{spinner:.green} {msg}")
        .unwrap());
    pb.set_message(msg.to_string());
    pb.enable_steady_tick(Duration::from_millis(100));
    pb
}

fn progress_event(enabled: bool, stage: &str) {
    if enabled {
        eprintln!("{}", serde_json::json!({ "event": "progress", "stage": stage }));
    }
}

fn fmt_duration(ms: u64) -> String {
    let total_sec = ms / 1000;
    let m = total_sec / 60;
    let s = total_sec % 60;
    format!("{}:{:02}", m, s)
}

fn parse_duration_override(value: Option<&str>) -> Result<Option<u64>> {
    let Some(value) = value else { return Ok(None); };
    let value = value.trim();
    if value.is_empty() { return Ok(None); }

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
            if delta > 30_000 { Some(consensus) } else { Some(metadata) }
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
        || contains_or_close(&normalize_for_metadata_match(&metadata.title), &normalize_for_metadata_match(request_title), 0.90);

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

    candidates.into_iter()
        .map(|s| s.trim().to_string())
        .find(|s| is_likely_album_hint(s))
}

fn infer_album_from_scored_candidates(
    scored: &[(needle_core::search::Candidate, needle_core::score::CandidateScore)],
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
    counts.into_iter()
        .filter(|(_, count)| *count >= 2)
        .max_by_key(|(_, count)| *count)
        .map(|(album, _)| album)
}

fn infer_title_from_source_title(source_title: &str, request_artist: &str) -> Option<String> {
    let cleaned = strip_bracketed_noise(source_title);
    let parts: Vec<_> = cleaned.split(" - ").map(str::trim).filter(|s| !s.is_empty()).collect();
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
        loop {
            let Some(start) = out.find(open) else { break; };
            let Some(end_rel) = out[start + open.len_utf8()..].find(close) else { break; };
            let end = start + open.len_utf8() + end_rel;
            let segment = &out[start + open.len_utf8()..end];
            if is_likely_album_hint(segment) {
                out.replace_range(start..=end, "");
            } else if is_title_noise(segment) {
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
        "with lyrics!", "with lyrics", "w/ lyrics",
        "▼download▼", "download",
        "lyric video", "lyrics", "lyric",
        "official audio", "official video", "official music video",
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
    let title = title.trim_end_matches(|c: char| c == '!' || c == ',' || c == '.' || c == '-' || c == '/');
    title.split_whitespace().collect::<Vec<_>>().join(" ").trim_matches('-').trim().to_string()
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
                let Some(rel_end) = out[start + open.len_utf8()..].find(close) else { break; };
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
    let paren_variants = ["(featuring ", "(featured ", "(feat. ", "(feat ", "(ft. ", "(ft "];
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

    let variants = [" featuring ", " featured ", " feat ", " feat. ", " ft. ", " ft "];
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
    let parts: Vec<&str> = normalized.split(',').map(str::trim).filter(|s| !s.is_empty()).collect();
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
    if ["lyrics", "lyric", "official audio", "official video", "audio", "video", "hq", "hd", "clean", "explicit"]
        .iter().any(|marker| normalized == *marker) {
        return true;
    }
    // Suffix patterns: anything ending in "mix" or "remix" is a remix variant, not the track
    if normalized.ends_with("mix") || normalized.ends_with("remix") {
        return true;
    }
    // Compound bracket phrases composed entirely of noise words, e.g.
    // "Music Video", "Official Music Video", "Audio HQ", "HD Video", etc.
    let words: Vec<&str> = normalized.split_whitespace().collect();
    if words.len() >= 2 && words.iter().all(|w| {
        ["official", "audio", "video", "music", "lyrics", "lyric", "hq", "hd", "clean", "explicit"]
            .contains(w)
    }) {
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
        let Some(end) = after_open.find(close) else { break; };
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
    if value.chars().any(|c| matches!(c, '#' | '!' | '{' | '}' | '|' | '~' | '@')) {
        return false;
    }

    let junk = [
        "official", "audio", "lyrics", "lyric", "video", "hq", "hd", "clean",
        "explicit", "feat", "ft", "featuring", "prod", "remix", "mix", "download",
        // Descriptive suffixes that appear in YouTube titles but never in real album names
        "song", "music", "track", "freestyle", "edit", "cover", "live", "leak",
        "reaction", "interview", "snippet", "session", "performance", "visualizer",
        "slowed", "reverb", "chopped", "sped up", "bass boosted",
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
            .ok_or_else(|| anyhow::anyhow!("selected URL did not resolve to a supported audio source"));
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
            Commands::Search { artist, title, album, url, no_metadata, duration_override, source, json } => {
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
            Commands::Get { json, events, source, .. } => {
                assert!(!json);
                assert!(events);
                assert_eq!(source, "auto");
            }
            _ => panic!("expected get command"),
        }

        let cli = Cli::try_parse_from(["needle", "doctor", "--json"]).unwrap();
        assert!(matches!(cli.command, Commands::Doctor { json: true }));
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
        assert_eq!(response["candidates"][0]["candidate"]["url"], "https://example.test/abc");
        assert_eq!(response["candidates"][0]["score"]["status"], "rejected");
    }

    #[test]
    fn strict_mode_rejects_scored_candidate_but_default_preserves_legacy_behavior() {
        let (_, rejected) = rejected_candidate();
        assert!(guard_selected_candidate(false, &rejected).is_ok());
        let error = guard_selected_candidate(true, &rejected).unwrap_err().to_string();
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
        ).unwrap();

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
            infer_title_from_source_title("Playboi Carti - H00DBYAIR (Official Music Video)", "Playboi Carti"),
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
            infer_title_from_source_title("Chain Heavy (With Lyrics) - Kanye West ft Talib Kweli", "Kanye West"),
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
        assert_eq!(
            canonical_library_artist(None, "A$AP ROCKY"),
            "A$AP ROCKY"
        );
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
        let result = filter_compatible_metadata(
            Some(meta),
            "A$AP ROCKY",
            "Big Spender",
        );
        assert!(result.is_some());
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
            infer_album_from_source_title("West Coast Wu-Tang ft. Punch and Ab-Soul - Kendrick Lamar (C4)"),
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

        assert_eq!(infer_album_from_scored_candidates(&scored), Some("C4".to_string()));
    }

    #[test]
    fn infers_clean_title_from_artist_first_source_title() {
        assert_eq!(
            infer_title_from_source_title("Kendrick Lamar - West Coast Wu-Tang Ft. Ab-Soul, Punch (Lyrics)", "kendrick"),
            Some("West Coast Wu-Tang (feat. Ab-Soul & Punch)".to_string()),
        );
    }

    #[test]
    fn infers_clean_title_from_artist_last_source_title() {
        assert_eq!(
            infer_title_from_source_title("West Coast Wu-Tang ft. Punch and Ab-Soul - Kendrick Lamar (C4)", "kendrick"),
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
            infer_title_from_source_title("Kendrick Lamar - West Coast Wu-Tang Ft. Ab-Soul, Punch (Lyrics)", "kendrick"),
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

    fn rejected_candidate() -> (needle_core::search::Candidate, needle_core::score::CandidateScore) {
        let candidate = needle_core::search::Candidate {
            provider: "youtube".into(),
            id: "abc".into(),
            title: "Some Cover (Reaction)".into(),
            url: "https://example.test/abc".into(),
            uploader: Some("Someone".into()),
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
