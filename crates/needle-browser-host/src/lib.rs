pub mod discovery;

use anyhow::{anyhow, bail, Context, Result};
use directories::ProjectDirs;
use serde::{Deserialize, Serialize};
use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::{self, ErrorKind, Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tiny_http::{Header, Method, Request, Response, Server, StatusCode};
use url::Url;

const QUEUE_ADDRESS: &str = "127.0.0.1:29878";
const MAX_NATIVE_MESSAGE_BYTES: usize = 1024 * 1024;
const MAX_FIELD_CHARS: usize = 500;
const EMPTY_SHUTDOWN_DELAY: Duration = Duration::from_secs(30);
const ALLOWED_ORIGINS: [&str; 3] = [
    "https://xpui.app.spotify.com",
    "https://xpui.app",
    "https://open.spotify.com",
];

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", tag = "action")]
pub enum BrowserRequest {
    Doctor,
    Download {
        #[serde(rename = "sourceUrl")]
        source_url: String,
        artist: String,
        title: String,
        #[serde(default)]
        album: Option<String>,
        #[serde(default)]
        playlist: PlaylistPreference,
    },
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaylistPreference {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default = "default_playlist_name")]
    pub name: String,
}

fn default_playlist_name() -> String {
    "Needle".to_owned()
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserResponse {
    pub ok: bool,
    pub status: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<DownloadResult>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub doctor: Option<DoctorResult>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadResult {
    pub saved_path: PathBuf,
    pub artist: String,
    pub title: String,
    pub album: Option<String>,
    pub source_url: String,
    pub playlist_queued: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DoctorResult {
    pub needle_path: Option<PathBuf>,
    pub spicetify_path: Option<PathBuf>,
    pub queue_server_running: bool,
}

#[derive(Debug, Clone, Deserialize)]
struct NeedleOutput {
    ok: bool,
    saved_path: PathBuf,
    artist: String,
    title: String,
    album: Option<String>,
    source_url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct QueueTrack {
    name: String,
    artist: String,
    album: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    saved_path: Option<PathBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    duration_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    file_revision: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct QueueJob {
    id: String,
    playlist_name: String,
    tracks: Vec<QueueTrack>,
    created_at_unix: u64,
    #[serde(default)]
    revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    reconcile: Option<ReconcileState>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReconcileState {
    source_job_id: String,
    target: Option<ReconcileTarget>,
    mutation: Option<ReplacementMutation>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReconcileTarget {
    playlist_uri: String,
    added_uri: String,
    added_uid: Option<String>,
    track: QueueTrack,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReplacementMutation {
    phase: ReplacementPhase,
    old_uid: String,
    new_uri: String,
    new_uid: Option<String>,
    original_rows: Vec<PlaylistRow>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
enum ReplacementPhase {
    Adding,
    Inserted,
    Removing,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PlaylistRow {
    uri: String,
    uid: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DesktopReconcileRequest {
    previous_job_id: String,
    track: QueueTrack,
    previous_track: QueueTrack,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReconcileCheckpoint {
    job_id: String,
    revision: u64,
    mutation: ReplacementMutation,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DesktopEnqueueRequest {
    pub artist: String,
    pub title: String,
    #[serde(default)]
    pub album: Option<String>,
    #[serde(default)]
    pub saved_path: Option<PathBuf>,
    pub playlist_name: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DesktopEnqueueResponse {
    pub ok: bool,
    pub job_id: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DesktopStatusResponse {
    pub ok: bool,
    pub status: String,
    pub playlist_uri: Option<String>,
    pub added_uri: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    pub track: Option<QueueTrack>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AcknowledgementReceipt {
    job_id: String,
    playlist_uri: Option<String>,
    added_uri: Option<String>,
    acknowledged_at_unix: u64,
    #[serde(default)]
    revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    track: Option<QueueTrack>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    added_uid: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    detail: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    source_job_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProgressReceipt {
    job_id: String,
    detail: String,
    updated_at_unix: u64,
}

pub fn run_native_host() -> Result<()> {
    let stdin = io::stdin();
    let request = read_native_message(stdin.lock())?
        .ok_or_else(|| anyhow!("native host received no message"));

    let response = match request.and_then(handle_request) {
        Ok(response) => response,
        Err(error) => BrowserResponse {
            ok: false,
            status: "error".into(),
            message: format!("{error:#}"),
            result: None,
            doctor: None,
        },
    };

    write_native_message(io::stdout().lock(), &response)
}

pub fn run_desktop_command<R: Read, W: Write>(
    command: &str,
    mut reader: R,
    mut writer: W,
) -> Result<()> {
    let mut body = String::new();
    reader
        .by_ref()
        .take((MAX_NATIVE_MESSAGE_BYTES + 1) as u64)
        .read_to_string(&mut body)?;
    if body.len() > MAX_NATIVE_MESSAGE_BYTES {
        bail!("desktop command is too large");
    }
    let response = match command {
        "enqueue" => serde_json::to_value(enqueue_desktop_job(&body)?)?,
        "reconcile" => serde_json::to_value(reconcile_desktop_job(&body)?)?,
        "status" => serde_json::to_value(status_desktop_job(body.trim())?)?,
        "resume" => serde_json::to_value(resume_desktop_job(body.trim())?)?,
        _ => bail!("unknown desktop command: {command}"),
    };
    serde_json::to_writer(&mut writer, &response)?;
    writer.write_all(b"\n")?;
    writer.flush()?;
    Ok(())
}

fn enqueue_desktop_job(body: &str) -> Result<DesktopEnqueueResponse> {
    let request: DesktopEnqueueRequest =
        serde_json::from_str(body).context("invalid enqueue JSON")?;
    let artist = validate_text("artist", request.artist)?;
    let title = validate_text("title", request.title)?;
    let album = request
        .album
        .map(|value| validate_text("album", value))
        .transpose()?;
    let playlist_name = validate_text("playlist name", request.playlist_name)?;
    let duration_ms = request.saved_path.as_deref().and_then(probe_duration_ms);
    let job = QueueJob {
        id: job_id(),
        playlist_name,
        tracks: vec![QueueTrack {
            name: title,
            artist,
            album,
            file_revision: request.saved_path.as_deref().and_then(file_revision),
            saved_path: request.saved_path,
            duration_ms,
        }],
        created_at_unix: unix_timestamp(),
        revision: 0,
        reconcile: None,
    };
    let job_id = enqueue_job(job)?;
    ensure_queue_server()?;
    Ok(DesktopEnqueueResponse { ok: true, job_id })
}

fn file_revision(path: &Path) -> Option<String> {
    let metadata = fs::metadata(path).ok()?;
    let modified = metadata.modified().ok()?.duration_since(UNIX_EPOCH).ok()?;
    Some(format!("{}:{}", metadata.len(), modified.as_nanos()))
}

fn reconcile_desktop_job(body: &str) -> Result<DesktopEnqueueResponse> {
    let mut request: DesktopReconcileRequest = serde_json::from_str(body)?;
    validate_job_id(&request.previous_job_id)?;
    request.track.artist = validate_text("artist", request.track.artist)?;
    request.track.name = validate_text("title", request.track.name)?;
    let path = request
        .track
        .saved_path
        .as_deref()
        .ok_or_else(|| anyhow!("reconciliation requires a saved file"))?;
    if !path.is_file() || request.previous_track.saved_path.as_deref() != Some(path) {
        bail!("reconciliation requires the same existing saved file");
    }
    request.track.duration_ms = probe_duration_ms(path);
    request.track.file_revision = file_revision(path);
    let id = reconcile_job(&queue_path()?, &receipt_dir()?, request)?;
    ensure_queue_server()?;
    Ok(DesktopEnqueueResponse {
        ok: true,
        job_id: id,
    })
}

fn target_from_receipt(receipt: &AcknowledgementReceipt) -> Option<ReconcileTarget> {
    Some(ReconcileTarget {
        playlist_uri: valid_spotify_uri(receipt.playlist_uri.clone(), "spotify:playlist:")?,
        added_uri: valid_spotify_uri(receipt.added_uri.clone(), "spotify:local:")?,
        added_uid: receipt.added_uid.clone(),
        track: receipt.track.clone()?,
    })
}

fn reconcile_job(
    queue: &Path,
    receipts: &Path,
    mut request: DesktopReconcileRequest,
) -> Result<String> {
    with_queue_lock(queue, || {
        let mut jobs = load_queue(queue)?;
        // Follow completed and pending successors after an interrupted history
        // write. The receipt chain keeps the original job ID recoverable.
        let mut completed = Vec::new();
        if receipts.is_dir() {
            for entry in fs::read_dir(receipts)? {
                let path = entry?.path();
                if path
                    .extension()
                    .is_some_and(|extension| extension == "json")
                {
                    let receipt: AcknowledgementReceipt = serde_json::from_slice(&fs::read(path)?)?;
                    completed.push(receipt);
                }
            }
        }
        let mut visited = std::collections::HashSet::new();
        loop {
            if !visited.insert(request.previous_job_id.clone()) {
                bail!("Spotify receipt lineage is cyclic");
            }
            let mut successors: Vec<String> = jobs
                .iter()
                .filter(|job| {
                    job.reconcile
                        .as_ref()
                        .is_some_and(|state| state.source_job_id == request.previous_job_id)
                })
                .map(|job| job.id.clone())
                .chain(
                    completed
                        .iter()
                        .filter(|receipt| {
                            receipt.source_job_id.as_ref() == Some(&request.previous_job_id)
                        })
                        .map(|receipt| receipt.job_id.clone()),
                )
                .collect();
            successors.sort();
            successors.dedup();
            match successors.as_slice() {
                [] => break,
                [next] => request.previous_job_id = next.clone(),
                _ => bail!(
                    "Spotify receipt lineage has conflicting successors; no playlist was changed"
                ),
            }
        }
        if let Some(existing) = jobs
            .iter_mut()
            .find(|job| job.id == request.previous_job_id)
        {
            if existing
                .tracks
                .first()
                .and_then(|track| track.saved_path.as_ref())
                != request.track.saved_path.as_ref()
            {
                bail!("pending Spotify job belongs to another file");
            }
            if existing.tracks.first() == Some(&request.track) {
                return Ok(existing.id.clone());
            }
            // An unstarted replacement can adopt the newest tags. Once mutation
            // begins its exact rows stay immutable and the successor waits.
            if existing
                .reconcile
                .as_ref()
                .is_some_and(|state| state.mutation.is_none())
            {
                existing.tracks = vec![request.track];
                existing.revision += 1;
                let id = existing.id.clone();
                save_queue(queue, &jobs)?;
                return Ok(id);
            }
        }
        let target = if let Some(mut receipt) = load_receipt(receipts, &request.previous_job_id)? {
            if !complete_receipt(&receipt) {
                bail!("Spotify destination was never confirmed");
            }
            if receipt.track.is_none() {
                // Legacy adoption is allowed only through the exact history job
                // ID and its same-file snapshot supplied by the desktop app.
                if request.previous_track.saved_path != request.track.saved_path {
                    bail!("legacy file association does not match");
                }
                receipt.track = Some(request.previous_track.clone());
                save_receipt(receipts, &receipt)?;
            }
            let baseline = receipt
                .track
                .as_ref()
                .ok_or_else(|| anyhow!("missing file association"))?;
            if baseline.saved_path != request.track.saved_path {
                bail!("Spotify receipt belongs to another file");
            }
            if baseline == &request.track {
                return Ok(receipt.job_id);
            }
            Some(
                target_from_receipt(&receipt)
                    .ok_or_else(|| anyhow!("invalid Spotify destination"))?,
            )
        } else if jobs.iter().any(|job| job.id == request.previous_job_id) {
            None
        } else {
            bail!("Spotify's original delivery receipt is missing; no playlist was changed");
        };
        let id = job_id();
        jobs.push(QueueJob {
            id: id.clone(),
            playlist_name: String::new(),
            tracks: vec![request.track],
            created_at_unix: unix_timestamp(),
            revision: 1,
            reconcile: Some(ReconcileState {
                source_job_id: request.previous_job_id,
                target,
                mutation: None,
            }),
        });
        save_queue(queue, &jobs)?;
        Ok(id)
    })
}

fn ready_jobs(queue: &Path, receipts: &Path) -> Result<Vec<QueueJob>> {
    with_queue_lock(queue, || {
        let mut jobs = load_queue(queue)?;
        let mut changed = false;
        for job in &mut jobs {
            if let Some(state) = &mut job.reconcile {
                if state.target.is_none() {
                    if let Some(receipt) = load_receipt(receipts, &state.source_job_id)? {
                        let target = target_from_receipt(&receipt);
                        if target.as_ref().is_some_and(|target| {
                            Some(&target.track.saved_path)
                                == job.tracks.first().map(|track| &track.saved_path)
                        }) {
                            state.target = target;
                            changed = true;
                        }
                    }
                }
            }
        }
        if changed {
            save_queue(queue, &jobs)?;
        }
        Ok(jobs
            .into_iter()
            .filter(|job| {
                job.reconcile
                    .as_ref()
                    .is_none_or(|state| state.target.is_some())
            })
            .collect())
    })
}

fn checkpoint_replacement(queue: &Path, checkpoint: ReconcileCheckpoint) -> Result<bool> {
    with_queue_lock(queue, || {
        let mut jobs = load_queue(queue)?;
        let Some(job) = jobs
            .iter_mut()
            .find(|job| job.id == checkpoint.job_id && job.revision == checkpoint.revision)
        else {
            return Ok(false);
        };
        let Some(state) = &mut job.reconcile else {
            return Ok(false);
        };
        let Some(target) = &state.target else {
            return Ok(false);
        };
        let mutation = checkpoint.mutation;
        if mutation.old_uid.is_empty()
            || !mutation.new_uri.starts_with("spotify:local:")
            || mutation.original_rows.iter().any(|row| row.uid.is_empty())
            || !mutation
                .original_rows
                .iter()
                .any(|row| row.uid == mutation.old_uid && row.uri == target.added_uri)
        {
            return Ok(false);
        }
        if let Some(previous) = &state.mutation {
            if previous.old_uid != mutation.old_uid
                || previous.new_uri != mutation.new_uri
                || serde_json::to_value(&previous.original_rows)?
                    != serde_json::to_value(&mutation.original_rows)?
                || previous
                    .new_uid
                    .as_ref()
                    .is_some_and(|uid| mutation.new_uid.as_ref() != Some(uid))
            {
                return Ok(false);
            }
        }
        state.mutation = Some(mutation);
        save_queue(queue, &jobs)?;
        Ok(true)
    })
}

fn status_desktop_job(job_id: &str) -> Result<DesktopStatusResponse> {
    let job_id = validate_job_id(job_id)?;
    status_for_job_with_progress(&queue_path()?, &receipt_dir()?, &progress_dir()?, &job_id)
}

fn resume_desktop_job(job_id: &str) -> Result<DesktopStatusResponse> {
    let status = status_desktop_job(job_id)?;
    if status.status == "pending" {
        ensure_queue_server()?;
    }
    Ok(status)
}

#[cfg(test)]
fn status_for_job(queue: &Path, receipts: &Path, job_id: &str) -> Result<DesktopStatusResponse> {
    status_for_job_with_progress(queue, receipts, Path::new(""), job_id)
}

fn status_for_job_with_progress(
    queue: &Path,
    receipts: &Path,
    progress: &Path,
    job_id: &str,
) -> Result<DesktopStatusResponse> {
    if let Some(receipt) = load_receipt(receipts, job_id)? {
        if complete_receipt(&receipt) {
            return Ok(DesktopStatusResponse {
                ok: true,
                status: "added".into(),
                playlist_uri: receipt.playlist_uri,
                added_uri: receipt.added_uri,
                detail: receipt.detail,
                track: receipt.track,
            });
        }
    }
    let pending = load_queue(queue)?.iter().any(|job| job.id == job_id);
    let detail = if pending && !progress.as_os_str().is_empty() {
        load_progress(progress, job_id)?.map(|receipt| receipt.detail)
    } else {
        None
    };
    Ok(DesktopStatusResponse {
        ok: true,
        status: if pending { "pending" } else { "unknown" }.into(),
        playlist_uri: None,
        added_uri: None,
        track: None,
        detail,
    })
}

fn handle_request(request: BrowserRequest) -> Result<BrowserResponse> {
    match request {
        BrowserRequest::Doctor => {
            let doctor = DoctorResult {
                needle_path: find_needle_binary(),
                spicetify_path: find_executable("spicetify"),
                queue_server_running: TcpStream::connect_timeout(
                    &QUEUE_ADDRESS.parse()?,
                    Duration::from_millis(150),
                )
                .is_ok(),
            };
            let ready = doctor.needle_path.is_some();
            Ok(BrowserResponse {
                ok: ready,
                status: if ready { "ready" } else { "missing-needle" }.into(),
                message: if ready {
                    "Needle bridge ready".into()
                } else {
                    "Needle binary not found; reinstall the browser bridge".into()
                },
                result: None,
                doctor: Some(doctor),
            })
        }
        BrowserRequest::Download {
            source_url,
            artist,
            title,
            album,
            playlist,
        } => download(source_url, artist, title, album, playlist),
    }
}

fn download(
    source_url: String,
    artist: String,
    title: String,
    album: Option<String>,
    playlist: PlaylistPreference,
) -> Result<BrowserResponse> {
    validate_source_url(&source_url)?;
    let artist = validate_text("artist", artist)?;
    let title = validate_text("title", title)?;
    let album = album
        .map(|value| validate_text("album", value))
        .transpose()?;

    let binary = find_needle_binary().ok_or_else(|| {
        anyhow!("needle binary not found; run scripts/install-browser-extension.sh")
    })?;
    let mut command = Command::new(&binary);
    command.args([
        "get",
        &artist,
        &title,
        "--url",
        &source_url,
        "--yes",
        "--json",
    ]);
    if let Some(ref album) = album {
        command.args(["--album", album]);
    }
    command.env("NO_COLOR", "1");
    command.env("PATH", browser_tool_path());

    let output = command
        .output()
        .with_context(|| format!("failed to launch {}", binary.display()))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        bail!(
            "needle exited {}: {}{}",
            output.status,
            tail(&stderr, 1600),
            if stderr.trim().is_empty() {
                tail(&stdout, 1600)
            } else {
                String::new()
            },
        );
    }

    let stdout = String::from_utf8(output.stdout).context("needle emitted invalid UTF-8")?;
    let needle = parse_needle_output(&stdout)?;
    if !needle.ok {
        bail!("needle reported an unsuccessful download");
    }

    let playlist_name = validate_text("playlist name", playlist.name)?;
    let playlist_queued = if playlist.enabled {
        enqueue_job(QueueJob {
            id: job_id(),
            playlist_name,
            tracks: vec![QueueTrack {
                name: needle.title.clone(),
                artist: needle.artist.clone(),
                album: needle.album.clone(),
                saved_path: Some(needle.saved_path.clone()),
                duration_ms: probe_duration_ms(&needle.saved_path),
                file_revision: file_revision(&needle.saved_path),
            }],
            created_at_unix: unix_timestamp(),
            revision: 0,
            reconcile: None,
        })?;
        ensure_queue_server()?;
        true
    } else {
        false
    };

    let result = DownloadResult {
        saved_path: needle.saved_path,
        artist: needle.artist,
        title: needle.title,
        album: needle.album,
        source_url: needle.source_url,
        playlist_queued,
    };
    Ok(BrowserResponse {
        ok: true,
        status: "saved".into(),
        message: format!("Saved {} — {}", result.artist, result.title),
        result: Some(result),
        doctor: None,
    })
}

fn browser_tool_path() -> OsString {
    let mut paths = std::env::var_os("PATH")
        .map(|value| std::env::split_paths(&value).collect::<Vec<_>>())
        .unwrap_or_default();

    let mut candidates = vec![
        PathBuf::from("/opt/homebrew/bin"),
        PathBuf::from("/usr/local/bin"),
        PathBuf::from("/usr/bin"),
        PathBuf::from("/bin"),
    ];
    if let Some(base_dirs) = directories::BaseDirs::new() {
        candidates.push(base_dirs.home_dir().join(".local/bin"));
        candidates.push(base_dirs.home_dir().join(".cargo/bin"));
        candidates.push(base_dirs.home_dir().join(".spicetify"));
    }

    for candidate in candidates {
        if candidate.is_dir() && !paths.contains(&candidate) {
            paths.push(candidate);
        }
    }

    std::env::join_paths(paths).unwrap_or_else(|_| OsString::from("/usr/bin:/bin"))
}

fn validate_source_url(value: &str) -> Result<Url> {
    let parsed = Url::parse(value).context("source URL is invalid")?;
    if !matches!(parsed.scheme(), "http" | "https") || parsed.host_str().is_none() {
        bail!("source URL must be an HTTP(S) page");
    }
    Ok(parsed)
}

fn validate_text(label: &str, value: String) -> Result<String> {
    let value = value.trim().to_owned();
    if value.is_empty() {
        bail!("{label} is required");
    }
    if value.chars().count() > MAX_FIELD_CHARS {
        bail!("{label} is too long");
    }
    Ok(value)
}

fn parse_needle_output(output: &str) -> Result<NeedleOutput> {
    output
        .lines()
        .rev()
        .find_map(|line| serde_json::from_str::<NeedleOutput>(line.trim()).ok())
        .ok_or_else(|| anyhow!("needle completed without a structured result"))
}

fn tail(value: &str, max_chars: usize) -> String {
    let chars: Vec<char> = value.trim().chars().collect();
    chars[chars.len().saturating_sub(max_chars)..]
        .iter()
        .collect()
}

fn find_needle_binary() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("NEEDLE_PATH").map(PathBuf::from) {
        if path.is_file() {
            return Some(path);
        }
    }
    if let Ok(current) = std::env::current_exe() {
        if let Some(parent) = current.parent() {
            let sibling = parent.join("needle");
            if sibling.is_file() {
                return Some(sibling);
            }
        }
    }
    find_executable("needle").or_else(|| {
        directories::BaseDirs::new()
            .map(|dirs| dirs.home_dir().join("Code/needle/target/release/needle"))
            .filter(|path| path.is_file())
    })
}

fn find_executable(name: &str) -> Option<PathBuf> {
    std::env::var_os("PATH")
        .into_iter()
        .flat_map(|paths| std::env::split_paths(&paths).collect::<Vec<_>>())
        .map(|directory| directory.join(name))
        .find(|path| path.is_file())
}

fn find_ffprobe_binary() -> Option<PathBuf> {
    if let Ok(current) = std::env::current_exe() {
        if let Some(parent) = current.parent() {
            let sibling = parent.join("ffprobe");
            if sibling.is_file() {
                return Some(sibling);
            }
        }
    }
    find_executable("ffprobe").or_else(|| {
        std::env::split_paths(&browser_tool_path())
            .map(|directory| directory.join("ffprobe"))
            .find(|path| path.is_file())
    })
}

fn parse_duration_ms(value: &str) -> Option<u64> {
    let seconds = value.trim().parse::<f64>().ok()?;
    if !seconds.is_finite() || seconds < 0.0 {
        return None;
    }
    Some((seconds * 1_000.0).round() as u64)
}

fn probe_duration_ms(path: &Path) -> Option<u64> {
    let ffprobe = find_ffprobe_binary()?;
    let output = Command::new(ffprobe)
        .args([
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
        ])
        .arg(path)
        .env("PATH", browser_tool_path())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    parse_duration_ms(&String::from_utf8_lossy(&output.stdout))
}

fn config_dir() -> Result<PathBuf> {
    ProjectDirs::from("dev", "tege", "needle")
        .map(|dirs| dirs.config_dir().to_path_buf())
        .ok_or_else(|| anyhow!("could not determine Needle config directory"))
}

fn queue_path() -> Result<PathBuf> {
    Ok(config_dir()?.join("browser-queue.json"))
}

fn receipt_dir() -> Result<PathBuf> {
    Ok(config_dir()?.join("browser-receipts"))
}

fn progress_dir() -> Result<PathBuf> {
    Ok(config_dir()?.join("browser-progress"))
}

fn receipt_path(receipts: &Path, job_id: &str) -> Result<PathBuf> {
    validate_job_id(job_id)?;
    Ok(receipts.join(format!("{job_id}.json")))
}

fn validate_job_id(value: &str) -> Result<String> {
    if value.is_empty()
        || value.len() > 200
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
    {
        bail!("job ID is invalid");
    }
    Ok(value.to_owned())
}

fn valid_spotify_uri(value: Option<String>, prefix: &str) -> Option<String> {
    value.and_then(|value| {
        let value = value.trim().to_owned();
        if value.starts_with(prefix)
            && value.len() <= MAX_FIELD_CHARS
            && !value.chars().any(char::is_whitespace)
        {
            Some(value)
        } else {
            None
        }
    })
}

fn complete_receipt(receipt: &AcknowledgementReceipt) -> bool {
    receipt.playlist_uri.is_some() && receipt.added_uri.is_some()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AcknowledgeOutcome {
    Acknowledged,
    AlreadyAcknowledged,
    Incomplete,
    Unknown,
}

fn acknowledge_job(
    queue: &Path,
    receipts: &Path,
    mut receipt: AcknowledgementReceipt,
) -> Result<AcknowledgeOutcome> {
    with_queue_lock(queue, || {
        let existing = load_receipt(receipts, &receipt.job_id)?;
        let mut jobs = load_queue(queue)?;
        if existing.as_ref().is_some_and(complete_receipt) {
            let original_len = jobs.len();
            jobs.retain(|job| job.id != receipt.job_id);
            if jobs.len() != original_len {
                save_queue(queue, &jobs)?;
            }
            return Ok(AcknowledgeOutcome::AlreadyAcknowledged);
        }

        let Some(job) = jobs.iter().find(|job| job.id == receipt.job_id) else {
            return Ok(AcknowledgeOutcome::Unknown);
        };
        if let Some(reconcile) = &job.reconcile {
            let Some(target) = &reconcile.target else {
                return Ok(AcknowledgeOutcome::Incomplete);
            };
            if receipt.revision != job.revision
                || receipt.playlist_uri.as_ref() != Some(&target.playlist_uri)
            {
                return Ok(AcknowledgeOutcome::Incomplete);
            }
            if let Some(mutation) = &reconcile.mutation {
                if receipt.added_uri.as_ref() != Some(&mutation.new_uri)
                    || receipt.added_uid != mutation.new_uid
                {
                    return Ok(AcknowledgeOutcome::Incomplete);
                }
            }
        }
        receipt.source_job_id = job
            .reconcile
            .as_ref()
            .map(|state| state.source_job_id.clone());
        receipt.track = job.tracks.first().cloned();
        receipt.revision = job.revision;
        if !complete_receipt(&receipt) {
            return Ok(AcknowledgeOutcome::Incomplete);
        }

        save_receipt(receipts, &receipt)?;
        jobs.retain(|job| job.id != receipt.job_id);
        save_queue(queue, &jobs)?;
        Ok(AcknowledgeOutcome::Acknowledged)
    })
}

fn save_receipt(receipts: &Path, receipt: &AcknowledgementReceipt) -> Result<()> {
    let job_id = validate_job_id(&receipt.job_id)?;
    fs::create_dir_all(receipts)?;
    let temporary = receipts.join(format!(".{job_id}-{}.tmp", std::process::id()));
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(&temporary)?;
    file.write_all(&serde_json::to_vec_pretty(receipt)?)?;
    file.sync_all()?;
    drop(file);
    fs::rename(&temporary, receipt_path(receipts, &job_id)?)?;
    Ok(())
}

fn load_receipt(receipts: &Path, job_id: &str) -> Result<Option<AcknowledgementReceipt>> {
    let path = receipt_path(receipts, job_id)?;
    match fs::read(path) {
        Ok(bytes) => Ok(Some(
            serde_json::from_slice(&bytes).context("invalid playlist acknowledgement receipt")?,
        )),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
    }
}

fn progress_path(progress: &Path, job_id: &str) -> Result<PathBuf> {
    validate_job_id(job_id)?;
    Ok(progress.join(format!("{job_id}.json")))
}

fn save_progress(progress: &Path, receipt: &ProgressReceipt) -> Result<()> {
    let job_id = validate_job_id(&receipt.job_id)?;
    fs::create_dir_all(progress)?;
    let temporary = progress.join(format!(".{job_id}-{}.tmp", std::process::id()));
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(&temporary)?;
    file.write_all(&serde_json::to_vec_pretty(receipt)?)?;
    file.sync_all()?;
    drop(file);
    fs::rename(&temporary, progress_path(progress, &job_id)?)?;
    Ok(())
}

fn load_progress(progress: &Path, job_id: &str) -> Result<Option<ProgressReceipt>> {
    let path = progress_path(progress, job_id)?;
    match fs::read(path) {
        Ok(bytes) => Ok(Some(
            serde_json::from_slice(&bytes).context("invalid playlist progress receipt")?,
        )),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
    }
}

fn record_progress(queue: &Path, progress: &Path, receipt: ProgressReceipt) -> Result<bool> {
    with_queue_lock(queue, || {
        if !load_queue(queue)?
            .iter()
            .any(|job| job.id == receipt.job_id)
        {
            return Ok(false);
        }
        save_progress(progress, &receipt)?;
        Ok(true)
    })
}

fn log_path() -> Result<PathBuf> {
    Ok(config_dir()?.join("browser-playlist.log"))
}

fn queue_tracks_match(left: &QueueTrack, right: &QueueTrack) -> bool {
    if !left.artist.eq_ignore_ascii_case(&right.artist)
        || !left.name.eq_ignore_ascii_case(&right.name)
    {
        return false;
    }

    match (&left.saved_path, &right.saved_path) {
        (Some(left_path), Some(right_path)) => left_path == right_path,
        (Some(_), None) | (None, Some(_)) => false,
        (None, None) => match (left.duration_ms, right.duration_ms) {
            (Some(left_duration), Some(right_duration)) => {
                left_duration == right_duration
                    && left
                        .album
                        .as_deref()
                        .unwrap_or("")
                        .eq_ignore_ascii_case(right.album.as_deref().unwrap_or(""))
            }
            (Some(_), None) | (None, Some(_)) => false,
            (None, None) => left
                .album
                .as_deref()
                .unwrap_or("")
                .eq_ignore_ascii_case(right.album.as_deref().unwrap_or("")),
        },
    }
}

fn enqueue_job(job: QueueJob) -> Result<String> {
    let path = queue_path()?;
    with_queue_lock(&path, || {
        let mut jobs = load_queue(&path)?;
        if let Some(existing) = jobs.iter().find(|existing| {
            existing.reconcile.is_none()
                && job.reconcile.is_none()
                && existing
                    .playlist_name
                    .eq_ignore_ascii_case(&job.playlist_name)
                && existing.tracks.iter().any(|existing_track| {
                    job.tracks
                        .iter()
                        .any(|track| queue_tracks_match(existing_track, track))
                })
        }) {
            return Ok(existing.id.clone());
        }
        let id = job.id.clone();
        jobs.push(job);
        save_queue(&path, &jobs)?;
        Ok(id)
    })
}

fn load_queue(path: &Path) -> Result<Vec<QueueJob>> {
    match fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes).context("invalid browser playlist queue"),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(Vec::new()),
        Err(error) => Err(error).with_context(|| format!("failed to read {}", path.display())),
    }
}

fn save_queue(path: &Path, jobs: &[QueueJob]) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("queue path has no parent"))?;
    fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(".browser-queue-{}.tmp", std::process::id()));
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(&temporary)?;
    file.write_all(&serde_json::to_vec_pretty(jobs)?)?;
    file.sync_all()?;
    drop(file);
    fs::rename(&temporary, path)?;
    Ok(())
}

fn with_queue_lock<T>(path: &Path, operation: impl FnOnce() -> Result<T>) -> Result<T> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("queue path has no parent"))?;
    fs::create_dir_all(parent)?;
    let lock_path = parent.join("browser-queue.lock");
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(&lock_path)?;
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        match lock.try_lock() {
            Ok(()) => break,
            Err(fs::TryLockError::WouldBlock) if Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(25))
            }
            Err(error) => return Err(anyhow!("failed to lock browser playlist queue: {error}")),
        }
    }
    // Keep this inode in place. Closing the file releases the OS lock even
    // after a crash or SIGTERM; deleting it would allow two owners to diverge.
    operation()
}

fn job_id() -> String {
    format!("{}-{}", unix_timestamp_nanos(), std::process::id())
}

fn unix_timestamp() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn unix_timestamp_nanos() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
}

fn ensure_queue_server() -> Result<()> {
    if TcpStream::connect(QUEUE_ADDRESS).is_ok() {
        return Ok(());
    }
    let executable = std::env::current_exe()?;
    Command::new(executable)
        .arg("serve")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .context("failed to start Spotify queue server")?;
    Ok(())
}

pub fn serve_queue() -> Result<()> {
    let server = match Server::http(QUEUE_ADDRESS) {
        Ok(server) => server,
        Err(_error) if TcpStream::connect(QUEUE_ADDRESS).is_ok() => return Ok(()),
        Err(error) => return Err(anyhow!(error.to_string())),
    };
    let mut empty_since: Option<Instant> = None;

    loop {
        if let Some(request) = server.recv_timeout(Duration::from_secs(1))? {
            handle_http_request(request)?;
        }

        if load_queue(&queue_path()?)?.is_empty() {
            let started = empty_since.get_or_insert_with(Instant::now);
            if started.elapsed() >= EMPTY_SHUTDOWN_DELAY {
                return Ok(());
            }
        } else {
            empty_since = None;
        }
    }
}

fn handle_http_request(mut request: Request) -> Result<()> {
    let origin = request
        .headers()
        .iter()
        .find(|header| header.field.equiv("Origin"))
        .map(|header| header.value.as_str().to_owned());
    if origin
        .as_deref()
        .is_some_and(|value| !ALLOWED_ORIGINS.contains(&value))
    {
        request.respond(Response::empty(StatusCode(403)))?;
        return Ok(());
    }

    if request.method() == &Method::Options {
        request.respond(cors_response(
            Response::empty(StatusCode(204)),
            origin.as_deref(),
        ))?;
        return Ok(());
    }

    match (request.method(), request.url()) {
        (&Method::Get, endpoint @ ("/queue" | "/queue?protocol=2")) => {
            let jobs = ready_jobs(&queue_path()?, &receipt_dir()?)?;
            // Older companions interpret every job as an add. Never expose a
            // replacement until the consumer explicitly requests this protocol.
            let compatible: Vec<_> = jobs
                .into_iter()
                .filter(|job| endpoint.ends_with("protocol=2") || job.reconcile.is_none())
                .collect();
            let body = serde_json::to_string(&compatible)?;
            let response = Response::from_string(body).with_header(json_header());
            request.respond(cors_response(response, origin.as_deref()))?;
        }
        (&Method::Post, "/done") => {
            let mut body = String::new();
            request
                .as_reader()
                .take(64 * 1024)
                .read_to_string(&mut body)?;
            let value: serde_json::Value = serde_json::from_str(&body)?;
            let id = value
                .get("jobId")
                .and_then(|value| value.as_str())
                .ok_or_else(|| anyhow!("jobId is required"))?;
            let id = validate_job_id(id)?;
            let receipt = AcknowledgementReceipt {
                job_id: id.clone(),
                playlist_uri: valid_spotify_uri(
                    value
                        .get("playlistUri")
                        .and_then(|value| value.as_str())
                        .map(str::to_owned),
                    "spotify:playlist:",
                ),
                added_uri: valid_spotify_uri(
                    value
                        .get("addedUri")
                        .and_then(|value| value.as_str())
                        .map(str::to_owned),
                    "spotify:local:",
                ),
                acknowledged_at_unix: unix_timestamp(),
                revision: value
                    .get("revision")
                    .and_then(|value| value.as_u64())
                    .unwrap_or(0),
                track: None,
                added_uid: value
                    .get("addedUid")
                    .and_then(|value| value.as_str())
                    .filter(|value| !value.is_empty())
                    .map(str::to_owned),
                source_job_id: None,
                detail: value
                    .get("detail")
                    .and_then(|value| value.as_str())
                    .map(str::to_owned),
            };
            let path = queue_path()?;
            match acknowledge_job(&path, &receipt_dir()?, receipt)? {
                AcknowledgeOutcome::Acknowledged | AcknowledgeOutcome::AlreadyAcknowledged => {
                    request.respond(cors_response(
                        Response::from_string("{}").with_header(json_header()),
                        origin.as_deref(),
                    ))?;
                }
                AcknowledgeOutcome::Incomplete => {
                    request.respond(cors_response(
                        Response::from_string("acknowledgement requires valid Spotify URIs")
                            .with_status_code(StatusCode(400)),
                        origin.as_deref(),
                    ))?;
                }
                AcknowledgeOutcome::Unknown => {
                    request.respond(cors_response(
                        Response::from_string("unknown job ID").with_status_code(StatusCode(404)),
                        origin.as_deref(),
                    ))?;
                }
            }
        }
        (&Method::Post, "/checkpoint") => {
            let mut body = String::new();
            request
                .as_reader()
                .take(1024 * 1024)
                .read_to_string(&mut body)?;
            let checkpoint: ReconcileCheckpoint = serde_json::from_str(&body)?;
            let updated = checkpoint_replacement(&queue_path()?, checkpoint)?;
            request.respond(cors_response(
                Response::from_string("{}")
                    .with_status_code(StatusCode(if updated { 200 } else { 409 }))
                    .with_header(json_header()),
                origin.as_deref(),
            ))?;
        }
        (&Method::Post, "/progress") => {
            let mut body = String::new();
            request
                .as_reader()
                .take(64 * 1024)
                .read_to_string(&mut body)?;
            let value: serde_json::Value = serde_json::from_str(&body)?;
            let id = value
                .get("jobId")
                .and_then(|value| value.as_str())
                .ok_or_else(|| anyhow!("jobId is required"))?;
            let id = validate_job_id(id)?;
            let detail = value
                .get("detail")
                .and_then(|value| value.as_str())
                .ok_or_else(|| anyhow!("detail is required"))?
                .to_owned();
            let detail = validate_text("progress detail", detail)?;
            let recorded = record_progress(
                &queue_path()?,
                &progress_dir()?,
                ProgressReceipt {
                    job_id: id,
                    detail,
                    updated_at_unix: unix_timestamp(),
                },
            )?;
            if recorded {
                request.respond(cors_response(
                    Response::from_string("{}").with_header(json_header()),
                    origin.as_deref(),
                ))?;
            } else {
                request.respond(cors_response(
                    Response::from_string("unknown job ID").with_status_code(StatusCode(404)),
                    origin.as_deref(),
                ))?;
            }
        }
        (&Method::Post, "/log") => {
            let mut body = String::new();
            request
                .as_reader()
                .take(64 * 1024)
                .read_to_string(&mut body)?;
            let path = log_path()?;
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent)?;
            }
            let mut log = OpenOptions::new().create(true).append(true).open(path)?;
            writeln!(log, "{} {}", unix_timestamp(), body.replace('\n', " "))?;
            request.respond(cors_response(
                Response::from_string("{}").with_header(json_header()),
                origin.as_deref(),
            ))?;
        }
        _ => {
            request.respond(cors_response(
                Response::empty(StatusCode(404)),
                origin.as_deref(),
            ))?;
        }
    }
    Ok(())
}

fn json_header() -> Header {
    Header::from_bytes("Content-Type", "application/json; charset=utf-8").expect("static header")
}

fn cors_response<R: Read>(response: Response<R>, origin: Option<&str>) -> Response<R> {
    let origin = origin
        .filter(|value| ALLOWED_ORIGINS.contains(value))
        .unwrap_or(ALLOWED_ORIGINS[0]);
    response
        .with_header(
            Header::from_bytes("Access-Control-Allow-Origin", origin).expect("static header"),
        )
        .with_header(
            Header::from_bytes("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
                .expect("static header"),
        )
        .with_header(
            Header::from_bytes("Access-Control-Allow-Headers", "Content-Type")
                .expect("static header"),
        )
        .with_header(Header::from_bytes("Vary", "Origin").expect("static header"))
}

fn read_native_message<R: Read>(mut reader: R) -> Result<Option<BrowserRequest>> {
    let mut prefix = [0_u8; 4];
    match reader.read_exact(&mut prefix) {
        Ok(()) => {}
        Err(error) if error.kind() == ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => return Err(error.into()),
    }
    let length = u32::from_le_bytes(prefix) as usize;
    if length == 0 || length > MAX_NATIVE_MESSAGE_BYTES {
        bail!("invalid native message length: {length}");
    }
    let mut body = vec![0; length];
    reader.read_exact(&mut body)?;
    Ok(Some(serde_json::from_slice(&body)?))
}

fn write_native_message<W: Write, T: Serialize>(mut writer: W, value: &T) -> Result<()> {
    let body = serde_json::to_vec(value)?;
    if body.len() > MAX_NATIVE_MESSAGE_BYTES {
        bail!("native response is too large");
    }
    writer.write_all(&(body.len() as u32).to_le_bytes())?;
    writer.write_all(&body)?;
    writer.flush()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

    #[test]
    fn browser_request_accepts_camel_case_source_url() {
        let request = serde_json::from_str::<BrowserRequest>(
            r#"{
                "action": "download",
                "sourceUrl": "https://www.youtube.com/watch?v=test",
                "artist": "Artist",
                "title": "Title",
                "playlist": {"enabled": false, "name": "Needle"}
            }"#,
        )
        .expect("browser request should match the extension wire format");

        match request {
            BrowserRequest::Download { source_url, .. } => {
                assert_eq!(source_url, "https://www.youtube.com/watch?v=test");
            }
            BrowserRequest::Doctor => panic!("expected a download request"),
        }
    }

    #[test]
    fn browser_tool_path_includes_homebrew_and_uv_tool_locations() {
        let paths = std::env::split_paths(&browser_tool_path()).collect::<Vec<_>>();

        assert!(paths.contains(&PathBuf::from("/opt/homebrew/bin")));
        if let Some(base_dirs) = directories::BaseDirs::new() {
            assert!(paths.contains(&base_dirs.home_dir().join(".local/bin")));
        }
    }

    #[test]
    fn parses_ffprobe_duration_in_milliseconds() {
        assert_eq!(parse_duration_ms("190.055420\n"), Some(190_055));
        assert_eq!(parse_duration_ms("0"), Some(0));
        assert_eq!(parse_duration_ms("N/A"), None);
        assert_eq!(parse_duration_ms("-1.0"), None);
    }

    #[test]
    fn queue_identity_prefers_saved_path_then_duration_then_album() {
        let base = QueueTrack {
            name: "Living So Italian".into(),
            artist: "Kanye West".into(),
            album: None,
            saved_path: None,
            duration_ms: None,
            file_revision: None,
        };
        let old = QueueTrack {
            duration_ms: Some(189_823),
            file_revision: None,
            ..base.clone()
        };
        let downloaded = QueueTrack {
            duration_ms: Some(190_055),
            file_revision: None,
            ..base.clone()
        };
        assert!(!queue_tracks_match(&old, &downloaded));
        assert!(queue_tracks_match(&downloaded, &downloaded));
        assert!(!queue_tracks_match(&base, &downloaded));
        let same_duration_different_album = QueueTrack {
            album: Some("REAL VERSION".into()),
            duration_ms: Some(190_055),
            file_revision: None,
            ..base.clone()
        };
        assert!(!queue_tracks_match(
            &same_duration_different_album,
            &downloaded
        ));

        let path_old = QueueTrack {
            saved_path: Some("/Music/old.mp3".into()),
            ..base.clone()
        };
        let path_new = QueueTrack {
            saved_path: Some("/Music/new.mp3".into()),
            ..base
        };
        assert!(!queue_tracks_match(&path_old, &path_new));
        assert!(queue_tracks_match(&path_new, &path_new));
    }

    #[test]
    fn queue_track_identity_fields_are_backward_compatible() {
        let job: QueueJob = serde_json::from_str(
            r#"{
                "id": "job-old",
                "playlistName": "Needle",
                "tracks": [{"name":"Song","artist":"Artist","album":null}],
                "createdAtUnix": 1
            }"#,
        )
        .unwrap();
        assert_eq!(job.tracks[0].saved_path, None);
        assert_eq!(job.tracks[0].duration_ms, None);
    }

    use std::io::Cursor;

    #[test]
    fn reads_native_message_frame() {
        let body = br#"{"action":"doctor"}"#;
        let mut framed = (body.len() as u32).to_le_bytes().to_vec();
        framed.extend_from_slice(body);
        let request = read_native_message(Cursor::new(framed)).unwrap().unwrap();
        assert!(matches!(request, BrowserRequest::Doctor));
    }

    #[test]
    fn rejects_non_http_source_urls() {
        assert!(validate_source_url("file:///tmp/song.mp3").is_err());
        assert!(validate_source_url("javascript:alert(1)").is_err());
        assert!(validate_source_url("https://www.youtube.com/watch?v=test").is_ok());
    }

    #[test]
    fn parses_last_structured_needle_line() {
        let output = "Resolving metadata...\n{\"ok\":true,\"saved_path\":\"/tmp/song.mp3\",\"artist\":\"Artist\",\"title\":\"Song\",\"album\":null,\"source_url\":\"https://example.test/song\"}\n";
        let parsed = parse_needle_output(output).unwrap();
        assert_eq!(parsed.artist, "Artist");
        assert_eq!(parsed.title, "Song");
    }

    #[test]
    fn native_response_uses_little_endian_length_prefix() {
        let response = BrowserResponse {
            ok: true,
            status: "ready".into(),
            message: "Needle bridge ready".into(),
            result: None,
            doctor: None,
        };
        let mut bytes = Vec::new();
        write_native_message(&mut bytes, &response).unwrap();
        let length = u32::from_le_bytes(bytes[..4].try_into().unwrap()) as usize;
        assert_eq!(length, bytes.len() - 4);
    }

    fn fixture_paths() -> (PathBuf, PathBuf, PathBuf) {
        let root = std::env::temp_dir().join(format!(
            "needle-browser-host-test-{}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
            NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed)
        ));
        let queue = root.join("queue.json");
        let receipts = root.join("receipts");
        fs::create_dir_all(&receipts).unwrap();
        (root, queue, receipts)
    }

    #[test]
    fn desktop_status_reports_pending_for_queued_job() {
        let (root, queue, receipts) = fixture_paths();
        save_queue(
            &queue,
            &[QueueJob {
                id: "job-pending".into(),
                playlist_name: "Needle".into(),
                tracks: vec![],
                created_at_unix: 1,
                revision: 0,
                reconcile: None,
            }],
        )
        .unwrap();
        assert_eq!(
            status_for_job(&queue, &receipts, "job-pending")
                .unwrap()
                .status,
            "pending"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn desktop_status_includes_durable_pending_detail() {
        let (root, queue, receipts) = fixture_paths();
        let progress = root.join("progress");
        save_queue(
            &queue,
            &[QueueJob {
                id: "job-detail".into(),
                playlist_name: "Needle".into(),
                tracks: vec![],
                created_at_unix: 1,
                revision: 0,
                reconcile: None,
            }],
        )
        .unwrap();
        assert!(record_progress(
            &queue,
            &progress,
            ProgressReceipt {
                job_id: "job-detail".into(),
                detail: "Open Spotify Local Files and choose the recording".into(),
                updated_at_unix: 2,
            },
        )
        .unwrap());
        let status =
            status_for_job_with_progress(&queue, &receipts, &progress, "job-detail").unwrap();
        assert_eq!(status.status, "pending");
        assert_eq!(
            status.detail.as_deref(),
            Some("Open Spotify Local Files and choose the recording")
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn progress_cannot_mint_detail_for_unknown_job() {
        let (root, queue, _receipts) = fixture_paths();
        let progress = root.join("progress");
        assert!(!record_progress(
            &queue,
            &progress,
            ProgressReceipt {
                job_id: "job-unknown".into(),
                detail: "untrusted".into(),
                updated_at_unix: 2,
            },
        )
        .unwrap());
        assert!(!progress.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn desktop_status_reports_added_only_for_complete_receipt() {
        let (root, queue, receipts) = fixture_paths();
        save_receipt(
            &receipts,
            &AcknowledgementReceipt {
                job_id: "job-added".into(),
                playlist_uri: Some("spotify:playlist:abc".into()),
                added_uri: Some("spotify:local:def".into()),
                acknowledged_at_unix: 1,
                revision: 0,
                track: None,
                added_uid: None,
                detail: None,
                source_job_id: None,
            },
        )
        .unwrap();
        let status = status_for_job(&queue, &receipts, "job-added").unwrap();
        assert_eq!(status.status, "added");
        assert_eq!(status.playlist_uri.as_deref(), Some("spotify:playlist:abc"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn desktop_status_reports_unknown_for_missing_or_incomplete_receipt() {
        let (root, queue, receipts) = fixture_paths();
        save_receipt(
            &receipts,
            &AcknowledgementReceipt {
                job_id: "job-unknown".into(),
                playlist_uri: Some("spotify:playlist:abc".into()),
                added_uri: None,
                acknowledged_at_unix: 1,
                revision: 0,
                track: None,
                added_uid: None,
                detail: None,
                source_job_id: None,
            },
        )
        .unwrap();
        assert_eq!(
            status_for_job(&queue, &receipts, "job-unknown")
                .unwrap()
                .status,
            "unknown"
        );
        assert_eq!(
            status_for_job(&queue, &receipts, "job-missing")
                .unwrap()
                .status,
            "unknown"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn receipt_retry_replaces_previous_acknowledgement_and_job_ids_are_path_safe() {
        let (root, queue, receipts) = fixture_paths();
        let first = AcknowledgementReceipt {
            job_id: "job-retry".into(),
            playlist_uri: Some("spotify:playlist:old".into()),
            added_uri: Some("spotify:local:old".into()),
            acknowledged_at_unix: 1,
            revision: 0,
            track: None,
            added_uid: None,
            detail: None,
            source_job_id: None,
        };
        save_receipt(&receipts, &first).unwrap();
        let second = AcknowledgementReceipt {
            playlist_uri: Some("spotify:playlist:new".into()),
            added_uri: Some("spotify:local:new".into()),
            acknowledged_at_unix: 2,
            ..first
        };
        save_receipt(&receipts, &second).unwrap();
        assert_eq!(
            status_for_job(&queue, &receipts, "job-retry")
                .unwrap()
                .added_uri
                .as_deref(),
            Some("spotify:local:new")
        );
        assert!(validate_job_id("../escape").is_err());
        assert!(validate_job_id("job-retry").is_ok());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn desktop_command_input_is_bounded() {
        let input = vec![b'x'; MAX_NATIVE_MESSAGE_BYTES + 1];
        let result = run_desktop_command("status", Cursor::new(input), Vec::new());
        assert!(result.is_err());
    }

    fn queued_job(id: &str) -> QueueJob {
        QueueJob {
            id: id.into(),
            playlist_name: "Needle".into(),
            tracks: vec![],
            created_at_unix: 1,
            revision: 0,
            reconcile: None,
        }
    }

    fn receipt(id: &str, complete: bool) -> AcknowledgementReceipt {
        AcknowledgementReceipt {
            job_id: id.into(),
            playlist_uri: complete.then(|| "spotify:playlist:test".into()),
            added_uri: complete.then(|| "spotify:local:test".into()),
            acknowledged_at_unix: 1,
            revision: 0,
            track: None,
            added_uid: None,
            detail: None,
            source_job_id: None,
        }
    }

    fn metadata(name: &str) -> QueueTrack {
        QueueTrack {
            name: name.into(),
            artist: "Artist".into(),
            album: Some("Album".into()),
            saved_path: Some(PathBuf::from("/tmp/same-recording.mp3")),
            duration_ms: Some(190000),
            file_revision: Some(name.into()),
        }
    }

    fn confirmed_source(receipts: &Path) {
        let mut source = receipt("original", true);
        source.track = Some(metadata("A"));
        source.added_uid = Some("original-row".into());
        save_receipt(receipts, &source).unwrap();
    }

    fn request(previous: &str, name: &str) -> DesktopReconcileRequest {
        DesktopReconcileRequest {
            previous_job_id: previous.into(),
            track: metadata(name),
            previous_track: metadata("A"),
        }
    }

    fn insertion() -> ReplacementMutation {
        ReplacementMutation {
            phase: ReplacementPhase::Adding,
            old_uid: "original-row".into(),
            new_uri: "spotify:local:B".into(),
            new_uid: None,
            original_rows: vec![PlaylistRow {
                uri: "spotify:local:test".into(),
                uid: "original-row".into(),
            }],
        }
    }

    #[test]
    fn reconciliation_uses_exact_receipt_and_retains_current_file_snapshot() {
        let (root, queue, receipts) = fixture_paths();
        confirmed_source(&receipts);
        let id = reconcile_job(&queue, &receipts, request("original", "B")).unwrap();
        let jobs = load_queue(&queue).unwrap();
        let target = jobs[0].reconcile.as_ref().unwrap().target.as_ref().unwrap();
        assert_eq!(target.playlist_uri, "spotify:playlist:test");
        assert_eq!(target.added_uri, "spotify:local:test");
        assert_eq!(target.added_uid.as_deref(), Some("original-row"));
        assert_eq!(jobs[0].tracks[0], metadata("B"));
        let mut done = receipt(&id, true);
        done.revision = jobs[0].revision;
        done.added_uri = Some("spotify:local:B".into());
        assert_eq!(
            acknowledge_job(&queue, &receipts, done).unwrap(),
            AcknowledgeOutcome::Acknowledged
        );
        assert_eq!(
            load_receipt(&receipts, &id).unwrap().unwrap().track,
            Some(metadata("B"))
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn unstarted_metadata_changes_coalesce_and_stale_acknowledgements_are_rejected() {
        let (root, queue, receipts) = fixture_paths();
        confirmed_source(&receipts);
        let id = reconcile_job(&queue, &receipts, request("original", "B")).unwrap();
        assert_eq!(
            reconcile_job(&queue, &receipts, request(&id, "C")).unwrap(),
            id
        );
        let jobs = load_queue(&queue).unwrap();
        assert_eq!(jobs.len(), 1);
        assert_eq!(jobs[0].tracks[0].name, "C");
        assert_eq!(jobs[0].revision, 2);
        let mut stale = receipt(&id, true);
        stale.revision = 1;
        assert_eq!(
            acknowledge_job(&queue, &receipts, stale).unwrap(),
            AcknowledgeOutcome::Incomplete
        );
        assert!(!checkpoint_replacement(
            &queue,
            ReconcileCheckpoint {
                job_id: id,
                revision: 1,
                mutation: insertion()
            }
        )
        .unwrap());
        assert_eq!(load_queue(&queue).unwrap().len(), 1);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn metadata_changes_during_insertion_serialize_after_durable_receipt() {
        let (root, queue, receipts) = fixture_paths();
        confirmed_source(&receipts);
        let b = reconcile_job(&queue, &receipts, request("original", "B")).unwrap();
        let mut mutation = insertion();
        assert!(checkpoint_replacement(
            &queue,
            ReconcileCheckpoint {
                job_id: b.clone(),
                revision: 1,
                mutation: mutation.clone()
            }
        )
        .unwrap());
        let c = reconcile_job(&queue, &receipts, request(&b, "C")).unwrap();
        assert_ne!(b, c);
        assert_eq!(ready_jobs(&queue, &receipts).unwrap().len(), 1);
        mutation.new_uid = Some("B-row".into());
        mutation.phase = ReplacementPhase::Removing;
        assert!(checkpoint_replacement(
            &queue,
            ReconcileCheckpoint {
                job_id: b.clone(),
                revision: 1,
                mutation
            }
        )
        .unwrap());
        let mut done = receipt(&b, true);
        done.revision = 1;
        done.added_uri = Some("spotify:local:B".into());
        done.added_uid = Some("B-row".into());
        assert_eq!(
            acknowledge_job(&queue, &receipts, done).unwrap(),
            AcknowledgeOutcome::Acknowledged
        );
        let ready = ready_jobs(&queue, &receipts).unwrap();
        assert_eq!(ready.len(), 1);
        assert_eq!(ready[0].id, c);
        let target = ready[0]
            .reconcile
            .as_ref()
            .unwrap()
            .target
            .as_ref()
            .unwrap();
        assert_eq!(target.added_uri, "spotify:local:B");
        assert_eq!(target.added_uid.as_deref(), Some("B-row"));
        assert_eq!(ready[0].tracks[0].name, "C");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn missing_receipts_and_wrong_file_associations_cannot_mint_replacement_targets() {
        let (root, queue, receipts) = fixture_paths();
        assert!(reconcile_job(&queue, &receipts, request("missing", "B")).is_err());
        confirmed_source(&receipts);
        let mut wrong = request("original", "B");
        wrong.track.saved_path = Some(PathBuf::from("/tmp/another.mp3"));
        assert!(reconcile_job(&queue, &receipts, wrong).is_err());
        assert!(load_queue(&queue).unwrap().is_empty());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn legacy_receipt_adoption_requires_known_job_and_same_file() {
        let (root, queue, receipts) = fixture_paths();
        save_receipt(&receipts, &receipt("original", true)).unwrap();
        let mut wrong = request("original", "B");
        wrong.previous_track.saved_path = Some(PathBuf::from("/tmp/other.mp3"));
        assert!(reconcile_job(&queue, &receipts, wrong).is_err());
        let id = reconcile_job(&queue, &receipts, request("original", "B")).unwrap();
        assert_ne!(id, "original");
        let adopted = load_receipt(&receipts, "original").unwrap().unwrap();
        assert_eq!(adopted.track.unwrap().saved_path, metadata("A").saved_path);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn unchanged_snapshot_is_idempotent_and_file_revision_alone_triggers_reconciliation() {
        let (root, queue, receipts) = fixture_paths();
        confirmed_source(&receipts);
        assert_eq!(
            reconcile_job(&queue, &receipts, request("original", "A")).unwrap(),
            "original"
        );
        assert!(load_queue(&queue).unwrap().is_empty());
        let mut artwork = request("original", "A");
        artwork.track.file_revision = Some("new-embedded-cover".into());
        assert_ne!(
            reconcile_job(&queue, &receipts, artwork).unwrap(),
            "original"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn queue_and_receipts_from_previous_versions_remain_decodable() {
        let job: QueueJob = serde_json::from_str(
            r#"{"id":"legacy","playlistName":"Needle","tracks":[],"createdAtUnix":1}"#,
        )
        .unwrap();
        assert!(job.reconcile.is_none());
        assert_eq!(job.revision, 0);
        let receipt: AcknowledgementReceipt = serde_json::from_str(r#"{"jobId":"legacy","playlistUri":"spotify:playlist:p","addedUri":"spotify:local:t","acknowledgedAtUnix":1}"#).unwrap();
        assert!(receipt.track.is_none());
        assert!(receipt.added_uid.is_none());
    }

    #[test]
    fn stale_history_follows_pending_and_completed_successor_receipts() {
        let (root, queue, receipts) = fixture_paths();
        confirmed_source(&receipts);
        let b = reconcile_job(&queue, &receipts, request("original", "B")).unwrap();
        assert_eq!(
            reconcile_job(&queue, &receipts, request("original", "C")).unwrap(),
            b
        );
        assert_eq!(load_queue(&queue).unwrap()[0].tracks[0].name, "C");
        let mut done = receipt(&b, true);
        done.revision = 2;
        done.added_uri = Some("spotify:local:C".into());
        done.added_uid = Some("C-row".into());
        acknowledge_job(&queue, &receipts, done).unwrap();
        let d = reconcile_job(&queue, &receipts, request("original", "D")).unwrap();
        let jobs = load_queue(&queue).unwrap();
        let target = jobs[0].reconcile.as_ref().unwrap().target.as_ref().unwrap();
        assert_eq!(jobs[0].id, d);
        assert_eq!(target.added_uri, "spotify:local:C");
        assert_eq!(target.added_uid.as_deref(), Some("C-row"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn legacy_unknown_file_revision_requires_safe_current_index_confirmation() {
        let (root, queue, receipts) = fixture_paths();
        save_receipt(&receipts, &receipt("original", true)).unwrap();
        let mut same_tags = request("original", "A");
        same_tags.previous_track.file_revision = None;
        let id = reconcile_job(&queue, &receipts, same_tags).unwrap();
        assert_ne!(id, "original");
        assert_eq!(load_queue(&queue).unwrap().len(), 1);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn queue_lock_child_fixture() {
        let Ok(root) = std::env::var("NEEDLE_TEST_LOCK_CHILD") else {
            return;
        };
        let path = PathBuf::from(root);
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(path.join("browser-queue.lock"))
            .unwrap();
        lock.try_lock().unwrap();
        fs::write(path.join("held"), b"ready").unwrap();
        loop {
            thread::sleep(Duration::from_secs(1));
        }
    }

    #[test]
    fn killed_queue_owner_releases_lock_without_stale_marker_cleanup() {
        let (root, queue, _receipts) = fixture_paths();
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "tests::queue_lock_child_fixture", "--nocapture"])
            .env("NEEDLE_TEST_LOCK_CHILD", &root)
            .stdout(Stdio::null())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while !root.join("held").exists() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
        }
        let held = root.join("held").exists();
        child.kill().unwrap();
        child.wait().unwrap();
        assert!(held, "child acquired the real OS lock");
        assert!(root.join("browser-queue.lock").exists());
        with_queue_lock(&queue, || {
            save_queue(&queue, &[])?;
            Ok(())
        })
        .unwrap();
        assert!(load_queue(&queue).unwrap().is_empty());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn incomplete_acknowledgement_preserves_pending_job() {
        let (root, queue, receipts) = fixture_paths();
        save_queue(&queue, &[queued_job("job-incomplete")]).unwrap();
        assert_eq!(
            acknowledge_job(&queue, &receipts, receipt("job-incomplete", false)).unwrap(),
            AcknowledgeOutcome::Incomplete
        );
        assert_eq!(load_queue(&queue).unwrap().len(), 1);
        assert!(load_receipt(&receipts, "job-incomplete").unwrap().is_none());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn unknown_acknowledgement_cannot_mint_receipt() {
        let (root, queue, receipts) = fixture_paths();
        assert_eq!(
            acknowledge_job(&queue, &receipts, receipt("job-unknown", true)).unwrap(),
            AcknowledgeOutcome::Unknown
        );
        assert!(load_receipt(&receipts, "job-unknown").unwrap().is_none());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn valid_acknowledgement_receipts_then_removes_job_and_retries_idempotently() {
        let (root, queue, receipts) = fixture_paths();
        save_queue(&queue, &[queued_job("job-valid")]).unwrap();
        assert_eq!(
            acknowledge_job(&queue, &receipts, receipt("job-valid", true)).unwrap(),
            AcknowledgeOutcome::Acknowledged
        );
        assert!(load_queue(&queue).unwrap().is_empty());
        assert!(load_receipt(&receipts, "job-valid").unwrap().is_some());
        assert_eq!(
            acknowledge_job(&queue, &receipts, receipt("job-valid", false)).unwrap(),
            AcknowledgeOutcome::AlreadyAcknowledged
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn complete_receipt_reconciles_a_lingering_queue_job() {
        let (root, queue, receipts) = fixture_paths();
        save_queue(&queue, &[queued_job("job-crashed")]).unwrap();
        save_receipt(&receipts, &receipt("job-crashed", true)).unwrap();
        assert_eq!(
            acknowledge_job(&queue, &receipts, receipt("job-crashed", false)).unwrap(),
            AcknowledgeOutcome::AlreadyAcknowledged
        );
        assert!(load_queue(&queue).unwrap().is_empty());
        fs::remove_dir_all(root).unwrap();
    }
}
