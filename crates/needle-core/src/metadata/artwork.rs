use super::TrackMetadata;
use anyhow::{bail, Result};
use reqwest::{Client, StatusCode, Url};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{Arc, LazyLock, Mutex, Weak},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tracing::debug;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArtworkReference {
    pub url: String,
    pub provider: String,
    pub release_id: Option<String>,
    pub release_group_id: Option<String>,
}

pub(super) struct ArtworkResolver {
    client: Client,
    base: String,
    cache_dir: Option<PathBuf>,
    retry_delay: Duration,
}

static CACHE_LOCKS: LazyLock<Mutex<HashMap<PathBuf, Weak<tokio::sync::Mutex<()>>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

#[derive(Serialize, Deserialize)]
struct CacheEntry {
    expires_at: u64,
    artwork: Option<ArtworkReference>,
}

#[derive(Deserialize)]
struct CoverIndex {
    #[serde(default)]
    images: Vec<CoverImage>,
    release: Option<String>,
}

#[derive(Deserialize)]
struct CoverImage {
    front: bool,
    #[serde(default)]
    approved: bool,
    image: String,
    #[serde(default)]
    thumbnails: std::collections::HashMap<String, String>,
}

impl ArtworkResolver {
    pub(super) fn new(client: Client, base: String, cache_dir: Option<PathBuf>) -> Self {
        Self {
            client,
            base,
            cache_dir,
            retry_delay: Duration::from_millis(250),
        }
    }

    pub(super) async fn enrich(&self, metadata: &mut TrackMetadata) {
        if let Some(url) = metadata
            .artwork_url
            .as_ref()
            .filter(|url| valid_image_url(url))
        {
            metadata.artwork = Some(ArtworkReference {
                url: url.clone(),
                provider: metadata.source.provider.clone(),
                release_id: None,
                release_group_id: None,
            });
            return;
        }
        if metadata.source.provider != "musicbrainz" {
            return;
        }
        let release = metadata
            .source
            .preferred_release_id
            .as_deref()
            .filter(|id| valid_mbid(id));
        let group = metadata
            .source
            .preferred_release_group_id
            .as_deref()
            .filter(|id| valid_mbid(id));
        for (kind, id) in [("release", release), ("release-group", group)] {
            let Some(id) = id else { continue };
            match self.lookup(kind, id, group).await {
                Ok(Some(artwork)) => {
                    metadata.artwork_url = Some(artwork.url.clone());
                    metadata.artwork = Some(artwork);
                    return;
                }
                Ok(None) => {}
                Err(error) => {
                    debug!("Cover Art Archive {kind} lookup failed: {error}");
                    return;
                }
            }
        }
    }

    async fn lookup(
        &self,
        kind: &str,
        id: &str,
        group: Option<&str>,
    ) -> Result<Option<ArtworkReference>> {
        let cache_path = self
            .cache_dir
            .as_ref()
            .map(|root| root.join(format!("{kind}-{id}.json")));
        let cache_lock = cache_path.as_ref().map(|path| {
            let mut locks = CACHE_LOCKS
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            locks.retain(|_, lock| lock.strong_count() > 0);
            let lock = locks
                .get(path)
                .and_then(Weak::upgrade)
                .unwrap_or_else(|| Arc::new(tokio::sync::Mutex::new(())));
            locks.insert(path.clone(), Arc::downgrade(&lock));
            lock
        });
        let _cache_guard = match &cache_lock {
            Some(lock) => Some(lock.lock().await),
            None => None,
        };
        if let Some(path) = &cache_path {
            if let Ok(bytes) = tokio::fs::read(path).await {
                if let Ok(entry) = serde_json::from_slice::<CacheEntry>(&bytes) {
                    if entry.expires_at > now()
                        && entry
                            .artwork
                            .as_ref()
                            .is_none_or(|art| valid_image_url(&art.url))
                    {
                        return Ok(entry.artwork);
                    }
                }
            }
        }
        let mut last_error = None;
        let mut retry_delay = self.retry_delay;
        for attempt in 0..2 {
            if attempt > 0 {
                tokio::time::sleep(retry_delay).await;
            }
            let request = self
                .client
                .get(format!("{}/{kind}/{id}", self.base.trim_end_matches('/')))
                .header(
                    reqwest::header::USER_AGENT,
                    concat!("Needle/", env!("CARGO_PKG_VERSION")),
                )
                .timeout(Duration::from_secs(3))
                .send()
                .await;
            let mut response = match request {
                Ok(response) => response,
                Err(error) => {
                    last_error = Some(error.into());
                    continue;
                }
            };
            let artwork = if response.status() == StatusCode::NOT_FOUND {
                None
            } else if response.status().is_server_error()
                || response.status() == StatusCode::TOO_MANY_REQUESTS
            {
                last_error = Some(anyhow::anyhow!("HTTP {}", response.status()));
                if let Some(retry_after) = response.headers().get(reqwest::header::RETRY_AFTER) {
                    match retry_after
                        .to_str()
                        .ok()
                        .and_then(|value| value.parse::<u64>().ok())
                    {
                        Some(seconds) if seconds <= 3 => retry_delay = Duration::from_secs(seconds),
                        _ => break,
                    }
                }
                continue;
            } else {
                response.error_for_status_ref()?;
                let mut bytes = Vec::new();
                while let Some(chunk) = response.chunk().await? {
                    if bytes.len() + chunk.len() > 1_048_576 {
                        bail!("Cover Art Archive response exceeds 1 MiB");
                    }
                    bytes.extend_from_slice(&chunk);
                }
                let index: CoverIndex = serde_json::from_slice(&bytes)?;
                let actual_release = if kind == "release" {
                    Some(id.to_string())
                } else {
                    index.release.as_deref().and_then(release_id_from_url)
                };
                index
                    .images
                    .into_iter()
                    .filter(|image| image.front && image.approved)
                    .find_map(|image| {
                        let url = image
                            .thumbnails
                            .get("1200")
                            .and_then(|url| canonical_image_url(url))
                            .or_else(|| canonical_image_url(&image.image))?;
                        Some(ArtworkReference {
                            url,
                            provider: "cover_art_archive".into(),
                            release_id: actual_release.clone(),
                            release_group_id: group.map(str::to_string),
                        })
                    })
            };
            if let Some(path) = cache_path {
                let ttl = if artwork.is_some() {
                    7 * 24 * 60 * 60
                } else {
                    6 * 60 * 60
                };
                let entry = CacheEntry {
                    expires_at: now() + ttl,
                    artwork: artwork.clone(),
                };
                if let (Some(parent), Ok(bytes)) = (path.parent(), serde_json::to_vec(&entry)) {
                    if tokio::fs::create_dir_all(parent).await.is_ok() {
                        let temporary = path.with_extension(format!(
                            "{}.{}.tmp",
                            std::process::id(),
                            now_nanos()
                        ));
                        if tokio::fs::write(&temporary, bytes).await.is_ok() {
                            if let Err(error) = tokio::fs::rename(&temporary, path).await {
                                debug!("Artwork cache write failed: {error}");
                                let _ = tokio::fs::remove_file(&temporary).await;
                            }
                        }
                    }
                }
            }
            return Ok(artwork);
        }
        Err(last_error.unwrap_or_else(|| anyhow::anyhow!("Artwork lookup failed")))
    }
}

pub(super) async fn enrich_artwork(metadata: &mut TrackMetadata) {
    let cache_dir = directories::ProjectDirs::from("dev", "tege", "needle")
        .map(|dirs| dirs.cache_dir().join("artwork-lookups"));
    let resolver = ArtworkResolver::new(
        Client::new(),
        "https://coverartarchive.org".into(),
        cache_dir,
    );
    resolver.enrich(metadata).await;
}

fn valid_mbid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(i, byte)| {
            if [8, 13, 18, 23].contains(&i) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

fn valid_image_url(value: &str) -> bool {
    Url::parse(value).is_ok_and(|url| {
        url.scheme() == "https"
            && url.host_str().is_some()
            && url.username().is_empty()
            && url.password().is_none()
    })
}

fn canonical_image_url(value: &str) -> Option<String> {
    let mut url = Url::parse(value).ok()?;
    if url.scheme() == "http" {
        let host = url.host_str()?;
        if host == "coverartarchive.org" || host == "archive.org" || host.ends_with(".archive.org")
        {
            url.set_scheme("https").ok()?;
        }
    }
    valid_image_url(url.as_str()).then(|| url.to_string())
}

fn release_id_from_url(value: &str) -> Option<String> {
    let url = Url::parse(value).ok()?;
    if url.host_str() != Some("musicbrainz.org") {
        return None;
    }
    let mut segments = url.path_segments()?;
    if segments.next()? != "release" {
        return None;
    }
    let id = segments.next()?;
    (valid_mbid(id) && segments.next().is_none()).then(|| id.to_string())
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
fn now_nanos() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
}

pub(super) async fn resolve_release_artwork(
    client: Client,
    release: &str,
    group: Option<&str>,
) -> Result<Option<ArtworkReference>> {
    if !valid_mbid(release) {
        return Ok(None);
    }
    let cache = directories::ProjectDirs::from("dev", "tege", "needle")
        .map(|dirs| dirs.cache_dir().join("artwork-lookups"));
    ArtworkResolver::new(client, "https://coverartarchive.org".into(), cache)
        .lookup("release", release, group)
        .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{Read, Write},
        net::TcpListener,
        sync::{
            atomic::{AtomicUsize, Ordering},
            Arc,
        },
    };

    const RELEASE: &str = "11111111-1111-1111-1111-111111111111";
    const GROUP: &str = "22222222-2222-2222-2222-222222222222";
    const OTHER: &str = "33333333-3333-3333-3333-333333333333";

    fn test_cache_directory() -> PathBuf {
        static COUNTER: AtomicUsize = AtomicUsize::new(0);
        std::env::temp_dir().join(format!(
            "needle-art-cache-{}-{}-{}",
            std::process::id(),
            now_nanos(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ))
    }

    fn server(responses: Vec<(u16, String)>) -> (String, Arc<AtomicUsize>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let count = Arc::new(AtomicUsize::new(0));
        let received = count.clone();
        std::thread::spawn(move || {
            for (status, body) in responses {
                let (mut connection, _) = listener.accept().unwrap();
                let mut request = [0; 4096];
                let received_bytes = connection.read(&mut request).unwrap();
                assert!(received_bytes > 0);
                received.fetch_add(1, Ordering::SeqCst);
                write!(connection, "HTTP/1.1 {status} OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
            }
        });
        (base, count)
    }

    fn cover(release: &str) -> String {
        serde_json::json!({"release":format!("https://musicbrainz.org/release/{release}"),"images":[
            {"front":false,"approved":true,"image":"https://archive.org/back.jpg"},
            {"front":true,"approved":true,"image":"https://archive.org/front.jpg","thumbnails":{"1200":"https://archive.org/front-1200.jpg"}}
        ]}).to_string()
    }

    fn metadata() -> TrackMetadata {
        TrackMetadata {
            artist: "Artist".into(),
            title: "Song (Named Remix)".into(),
            source: super::super::MetadataSource {
                provider: "musicbrainz".into(),
                preferred_release_id: Some(RELEASE.into()),
                preferred_release_group_id: Some(GROUP.into()),
                ..Default::default()
            },
            ..Default::default()
        }
    }

    fn resolver(base: String, cache: Option<PathBuf>) -> ArtworkResolver {
        let mut resolver = ArtworkResolver::new(Client::new(), base, cache);
        resolver.retry_delay = Duration::ZERO;
        resolver
    }

    #[test]
    fn archive_http_urls_are_upgraded_without_accepting_other_http_hosts() {
        assert_eq!(
            canonical_image_url("http://coverartarchive.org/release/front.jpg").as_deref(),
            Some("https://coverartarchive.org/release/front.jpg")
        );
        assert_eq!(
            canonical_image_url("http://ia600100.us.archive.org/front.jpg").as_deref(),
            Some("https://ia600100.us.archive.org/front.jpg")
        );
        assert!(canonical_image_url("http://unrelated.test/front.jpg").is_none());
        let mut credentialed = Url::parse("https://archive.org/front.jpg").unwrap();
        credentialed.set_username("user").unwrap();
        credentialed.set_password(Some("secret")).unwrap();
        assert!(canonical_image_url(credentialed.as_str()).is_none());
    }

    #[tokio::test]
    async fn exact_release_cover_does_not_change_recording_identity() {
        let (base, count) = server(vec![(200, cover(RELEASE))]);
        let mut metadata = metadata();
        resolver(base, None).enrich(&mut metadata).await;
        assert_eq!(metadata.title, "Song (Named Remix)");
        assert_eq!(
            metadata.artwork_url.as_deref(),
            Some("https://archive.org/front-1200.jpg")
        );
        assert_eq!(
            metadata.artwork.as_ref().unwrap().release_id.as_deref(),
            Some(RELEASE)
        );
        assert_eq!(count.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn group_fallback_preserves_actual_release_provenance() {
        let (base, count) = server(vec![(404, "".into()), (200, cover(OTHER))]);
        let mut metadata = metadata();
        resolver(base, None).enrich(&mut metadata).await;
        let artwork = metadata.artwork.unwrap();
        assert_eq!(artwork.release_id.as_deref(), Some(OTHER));
        assert_eq!(artwork.release_group_id.as_deref(), Some(GROUP));
        assert_eq!(count.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn positive_and_missing_covers_survive_resolver_restart() {
        for (status, body) in [(200, cover(RELEASE)), (404, String::new())] {
            let cache = test_cache_directory();
            let (base, count) = server(vec![(status, body)]);
            let first = resolver(base.clone(), Some(cache.clone()))
                .lookup("release", RELEASE, Some(GROUP))
                .await
                .unwrap();
            let second = resolver(base, Some(cache.clone()))
                .lookup("release", RELEASE, Some(GROUP))
                .await
                .unwrap();
            assert_eq!(first, second);
            assert_eq!(count.load(Ordering::SeqCst), 1);
            std::fs::remove_dir_all(cache).unwrap();
        }
    }

    #[tokio::test]
    async fn concurrent_requests_share_the_cached_lookup() {
        let cache = test_cache_directory();
        let (base, count) = server(vec![(200, cover(RELEASE))]);
        let resolver = resolver(base, Some(cache.clone()));
        let (first, second) = tokio::join!(
            resolver.lookup("release", RELEASE, Some(GROUP)),
            resolver.lookup("release", RELEASE, Some(GROUP))
        );
        assert_eq!(first.unwrap(), second.unwrap());
        assert_eq!(count.load(Ordering::SeqCst), 1);
        std::fs::remove_dir_all(cache).unwrap();
    }

    #[tokio::test]
    async fn unapproved_or_non_front_images_are_not_used() {
        let body = serde_json::json!({"release":format!("https://musicbrainz.org/release/{RELEASE}"),"images":[
            {"front":true,"approved":false,"image":"https://archive.org/unapproved.jpg"},
            {"front":false,"approved":true,"image":"https://archive.org/back.jpg"}
        ]}).to_string();
        let (base, _) = server(vec![(200, body)]);
        assert!(resolver(base, None)
            .lookup("release", RELEASE, None)
            .await
            .unwrap()
            .is_none());
    }

    #[tokio::test]
    async fn transient_failure_is_retried_and_not_cached_as_missing() {
        let cache = test_cache_directory();
        let (base, count) = server(vec![
            (503, "".into()),
            (503, "".into()),
            (200, cover(RELEASE)),
        ]);
        let resolver = resolver(base, Some(cache.clone()));
        assert!(resolver.lookup("release", RELEASE, None).await.is_err());
        assert!(resolver
            .lookup("release", RELEASE, None)
            .await
            .unwrap()
            .is_some());
        assert_eq!(count.load(Ordering::SeqCst), 3);
        std::fs::remove_dir_all(cache).unwrap();
    }

    #[tokio::test]
    async fn expired_negative_cache_is_refreshed() {
        let cache = test_cache_directory();
        std::fs::create_dir_all(&cache).unwrap();
        std::fs::write(
            cache.join(format!("release-{RELEASE}.json")),
            serde_json::to_vec(&CacheEntry {
                expires_at: 0,
                artwork: None,
            })
            .unwrap(),
        )
        .unwrap();
        let (base, count) = server(vec![(200, cover(RELEASE))]);
        assert!(resolver(base, Some(cache.clone()))
            .lookup("release", RELEASE, None)
            .await
            .unwrap()
            .is_some());
        assert_eq!(count.load(Ordering::SeqCst), 1);
        std::fs::remove_dir_all(cache).unwrap();
    }

    #[tokio::test]
    async fn invalid_release_identity_never_starts_a_lookup() {
        let (base, count) = server(vec![]);
        let mut metadata = metadata();
        metadata.source.preferred_release_id = Some("../other-release".into());
        metadata.source.preferred_release_group_id = None;
        resolver(base, None).enrich(&mut metadata).await;
        assert!(metadata.artwork.is_none());
        assert_eq!(count.load(Ordering::SeqCst), 0);
    }
}
