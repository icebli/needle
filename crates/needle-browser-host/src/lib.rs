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

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct QueueTrack {
    name: String,
    artist: String,
    album: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    saved_path: Option<PathBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    duration_ms: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct QueueJob {
    id: String,
    playlist_name: String,
    tracks: Vec<QueueTrack>,
    created_at_unix: u64,
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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AcknowledgementReceipt {
    job_id: String,
    playlist_uri: Option<String>,
    added_uri: Option<String>,
    acknowledged_at_unix: u64,
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

pub fn run_desktop_command<R: Read, W: Write>(command: &str, mut reader: R, mut writer: W) -> Result<()> {
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
    let request: DesktopEnqueueRequest = serde_json::from_str(body).context("invalid enqueue JSON")?;
    let artist = validate_text("artist", request.artist)?;
    let title = validate_text("title", request.title)?;
    let album = request.album.map(|value| validate_text("album", value)).transpose()?;
    let playlist_name = validate_text("playlist name", request.playlist_name)?;
    let duration_ms = request.saved_path.as_deref().and_then(probe_duration_ms);
    let job = QueueJob {
        id: job_id(),
        playlist_name,
        tracks: vec![QueueTrack {
            name: title,
            artist,
            album,
            saved_path: request.saved_path,
            duration_ms,
        }],
        created_at_unix: unix_timestamp(),
    };
    let job_id = enqueue_job(job)?;
    ensure_queue_server()?;
    Ok(DesktopEnqueueResponse { ok: true, job_id })
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
                detail: None,
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
            }],
            created_at_unix: unix_timestamp(),
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
    receipt: AcknowledgementReceipt,
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

        if !jobs.iter().any(|job| job.id == receipt.job_id) {
            return Ok(AcknowledgeOutcome::Unknown);
        }
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
        Ok(bytes) => Ok(Some(serde_json::from_slice(&bytes).context("invalid playlist acknowledgement receipt")?)),
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
        Ok(bytes) => Ok(Some(serde_json::from_slice(&bytes).context("invalid playlist progress receipt")?)),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
    }
}

fn record_progress(queue: &Path, progress: &Path, receipt: ProgressReceipt) -> Result<bool> {
    with_queue_lock(queue, || {
        if !load_queue(queue)?.iter().any(|job| job.id == receipt.job_id) {
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
                    && left.album.as_deref().unwrap_or("").eq_ignore_ascii_case(
                        right.album.as_deref().unwrap_or(""),
                    )
            }
            (Some(_), None) | (None, Some(_)) => false,
            (None, None) => left.album.as_deref().unwrap_or("").eq_ignore_ascii_case(
                right.album.as_deref().unwrap_or(""),
            ),
        },
    }
}

fn enqueue_job(job: QueueJob) -> Result<String> {
    let path = queue_path()?;
    with_queue_lock(&path, || {
        let mut jobs = load_queue(&path)?;
        if let Some(existing) = jobs.iter().find(|existing| {
            existing
                .playlist_name
                .eq_ignore_ascii_case(&job.playlist_name)
                && existing.tracks.iter().any(|existing_track| {
                    job.tracks.iter().any(|track| queue_tracks_match(existing_track, track))
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
    fs::write(&temporary, serde_json::to_vec_pretty(jobs)?)?;
    fs::rename(&temporary, path)?;
    Ok(())
}

struct QueueLock(PathBuf);

impl Drop for QueueLock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

fn with_queue_lock<T>(path: &Path, operation: impl FnOnce() -> Result<T>) -> Result<T> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("queue path has no parent"))?;
    fs::create_dir_all(parent)?;
    let lock_path = parent.join("browser-queue.lock");
    let deadline = Instant::now() + Duration::from_secs(3);
    let _lock = loop {
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&lock_path)
        {
            Ok(_) => break QueueLock(lock_path.clone()),
            Err(error) if error.kind() == ErrorKind::AlreadyExists && Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(25));
            }
            Err(error) => return Err(error).context("failed to lock browser playlist queue"),
        }
    };
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
        (&Method::Get, "/queue") => {
            let body = serde_json::to_string(&load_queue(&queue_path()?)?)?;
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
                    value.get("playlistUri").and_then(|value| value.as_str()).map(str::to_owned),
                    "spotify:playlist:",
                ),
                added_uri: valid_spotify_uri(
                    value.get("addedUri").and_then(|value| value.as_str()).map(str::to_owned),
                    "spotify:local:",
                ),
                acknowledged_at_unix: unix_timestamp(),
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
        };
        let old = QueueTrack {
            duration_ms: Some(189_823),
            ..base.clone()
        };
        let downloaded = QueueTrack {
            duration_ms: Some(190_055),
            ..base.clone()
        };
        assert!(!queue_tracks_match(&old, &downloaded));
        assert!(queue_tracks_match(&downloaded, &downloaded));
        assert!(!queue_tracks_match(&base, &downloaded));
        let same_duration_different_album = QueueTrack {
            album: Some("REAL VERSION".into()),
            duration_ms: Some(190_055),
            ..base.clone()
        };
        assert!(!queue_tracks_match(&same_duration_different_album, &downloaded));

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
            }],
        )
        .unwrap();
        assert_eq!(status_for_job(&queue, &receipts, "job-pending").unwrap().status, "pending");
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
        let status = status_for_job_with_progress(&queue, &receipts, &progress, "job-detail").unwrap();
        assert_eq!(status.status, "pending");
        assert_eq!(status.detail.as_deref(), Some("Open Spotify Local Files and choose the recording"));
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
            },
        )
        .unwrap();
        assert_eq!(status_for_job(&queue, &receipts, "job-unknown").unwrap().status, "unknown");
        assert_eq!(status_for_job(&queue, &receipts, "job-missing").unwrap().status, "unknown");
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
        };
        save_receipt(&receipts, &first).unwrap();
        let second = AcknowledgementReceipt {
            playlist_uri: Some("spotify:playlist:new".into()),
            added_uri: Some("spotify:local:new".into()),
            acknowledged_at_unix: 2,
            ..first
        };
        save_receipt(&receipts, &second).unwrap();
        assert_eq!(status_for_job(&queue, &receipts, "job-retry").unwrap().added_uri.as_deref(), Some("spotify:local:new"));
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
        }
    }

    fn receipt(id: &str, complete: bool) -> AcknowledgementReceipt {
        AcknowledgementReceipt {
            job_id: id.into(),
            playlist_uri: complete.then(|| "spotify:playlist:test".into()),
            added_uri: complete.then(|| "spotify:local:test".into()),
            acknowledged_at_unix: 1,
        }
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
