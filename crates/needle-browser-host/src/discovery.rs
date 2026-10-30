use anyhow::{anyhow, bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::fs::File;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tiny_http::{Header, Method, Request, Response, Server, StatusCode};

const DISCOVERY_ADDRESS: &str = "127.0.0.1:29879";
const MAX_BODY_BYTES: usize = 256 * 1024;
const MAX_QUERY_CHARS: usize = 200;
const MAX_ARTISTS: usize = 100;
const MAX_TRACKS: usize = 10;
const REQUEST_DEADLINE: Duration = Duration::from_secs(30);
const SERVER_IDLE_TIMEOUT: Duration = Duration::from_secs(35);
const ALLOWED_ORIGINS: [&str; 3] = [
    "https://xpui.app.spotify.com",
    "https://xpui.app",
    "https://open.spotify.com",
];

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiscoveryRequest {
    pub nonce: String,
    pub operation: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub artist: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub created_at_ms: u128,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DiscoveryArtist {
    pub id: String,
    pub name: String,
    pub uri: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DiscoveryTrackArtist {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DiscoveryTrack {
    pub id: String,
    pub name: String,
    pub uri: String,
    pub artists: Vec<DiscoveryTrackArtist>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DiscoveryResponse {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub artists: Option<Vec<DiscoveryArtist>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tracks: Option<Vec<DiscoveryTrack>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Default)]
struct Mailbox {
    request: Option<DiscoveryRequest>,
    result: Option<(String, DiscoveryResponse)>,
}

/// Run a synchronous discovery request for the desktop CLI. The companion
/// performs the Spotify API call inside Spotify; this process never receives
/// or stores an access token.
pub fn run_discovery_command(args: &[String]) -> Result<()> {
    let request = match args {
        [operation] if operation == "top-artists" => new_request(operation, None, None),
        [operation, artist, title] if operation == "catalog" => {
            new_request(operation, Some(artist), Some(title))
        }
        _ => {
            write_json(&error_response(
                "usage: discover top-artists | discover catalog <artist> <title>",
            ))?;
            return Ok(());
        }
    }?;

    let response = match request_and_wait(&request) {
        Ok(response) => response,
        Err(error) => error_response(&error.to_string()),
    };
    write_json(&response)
}

pub fn serve_discovery() -> Result<()> {
    let server = match Server::http(DISCOVERY_ADDRESS) {
        Ok(server) => server,
        Err(error) if TcpStream::connect(DISCOVERY_ADDRESS).is_ok() => {
            return Err(anyhow!("discovery bridge already running: {error}"));
        }
        Err(error) => return Err(anyhow!(error.to_string())),
    };
    let mut mailbox = Mailbox::default();
    let mut empty_since = Instant::now();

    loop {
        if let Some(request) = server.recv_timeout(Duration::from_millis(250))? {
            // Malformed input must be isolated to this request. The companion
            // can retry a closed connection while the bridge stays available.
            let _ = handle_http_request(request, &mut mailbox);
            empty_since = Instant::now();
        }
        expire_request(&mut mailbox);
        if mailbox.request.is_none()
            && mailbox.result.is_none()
            && empty_since.elapsed() >= SERVER_IDLE_TIMEOUT
        {
            return Ok(());
        }
    }
}

fn new_request(
    operation: &str,
    artist: Option<&String>,
    title: Option<&String>,
) -> Result<DiscoveryRequest> {
    if operation != "top-artists" && operation != "catalog" {
        bail!("unsupported discovery operation")
    }
    let artist = artist
        .map(|value| validate_query("artist", value))
        .transpose()?;
    let title = title
        .map(|value| validate_query("title", value))
        .transpose()?;
    if operation == "catalog" && (artist.is_none() || title.is_none()) {
        bail!("catalog discovery requires artist and title")
    }
    Ok(DiscoveryRequest {
        nonce: nonce(),
        operation: operation.to_owned(),
        artist,
        title,
        created_at_ms: now_millis(),
    })
}

fn validate_query(field: &str, value: &str) -> Result<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() || trimmed.chars().count() > MAX_QUERY_CHARS {
        bail!("{field} must be between 1 and {MAX_QUERY_CHARS} characters")
    }
    Ok(trimmed.to_owned())
}

fn request_and_wait(request: &DiscoveryRequest) -> Result<DiscoveryResponse> {
    ensure_server()?;
    let body = serde_json::to_vec(request)?;
    let response = http_request("POST", "/request", &body)?;
    if response.status != 200 {
        bail!(
            "Spotify discovery bridge rejected the request ({})",
            response.status
        )
    }
    let deadline = Instant::now() + REQUEST_DEADLINE;
    while Instant::now() < deadline {
        thread::sleep(Duration::from_millis(250));
        let response = http_request("GET", &format!("/result?nonce={}", request.nonce), &[])?;
        if response.status != 200 {
            continue;
        }
        let value: serde_json::Value = serde_json::from_slice(&response.body)?;
        if value.get("pending").and_then(|value| value.as_bool()) == Some(true) {
            continue;
        }
        return Ok(serde_json::from_value(value)?);
    }
    Ok(error_response(
        "Spotify did not respond before the 30 second deadline",
    ))
}

fn ensure_server() -> Result<()> {
    if TcpStream::connect(DISCOVERY_ADDRESS).is_ok() {
        return Ok(());
    }
    let executable = std::env::current_exe()?;
    Command::new(executable)
        .arg("discover-serve")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .context("failed to start Spotify discovery bridge")?;
    for _ in 0..20 {
        if TcpStream::connect(DISCOVERY_ADDRESS).is_ok() {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(50));
    }
    bail!("Spotify discovery bridge did not start")
}

fn handle_http_request(mut request: Request, mailbox: &mut Mailbox) -> Result<()> {
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
        (&Method::Post, "/request") => {
            let body = read_body(&mut request)?;
            let mut value: DiscoveryRequest =
                serde_json::from_slice(&body).context("invalid discovery request")?;
            validate_request(&value)?;
            // The timestamp is an expiry hint, never client authority. A caller
            // must not be able to submit a future timestamp and pin the mailbox.
            value = server_timestamp(value);
            expire_request(mailbox);
            if mailbox.request.is_some() {
                return respond_json(
                    request,
                    StatusCode(409),
                    &error_response("another discovery request is already pending"),
                    origin.as_deref(),
                );
            }
            mailbox.request = Some(value);
            respond_json(
                request,
                StatusCode(200),
                &serde_json::json!({"ok": true}),
                origin.as_deref(),
            )?;
        }
        (&Method::Get, "/request") => {
            let value = serde_json::json!({"ok": true, "request": mailbox.request});
            respond_json(request, StatusCode(200), &value, origin.as_deref())?;
        }
        (&Method::Post, "/result") => {
            let body = read_body(&mut request)?;
            let value: serde_json::Value =
                serde_json::from_slice(&body).context("invalid discovery result")?;
            let nonce = value
                .get("nonce")
                .and_then(|value| value.as_str())
                .ok_or_else(|| anyhow!("result nonce is required"))?;
            let pending = mailbox
                .request
                .as_ref()
                .ok_or_else(|| anyhow!("no discovery request is pending"))?;
            if nonce != pending.nonce {
                return respond_json(
                    request,
                    StatusCode(409),
                    &error_response("discovery nonce does not match"),
                    origin.as_deref(),
                );
            }
            let result: DiscoveryResponse =
                serde_json::from_value(value.get("result").cloned().unwrap_or(value.clone()))
                    .context("invalid discovery response")?;
            validate_result(&result, &pending.operation)?;
            mailbox.result = Some((nonce.to_owned(), result));
            mailbox.request = None;
            respond_json(
                request,
                StatusCode(200),
                &serde_json::json!({"ok": true}),
                origin.as_deref(),
            )?;
        }
        (&Method::Get, url) if url.starts_with("/result?nonce=") => {
            let nonce = url.trim_start_matches("/result?nonce=");
            if let Some((stored_nonce, result)) = mailbox.result.as_ref() {
                if stored_nonce == nonce {
                    let result = result.clone();
                    mailbox.result = None;
                    return respond_json(request, StatusCode(200), &result, origin.as_deref());
                }
            }
            respond_json(
                request,
                StatusCode(200),
                &serde_json::json!({"pending": true}),
                origin.as_deref(),
            )?;
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

fn validate_request(request: &DiscoveryRequest) -> Result<()> {
    if request.nonce.is_empty() || request.nonce.len() > 100 {
        bail!("invalid discovery nonce");
    }
    match request.operation.as_str() {
        "top-artists" if request.artist.is_none() && request.title.is_none() => Ok(()),
        "catalog" => {
            validate_query("artist", request.artist.as_deref().unwrap_or(""))?;
            validate_query("title", request.title.as_deref().unwrap_or(""))?;
            Ok(())
        }
        _ => bail!("unsupported discovery operation"),
    }
}

fn validate_result(result: &DiscoveryResponse, operation: &str) -> Result<()> {
    if !result.ok {
        return Ok(());
    }
    match operation {
        "top-artists" => {
            let items = result
                .artists
                .as_ref()
                .ok_or_else(|| anyhow!("artists are missing"))?;
            if items.len() > MAX_ARTISTS {
                bail!("discovery response exceeded the artist limit");
            }
            if items
                .iter()
                .any(|item| item.id.is_empty() || item.name.is_empty() || item.uri.is_empty())
            {
                bail!("discovery response contained an incomplete artist");
            }
            Ok(())
        }
        "catalog" => {
            let items = result
                .tracks
                .as_ref()
                .ok_or_else(|| anyhow!("tracks are missing"))?;
            if items.len() > MAX_TRACKS {
                bail!("discovery response exceeded the track limit");
            }
            if items.iter().any(|item| {
                item.id.is_empty()
                    || item.name.is_empty()
                    || item.uri.is_empty()
                    || item.artists.is_empty()
                    || item.artists.len() > 10
                    || item
                        .artists
                        .iter()
                        .any(|artist| artist.id.is_empty() || artist.name.is_empty())
            }) {
                bail!("discovery response contained an incomplete track");
            }
            Ok(())
        }
        _ => bail!("discovery response exceeded the result limit"),
    }
}

fn expire_request(mailbox: &mut Mailbox) {
    if mailbox.request.as_ref().is_some_and(|request| {
        now_millis().saturating_sub(request.created_at_ms) > REQUEST_DEADLINE.as_millis()
    }) {
        mailbox.request = None;
    }
}

fn server_timestamp(mut request: DiscoveryRequest) -> DiscoveryRequest {
    request.created_at_ms = now_millis();
    request
}

fn read_body(request: &mut Request) -> Result<Vec<u8>> {
    let mut body = Vec::new();
    request
        .as_reader()
        .take((MAX_BODY_BYTES + 1) as u64)
        .read_to_end(&mut body)?;
    if body.len() > MAX_BODY_BYTES {
        bail!("discovery request is too large");
    }
    Ok(body)
}

fn respond_json<T: Serialize>(
    request: Request,
    status: StatusCode,
    value: &T,
    origin: Option<&str>,
) -> Result<()> {
    let body = serde_json::to_vec(value)?;
    if body.len() > MAX_BODY_BYTES {
        bail!("discovery response is too large");
    }
    request.respond(cors_response(
        Response::from_data(body)
            .with_status_code(status)
            .with_header(json_header()),
        origin,
    ))?;
    Ok(())
}

fn http_request(method: &str, path: &str, body: &[u8]) -> Result<HttpResponse> {
    let mut stream = TcpStream::connect(DISCOVERY_ADDRESS)?;
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    write!(stream, "{method} {path} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len())?;
    stream.write_all(body)?;
    stream.flush()?;
    let mut bytes = Vec::new();
    stream
        .take((MAX_BODY_BYTES + 16 * 1024) as u64)
        .read_to_end(&mut bytes)?;
    let split = bytes
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .ok_or_else(|| anyhow!("invalid discovery bridge response"))?;
    let headers = String::from_utf8_lossy(&bytes[..split]);
    let status = headers
        .split_whitespace()
        .nth(1)
        .and_then(|value| value.parse().ok())
        .unwrap_or(500);
    Ok(HttpResponse {
        status,
        body: bytes[split + 4..].to_vec(),
    })
}

struct HttpResponse {
    status: u16,
    body: Vec<u8>,
}

fn write_json<T: Serialize>(value: &T) -> Result<()> {
    serde_json::to_writer(std::io::stdout(), value)?;
    println!();
    Ok(())
}

fn error_response(error: &str) -> DiscoveryResponse {
    DiscoveryResponse {
        ok: false,
        artists: None,
        tracks: None,
        error: Some(error.chars().take(MAX_QUERY_CHARS).collect()),
    }
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

fn nonce() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let mut random = [0_u8; 16];
    if let Ok(mut source) = File::open("/dev/urandom") {
        if source.read_exact(&mut random).is_ok() {
            return random.iter().map(|byte| format!("{byte:02x}")).collect();
        }
    }
    format!(
        "{:x}-{:x}-{:x}",
        now_millis(),
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    )
}

fn now_millis() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_one_hundred_artists_and_rejects_oversized_results() {
        let mut response = DiscoveryResponse {
            ok: true,
            artists: Some(
                (0..100)
                    .map(|index| DiscoveryArtist {
                        id: format!("artist-{index}"),
                        name: format!("Artist {index}"),
                        uri: format!("spotify:artist:{index}"),
                        image_url: None,
                    })
                    .collect(),
            ),
            tracks: None,
            error: None,
        };
        assert!(validate_result(&response, "top-artists").is_ok());
        let artist = response.artists.as_ref().unwrap()[0].clone();
        response.artists.as_mut().unwrap().push(artist);
        assert!(validate_result(&response, "top-artists").is_err());
    }

    #[test]
    fn validates_supported_requests_and_bounds_queries() {
        let artist = "Artist".to_owned();
        let title = "Title".to_owned();
        let request = new_request("catalog", Some(&artist), Some(&title)).unwrap();
        assert_eq!(request.operation, "catalog");
        assert!(new_request("top-artists", None, None).is_ok());
        assert!(new_request(
            "catalog",
            Some(&"x".repeat(MAX_QUERY_CHARS + 1)),
            Some(&title)
        )
        .is_err());
    }

    #[test]
    fn rejects_wrong_operation_result_shape_and_accepts_bounded_error() {
        let response = DiscoveryResponse {
            ok: true,
            artists: Some(vec![]),
            tracks: None,
            error: None,
        };
        assert!(validate_result(&response, "top-artists").is_ok());
        assert!(validate_result(&response, "catalog").is_err());
        let error = error_response(&"x".repeat(MAX_QUERY_CHARS + 100));
        assert!(error.error.unwrap().chars().count() <= MAX_QUERY_CHARS);
    }

    #[test]
    fn server_timestamp_replaces_untrusted_future_request_time() {
        let future = DiscoveryRequest {
            nonce: "nonce".to_owned(),
            operation: "top-artists".to_owned(),
            artist: None,
            title: None,
            created_at_ms: now_millis() + REQUEST_DEADLINE.as_millis() * 10,
        };
        let stamped = server_timestamp(future);
        assert!(stamped.created_at_ms <= now_millis());
        let mut mailbox = Mailbox {
            request: Some(stamped),
            result: None,
        };
        mailbox.request.as_mut().unwrap().created_at_ms =
            now_millis().saturating_sub(REQUEST_DEADLINE.as_millis() + 1);
        expire_request(&mut mailbox);
        assert!(mailbox.request.is_none());
    }
}
