use anyhow::{bail, Context, Result};
use serde::Serialize;
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

const MAX_TRACKS: usize = 10_000;
const MAX_WARNINGS: usize = 128;
const MAX_SIDECAR_BYTES: u64 = 1024 * 1024;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LibraryTrack {
    pub path: String,
    pub artist: Option<String>,
    pub title: Option<String>,
    pub album: Option<String>,
    pub source_url: Option<String>,
    pub modified_ms: Option<u64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LibraryScanResponse {
    pub ok: bool,
    pub tracks: Vec<LibraryTrack>,
    pub warnings: Vec<String>,
}

const AUDIO_EXTENSIONS: &[&str] = &["mp3", "flac", "m4a", "aac", "ogg", "opus", "wav", "aiff", "aif"];

pub fn run(root: &Path) -> Result<LibraryScanResponse> {
    let metadata = fs::symlink_metadata(root)
        .with_context(|| format!("read library root {}", root.display()))?;
    if !metadata.is_dir() {
        bail!("library root is not a directory: {}", root.display());
    }

    let mut scanner = Scanner { tracks: Vec::new(), warnings: Vec::new(), seen: HashSet::new() };
    scanner.visit_dir(root, root)?;
    scanner.tracks.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(LibraryScanResponse { ok: true, tracks: scanner.tracks, warnings: scanner.warnings })
}

struct Scanner {
    tracks: Vec<LibraryTrack>,
    warnings: Vec<String>,
    seen: HashSet<PathBuf>,
}

impl Scanner {
    fn visit_dir(&mut self, root: &Path, dir: &Path) -> Result<()> {
        let entries = match fs::read_dir(dir) {
            Ok(entries) => entries,
            Err(error) if dir == root => {
                return Err(error).with_context(|| format!("read library root {}", root.display()));
            }
            Err(error) => {
                self.warn(format!("could not read directory {}: {error}", dir.display()));
                return Ok(());
            }
        };

        for entry in entries {
            let entry = match entry {
                Ok(entry) => entry,
                Err(error) => {
                    self.warn(format!("could not read an entry in {}: {error}", dir.display()));
                    continue;
                }
            };
            let path = entry.path();
            let file_type = match entry.file_type() {
                Ok(file_type) => file_type,
                Err(error) => {
                    self.warn(format!("could not inspect {}: {error}", path.display()));
                    continue;
                }
            };
            if file_type.is_symlink() {
                continue;
            }
            if file_type.is_dir() {
                if should_skip_directory(&path) {
                    continue;
                }
                self.visit_dir(root, &path)?;
            } else if file_type.is_file() && !should_skip_file(&path) && is_audio_file(&path) {
                if self.tracks.len() >= MAX_TRACKS {
                    self.warn(format!("stopped after {MAX_TRACKS} audio files"));
                    break;
                }
                self.inspect_track(root, &path);
            }
        }
        Ok(())
    }

    fn inspect_track(&mut self, root: &Path, path: &Path) {
        let key = path.to_path_buf();
        if !self.seen.insert(key) {
            return;
        }
        let tags = match needle_core::tag::inspect_tags(path, None) {
            Ok(tags) => tags,
            Err(error) => {
                self.warn(format!("could not read tags for {}: {error}", path.display()));
                needle_core::tag::TagInspection { path: path.to_path_buf(), ..Default::default() }
            }
        };
        let (fallback_artist, fallback_title, fallback_album) = filename_fallback(root, path);
        let source_url = read_source_url(path, &mut self.warnings);
        let modified_ms = fs::metadata(path).ok().and_then(|metadata| {
            metadata.modified().ok()?.duration_since(UNIX_EPOCH).ok()?.as_millis().try_into().ok()
        });
        self.tracks.push(LibraryTrack {
            path: path.to_string_lossy().into_owned(),
            artist: tags.artist.or(fallback_artist),
            title: tags.title.or(fallback_title),
            album: tags.album.or(fallback_album),
            source_url,
            modified_ms,
        });
    }

    fn warn(&mut self, message: String) {
        if self.warnings.len() < MAX_WARNINGS {
            self.warnings.push(message);
        }
    }
}

fn is_audio_file(path: &Path) -> bool {
    path.extension().and_then(|extension| extension.to_str()).is_some_and(|extension| {
        AUDIO_EXTENSIONS.contains(&extension.to_ascii_lowercase().as_str())
    })
}

fn should_skip_directory(path: &Path) -> bool {
    let name = path.file_name().and_then(|name| name.to_str()).unwrap_or_default();
    let lowercase = name.to_ascii_lowercase();
    name.starts_with('.') || matches!(lowercase.as_str(), "backup" | "backups" | "temp" | "tmp")
}

fn should_skip_file(path: &Path) -> bool {
    let name = path.file_name().and_then(|name| name.to_str()).unwrap_or_default();
    let lowercase = name.to_ascii_lowercase();
    if name.starts_with('.') {
        return true;
    }
    let stem = Path::new(&lowercase).file_stem().and_then(|stem| stem.to_str()).unwrap_or_default();
    [".part", ".partial", ".tmp", ".temp", ".bak", ".backup"].iter().any(|suffix| stem.ends_with(suffix))
}

fn filename_fallback(root: &Path, path: &Path) -> (Option<String>, Option<String>, Option<String>) {
    let title = path.file_stem().and_then(|stem| stem.to_str()).map(|stem| {
        let trimmed = stem.trim();
        trimmed.split_once(" - ").and_then(|(prefix, rest)| {
            prefix.trim().trim_end_matches('.').parse::<u32>().ok().map(|_| rest.trim().to_owned())
        }).unwrap_or_else(|| trimmed.to_owned())
    });
    let relative_parent = path.parent().and_then(|parent| parent.strip_prefix(root).ok());
    let components: Vec<_> = relative_parent.into_iter().flat_map(|parent| parent.components()).collect();
    let album = components.last().and_then(|component| component.as_os_str().to_str())
        .filter(|album| !album.eq_ignore_ascii_case("unknown album"))
        .map(str::to_owned);
    let artist = (components.len() >= 2)
        .then(|| components[components.len() - 2].as_os_str().to_str())
        .flatten()
        .map(str::to_owned);
    (artist, title, album)
}

fn read_source_url(path: &Path, warnings: &mut Vec<String>) -> Option<String> {
    if should_skip_file(path) {
        return None;
    }
    let sidecar = path.with_extension("json");
    match fs::symlink_metadata(&sidecar) {
        Ok(metadata) if metadata.file_type().is_symlink() => return None,
        Ok(metadata) if !metadata.is_file() => return None,
        Ok(metadata) if metadata.len() > MAX_SIDECAR_BYTES => {
            if warnings.len() < MAX_WARNINGS { warnings.push(format!("skipped oversized sidecar {}", sidecar.display())); }
            return None;
        }
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return None,
        Err(error) => {
            if warnings.len() < MAX_WARNINGS { warnings.push(format!("could not inspect sidecar {}: {error}", sidecar.display())); }
            return None;
        }
    };
    let contents = match fs::read_to_string(&sidecar) {
        Ok(contents) => contents,
        Err(error) => {
            if warnings.len() < MAX_WARNINGS { warnings.push(format!("could not read sidecar {}: {error}", sidecar.display())); }
            return None;
        }
    };
    let value: serde_json::Value = match serde_json::from_str(&contents) {
        Ok(value) => value,
        Err(error) => {
            if warnings.len() < MAX_WARNINGS { warnings.push(format!("could not parse sidecar {}: {error}", sidecar.display())); }
            return None;
        }
    };
    value.get("selected_source").and_then(|source| source.get("url")).and_then(serde_json::Value::as_str)
        .or_else(|| value.get("sourceUrl").and_then(serde_json::Value::as_str))
        .or_else(|| value.get("source_url").and_then(serde_json::Value::as_str))
        .map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEST_ROOT_COUNTER: AtomicU64 = AtomicU64::new(0);

    fn temp_root() -> PathBuf {
        let nonce = TEST_ROOT_COUNTER.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!("needle-library-scan-{}-{nonce}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        root
    }

    #[test]
    fn scans_supported_files_with_fallbacks_and_sidecar() {
        let root = temp_root();
        let track_dir = root.join("Artist").join("Album");
        fs::create_dir_all(&track_dir).unwrap();
        let path = track_dir.join("01 - Song.mp3");
        fs::write(&path, b"not real audio").unwrap();
        fs::write(path.with_extension("json"), br#"{"selected_source":{"url":"https://example.test/song"}}"#).unwrap();
        fs::write(track_dir.join("cover.jpg"), b"image").unwrap();
        let response = run(&root).unwrap();
        assert_eq!(response.tracks.len(), 1);
        let track = &response.tracks[0];
        assert_eq!(track.artist.as_deref(), Some("Artist"));
        assert_eq!(track.title.as_deref(), Some("Song"));
        assert_eq!(track.album.as_deref(), Some("Album"));
        assert_eq!(track.source_url.as_deref(), Some("https://example.test/song"));
        assert!(track.modified_ms.is_some());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn skips_symlinks_hidden_backups_and_temp_files() {
        let root = temp_root();
        fs::write(root.join("01 - Song.flac"), b"bad").unwrap();
        fs::write(root.join("01 - Song.part.mp3"), b"bad").unwrap();
        fs::write(root.join("Party.mp3"), b"bad").unwrap();
        fs::write(root.join("Tempest.mp3"), b"bad").unwrap();
        fs::write(root.join(".hidden.mp3"), b"bad").unwrap();
        fs::create_dir_all(root.join("backup")).unwrap();
        fs::write(root.join("backup").join("old.mp3"), b"bad").unwrap();
        #[cfg(unix)] std::os::unix::fs::symlink(root.join("01 - Song.flac"), root.join("link.mp3")).unwrap();
        let response = run(&root).unwrap();
        assert_eq!(response.tracks.len(), 3);
        assert!(response.tracks.iter().any(|track| track.path.ends_with("01 - Song.flac")));
        assert!(response.tracks.iter().any(|track| track.path.ends_with("Party.mp3")));
        assert!(response.tracks.iter().any(|track| track.path.ends_with("Tempest.mp3")));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn reads_real_tags_without_extracting_artwork() {
        let root = temp_root();
        let path = root.join("Tagged.mp3");
        let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/tag_repair.mp3");
        fs::copy(fixture, &path).unwrap();
        needle_core::tag::write_tags(&path, &needle_core::tag::TagPlan {
            artist: "Tagged Artist".into(), title: "Tagged Title".into(), album: Some("Tagged Album".into()), ..Default::default()
        }).unwrap();
        let response = run(&root).unwrap();
        assert_eq!(response.tracks.len(), 1);
        assert_eq!(response.tracks[0].artist.as_deref(), Some("Tagged Artist"));
        assert_eq!(response.tracks[0].title.as_deref(), Some("Tagged Title"));
        assert_eq!(response.tracks[0].album.as_deref(), Some("Tagged Album"));
        assert!(response.warnings.is_empty());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn missing_root_is_an_error() {
        let root = std::env::temp_dir().join("needle-library-scan-does-not-exist");
        let _ = fs::remove_dir_all(&root);
        assert!(run(&root).is_err());
    }

    #[test]
    fn response_uses_camel_case_fields() {
        let root = temp_root();
        fs::write(root.join("song.aiff"), b"bad").unwrap();
        let json = serde_json::to_value(run(&root).unwrap()).unwrap();
        assert!(json["tracks"][0].get("modifiedMs").is_some());
        assert!(json["tracks"][0].get("sourceUrl").is_some());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn unknown_album_folder_is_not_reported_as_metadata() {
        let root = temp_root();
        let path = root.join("Artist").join("Unknown Album").join("01 - Song.mp3");
        assert_eq!(filename_fallback(&root, &path).2, None);
        let _ = fs::remove_dir_all(root);
    }
}
