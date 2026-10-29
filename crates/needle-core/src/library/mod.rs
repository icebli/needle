use anyhow::{bail, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// Output profile for library layout
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OutputProfile {
    pub name: String,
    pub root: PathBuf,
    pub template: String,
    pub collision: CollisionStrategy,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum CollisionStrategy {
    #[default]
    Ask,
    Overwrite,
    KeepBoth,
    Skip,
}

impl Default for OutputProfile {
    fn default() -> Self {
        Self {
            name: "default".into(),
            root: dirs::home_dir()
                .map(|h| h.join("Music").join("needle"))
                .unwrap_or_else(|| PathBuf::from(".").join("needle")),
            template: "{album_artist}/{album}/{track:02} - {title}.{ext}".into(),
            collision: CollisionStrategy::Ask,
        }
    }
}

/// Keep a metadata field usable as one path component.
///
/// Artist, album, and title values come from user input and remote metadata.
/// They must not introduce separators or parent-directory segments that escape
/// the profile root.
pub fn sanitize_path_component(value: &str, fallback: &str) -> String {
    let mut out = String::new();
    let mut pending_space = false;

    for ch in value.chars() {
        let unsafe_char =
            ch.is_control() || matches!(ch, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|');
        if unsafe_char || ch.is_whitespace() {
            if !out.is_empty() {
                pending_space = true;
            }
            continue;
        }
        if pending_space {
            out.push(' ');
            pending_space = false;
        }
        out.push(ch);
    }

    let collapsed = collapse_whitespace(&collapse_parent_runs(&out));
    let trimmed = collapsed.trim().trim_matches('.').trim();
    if trimmed.is_empty() || trimmed == "." || trimmed == ".." {
        fallback.to_string()
    } else {
        trimmed.to_string()
    }
}

fn collapse_whitespace(value: &str) -> String {
    let mut out = String::new();
    let mut pending_space = false;
    for ch in value.chars() {
        if ch.is_whitespace() {
            if !out.is_empty() {
                pending_space = true;
            }
            continue;
        }
        if pending_space {
            out.push(' ');
            pending_space = false;
        }
        out.push(ch);
    }
    out
}

fn collapse_parent_runs(value: &str) -> String {
    let mut out = String::new();
    let mut dots = 0usize;
    for ch in value.chars() {
        if ch == '.' {
            dots += 1;
            continue;
        }
        if dots > 0 {
            if dots < 2 {
                out.push('.');
            }
            dots = 0;
        }
        out.push(ch);
    }
    if dots == 1 {
        out.push('.');
    }
    out
}

/// Build final output path from template.
///
/// The returned path is always relative to `profile.root`. Metadata cannot add
/// extra directories or climb out of the library with `..`.
pub fn build_output_path(
    profile: &OutputProfile,
    artist: &str,
    title: &str,
    album: Option<&str>,
    track: Option<u32>,
    ext: &str,
) -> PathBuf {
    let album_artist = sanitize_path_component(artist, "Unknown Artist");
    let album_str = sanitize_path_component(album.unwrap_or("Unknown Album"), "Unknown Album");
    let title_str = sanitize_path_component(title, "Unknown Title");
    let ext_str = sanitize_path_component(ext, "audio");
    let track_str = track
        .map(|t| format!("{:02}", t))
        .unwrap_or_else(|| "00".into());

    let relative = profile
        .template
        .replace("{album_artist}", &album_artist)
        .replace("{artist}", &album_artist)
        .replace("{album}", &album_str)
        .replace("{track:02}", &track_str)
        .replace("{track}", &track_str)
        .replace("{title}", &title_str)
        .replace("{ext}", &ext_str);

    let mut path = profile.root.clone();
    for component in Path::new(&relative).components() {
        match component {
            std::path::Component::Normal(part) => path.push(part),
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir
            | std::path::Component::RootDir
            | std::path::Component::Prefix(_) => {
                path.push("Unknown");
            }
        }
    }
    path
}

/// Resolve where a finished download should be placed.
///
/// `Skip` returns `None` when the destination already exists. `KeepBoth`
/// chooses the next unused numbered sibling. `Ask` reports that an interactive
/// decision is required instead of silently replacing the file.
pub fn resolve_destination(path: &Path, strategy: CollisionStrategy) -> Result<Option<PathBuf>> {
    handle_collision(path, strategy)
}

/// Handle file collision based on strategy
pub fn handle_collision(path: &Path, strategy: CollisionStrategy) -> Result<Option<PathBuf>> {
    if !path.exists() {
        return Ok(Some(path.to_path_buf()));
    }

    match strategy {
        CollisionStrategy::Skip => Ok(None),
        CollisionStrategy::Overwrite => Ok(Some(path.to_path_buf())),
        CollisionStrategy::KeepBoth => {
            let mut counter = 1;
            let stem = path.file_stem().unwrap_or_default();
            let ext = path.extension().unwrap_or_default();
            let parent = path.parent().unwrap_or(Path::new("."));
            loop {
                let new_name = format!(
                    "{} ({}).{}",
                    stem.to_string_lossy(),
                    counter,
                    ext.to_string_lossy()
                );
                let new_path = parent.join(new_name);
                if !new_path.exists() {
                    return Ok(Some(new_path));
                }
                counter += 1;
            }
        }
        CollisionStrategy::Ask => {
            // CLI handles interactive prompt
            bail!(
                "file collision at {}: interactive resolution required",
                path.display()
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn profile(root: &str) -> OutputProfile {
        OutputProfile {
            root: PathBuf::from(root),
            ..OutputProfile::default()
        }
    }

    #[test]
    fn keeps_ordinary_metadata_readable() {
        let path = build_output_path(
            &profile("/library"),
            "Kendrick Lamar",
            "The Heart Pt. 2",
            Some("Overly Dedicated"),
            Some(3),
            "mp3",
        );

        assert_eq!(
            path,
            PathBuf::from("/library/Kendrick Lamar/Overly Dedicated/03 - The Heart Pt. 2.mp3")
        );
    }

    #[test]
    fn metadata_path_separators_cannot_escape_profile_root() {
        let path = build_output_path(
            &profile("/library"),
            "../../etc",
            "song/../secret",
            Some("albums/../../tmp"),
            Some(1),
            "mp3",
        );

        assert!(path.starts_with("/library"));
        assert_eq!(
            path.components().next(),
            Some(std::path::Component::RootDir)
        );
        let parts: Vec<_> = path.components().skip(1).collect();
        assert!(parts
            .iter()
            .all(|component| matches!(component, std::path::Component::Normal(_))));
        assert_eq!(
            parts[0],
            std::path::Component::Normal(std::ffi::OsStr::new("library"))
        );
        assert!(parts
            .iter()
            .all(|component| { component.as_os_str() != ".." && component.as_os_str() != "." }));
        let rendered = path.to_string_lossy().into_owned();
        assert!(
            rendered.starts_with("/library/"),
            "escaped library root: {rendered}"
        );
        assert!(
            !rendered.contains(".."),
            "parent segment remained: {rendered}"
        );
        assert_eq!(
            rendered, "/library/etc/albums tmp/01 - song secret.mp3",
            "unexpected sanitized path: {rendered}"
        );
    }

    #[test]
    fn empty_and_dot_components_use_fallbacks() {
        let path = build_output_path(&profile("/library"), " .. ", "...", Some("   "), None, "");

        assert_eq!(
            path,
            PathBuf::from("/library/Unknown Artist/Unknown Album/00 - Unknown Title.audio")
        );
    }

    #[test]
    fn skip_keeps_existing_file() {
        let dir =
            std::env::temp_dir().join(format!("needle-collision-skip-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("track.mp3");
        std::fs::write(&path, b"existing").unwrap();

        let resolved = resolve_destination(&path, CollisionStrategy::Skip).unwrap();

        assert_eq!(resolved, None);
        assert_eq!(std::fs::read(&path).unwrap(), b"existing");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn keep_both_uses_next_free_sibling() {
        let dir =
            std::env::temp_dir().join(format!("needle-collision-keep-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("track.mp3");
        std::fs::write(&path, b"existing").unwrap();
        std::fs::write(dir.join("track (1).mp3"), b"also").unwrap();

        let resolved = resolve_destination(&path, CollisionStrategy::KeepBoth)
            .unwrap()
            .unwrap();

        assert_eq!(resolved, dir.join("track (2).mp3"));
        let _ = std::fs::remove_dir_all(dir);
    }
}
