use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use tracing::debug;

/// The fields a user may change when repairing an existing recording.
/// `None` means leave the existing value alone; use `clear_album` to remove
/// an album without accidentally replacing it with a guessed release.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TagRepair {
    pub artist: Option<String>,
    pub title: Option<String>,
    pub album: Option<String>,
    pub clear_album: bool,
    pub album_artist: Option<String>,
    pub artwork: Option<Vec<u8>>,
    pub artwork_mime: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ArtworkInfo {
    pub index: usize,
    pub mime_type: Option<String>,
    pub bytes: usize,
    pub extracted_path: Option<PathBuf>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TagInspection {
    pub path: PathBuf,
    pub tag_type: Option<String>,
    pub artist: Option<String>,
    pub title: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub track: Option<u32>,
    pub disc: Option<u32>,
    pub date: Option<String>,
    pub genre: Option<String>,
    pub comment: Option<String>,
    pub artwork: Vec<ArtworkInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RepairResult {
    pub track: TagInspection,
    pub backup_path: PathBuf,
}

/// Read the current tags and embedded artwork without touching the audio file.
pub fn inspect_tags(file: &Path, artwork_dir: Option<&Path>) -> Result<TagInspection> {
    use lofty::file::TaggedFileExt;
    use lofty::tag::Accessor;

    let tagged = lofty::read_from_path(file)?;
    let tag = tagged.primary_tag().or_else(|| tagged.first_tag());
    let mut result = TagInspection {
        path: file.to_path_buf(),
        ..Default::default()
    };
    let Some(tag) = tag else {
        return Ok(result);
    };
    result.tag_type = Some(format!("{:?}", tag.tag_type()));
    result.artist = tag.artist().map(|v| v.into_owned());
    result.title = tag.title().map(|v| v.into_owned());
    result.album = tag.album().map(|v| v.into_owned());
    result.album_artist = tag
        .get_string(lofty::tag::ItemKey::AlbumArtist)
        .map(str::to_owned);
    result.track = tag.track();
    result.disc = tag.disk();
    result.date = tag.date().map(|v| v.to_string());
    result.genre = tag.genre().map(|v| v.into_owned());
    result.comment = tag.comment().map(|v| v.into_owned());
    for (index, picture) in tag.pictures().iter().enumerate() {
        let extracted_path = if let Some(dir) = artwork_dir {
            std::fs::create_dir_all(dir)
                .with_context(|| format!("create artwork directory {}", dir.display()))?;
            let ext = artwork_extension(picture.mime_type().map(|m| m.as_str()));
            let mut hasher = std::collections::hash_map::DefaultHasher::new();
            use std::hash::{Hash, Hasher};
            file.to_string_lossy().hash(&mut hasher);
            index.hash(&mut hasher);
            picture.data().hash(&mut hasher);
            let path = dir.join(format!("artwork-{:016x}.{ext}", hasher.finish()));
            std::fs::write(&path, picture.data())
                .with_context(|| format!("write extracted artwork {}", path.display()))?;
            Some(path)
        } else {
            None
        };
        result.artwork.push(ArtworkInfo {
            index,
            mime_type: picture.mime_type().map(|m| m.as_str().to_owned()),
            bytes: picture.data().len(),
            extracted_path,
        });
    }
    Ok(result)
}

fn artwork_extension(mime: Option<&str>) -> &'static str {
    match mime.map(str::to_ascii_lowercase).as_deref() {
        Some("image/png") => "png",
        Some("image/webp") => "webp",
        Some("image/jpeg") | Some("image/jpg") => "jpg",
        _ => "jpg",
    }
}

/// Repair tags in place using a sibling temporary file and an atomic rename.
/// The original audio remains untouched if parsing, encoding, or replacement fails.
pub fn repair_tags_with_backup(file: &Path, repair: &TagRepair) -> Result<RepairResult> {
    use lofty::config::WriteOptions;
    use lofty::file::{AudioFile, TaggedFileExt};
    use lofty::tag::{Accessor, Tag};

    if std::fs::symlink_metadata(file)?.file_type().is_symlink() {
        return Err(anyhow::anyhow!(
            "refusing to repair a symbolic link; choose the real audio file"
        ));
    }
    if repair
        .artist
        .as_deref()
        .is_some_and(|v| v.trim().is_empty())
        || repair.title.as_deref().is_some_and(|v| v.trim().is_empty())
        || repair.album.as_deref().is_some_and(|v| v.trim().is_empty())
    {
        return Err(anyhow::anyhow!(
            "artist, title, and album values cannot be blank"
        ));
    }
    if let Some(data) = repair.artwork.as_ref() {
        // Validate the image before copying/replacing the audio. This catches
        // HTML/error responses accidentally passed as artwork.
        let mut cursor = std::io::Cursor::new(data.as_slice());
        lofty::picture::Picture::from_reader(&mut cursor)
            .map_err(|error| anyhow::anyhow!("invalid artwork image: {error}"))?;
    }
    let parent = file.parent().unwrap_or_else(|| Path::new("."));
    let extension = file
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("audio");
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or_default();
    let temp = parent.join(format!(".needle-repair-{nonce}.{}", extension));
    std::fs::copy(file, &temp)?;
    let result = (|| -> Result<()> {
        let mut tagged = lofty::read_from_path(&temp)?;
        if tagged.primary_tag().is_none() {
            tagged.insert_tag(Tag::new(tagged.primary_tag_type()));
        }
        let tag = tagged
            .primary_tag_mut()
            .ok_or_else(|| anyhow::anyhow!("audio format does not support writable tags"))?;
        if let Some(value) = repair.artist.as_ref() {
            tag.set_artist(value.clone());
        }
        if let Some(value) = repair.title.as_ref() {
            tag.set_title(value.clone());
        }
        if repair.clear_album {
            tag.remove_album();
        } else if let Some(value) = repair.album.as_ref() {
            tag.set_album(value.clone());
        }
        if let Some(value) = repair.album_artist.as_ref() {
            tag.insert_text(lofty::tag::ItemKey::AlbumArtist, value.clone());
        }
        if let Some(data) = repair.artwork.as_ref() {
            tag.remove_picture_type(lofty::picture::PictureType::CoverFront);
            let mime = repair
                .artwork_mime
                .as_deref()
                .map(lofty::picture::MimeType::from_str)
                .unwrap_or_else(|| detect_mime(data));
            tag.push_picture(
                lofty::picture::Picture::unchecked(data.clone())
                    .pic_type(lofty::picture::PictureType::CoverFront)
                    .mime_type(mime)
                    .build(),
            );
        }
        tagged.save_to_path(&temp, WriteOptions::default())?;
        Ok(())
    })();
    if let Err(error) = result {
        let _ = std::fs::remove_file(&temp);
        return Err(error);
    }
    let stem = file.file_stem().and_then(|v| v.to_str()).unwrap_or("track");
    let backup = parent.join(format!(".{stem}.needle-backup-{nonce}.{}", extension));
    if let Err(error) = std::fs::copy(file, &backup) {
        let _ = std::fs::remove_file(&temp);
        return Err(error.into());
    }
    if let Err(error) = std::fs::rename(&temp, file) {
        let _ = std::fs::remove_file(&temp);
        let _ = std::fs::remove_file(&backup);
        return Err(error.into());
    }
    Ok(RepairResult {
        track: inspect_tags(file, None)?,
        backup_path: backup,
    })
}

/// Repair tags without exposing the backup path to legacy callers.
pub fn repair_tags(file: &Path, repair: &TagRepair) -> Result<TagInspection> {
    Ok(repair_tags_with_backup(file, repair)?.track)
}

/// Tag writing plan derived from metadata + user request
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TagPlan {
    pub title: String,
    pub artist: String,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub track: Option<u32>,
    pub disc: Option<u32>,
    pub date: Option<String>,
    pub genre: Option<String>,
    pub comment: Option<String>,
    pub source_url: Option<String>,
    pub artwork_path: Option<PathBuf>,
}

/// Write tags to an audio file using lofty
pub fn write_tags(file: &Path, plan: &TagPlan) -> Result<()> {
    use lofty::config::WriteOptions;
    use lofty::picture::{Picture, PictureType};
    use lofty::tag::{ItemKey, Tag, TagExt, TagType};
    use std::fs::OpenOptions;

    debug!("writing tags to {}", file.display());

    // Build a fresh tag from scratch — don't read existing tags because
    // some SoundCloud-origin MP3 files have corrupt ID3v2 timestamp frames
    // that cause lofty to fail with "Encountered an invalid timestamp".
    let mut tag = Tag::new(TagType::Id3v2);

    tag.insert_text(ItemKey::TrackTitle, plan.title.clone());
    tag.insert_text(ItemKey::TrackArtist, plan.artist.clone());

    if let Some(ref album) = plan.album {
        tag.insert_text(ItemKey::AlbumTitle, album.clone());
    }
    if let Some(ref aa) = plan.album_artist {
        tag.insert_text(ItemKey::AlbumArtist, aa.clone());
    }
    if let Some(track) = plan.track {
        tag.insert_text(ItemKey::TrackNumber, track.to_string());
    }
    if let Some(disc) = plan.disc {
        tag.insert_text(ItemKey::DiscNumber, disc.to_string());
    }
    if let Some(ref date) = plan.date {
        tag.insert_text(ItemKey::Year, date.clone());
    }
    if let Some(ref genre) = plan.genre {
        tag.insert_text(ItemKey::Genre, genre.clone());
    }
    if let Some(ref comment) = plan.comment {
        tag.insert_text(ItemKey::Comment, comment.clone());
    }
    if let Some(ref url) = plan.source_url {
        tag.insert_text(ItemKey::Comment, format!("Source: {}", url));
    }

    // Embed artwork
    if let Some(ref art_path) = plan.artwork_path {
        if art_path.exists() {
            let data = std::fs::read(art_path)?;
            let mime = guess_mime_type(art_path);
            let picture = Picture::unchecked(data)
                .pic_type(PictureType::CoverFront)
                .mime_type(mime)
                .build();
            tag.push_picture(picture);
        }
    }

    // Write back
    let mut file_handle = OpenOptions::new().read(true).write(true).open(file)?;
    tag.save_to(&mut file_handle, WriteOptions::default())?;

    Ok(())
}

fn guess_mime_type(path: &Path) -> lofty::picture::MimeType {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    match ext.as_str() {
        "png" => lofty::picture::MimeType::Png,
        "gif" => lofty::picture::MimeType::Gif,
        "bmp" => lofty::picture::MimeType::Bmp,
        "tiff" | "tif" => lofty::picture::MimeType::Tiff,
        _ => lofty::picture::MimeType::Jpeg,
    }
}

fn detect_mime(data: &[u8]) -> lofty::picture::MimeType {
    if data.starts_with(b"\x89PNG") {
        lofty::picture::MimeType::Png
    } else if data.starts_with(b"GIF8") {
        lofty::picture::MimeType::Gif
    } else if data.starts_with(b"BM") {
        lofty::picture::MimeType::Bmp
    } else if data.starts_with(b"II*\0") || data.starts_with(b"MM\0*") {
        lofty::picture::MimeType::Tiff
    } else {
        lofty::picture::MimeType::Jpeg
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_copy(label: &str) -> PathBuf {
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "needle-tag-{label}-{}-{nonce}.mp3",
            std::process::id()
        ));
        std::fs::copy(
            concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../tests/fixtures/tag_repair.mp3"
            ),
            &path,
        )
        .unwrap();
        path
    }

    fn seed_tags(path: &Path) {
        write_tags(
            path,
            &TagPlan {
                title: "Original title".into(),
                artist: "Original artist".into(),
                album: Some("Original album".into()),
                comment: Some("keep this comment".into()),
                ..Default::default()
            },
        )
        .unwrap();
    }

    #[test]
    fn repair_preserves_unrelated_tags_and_returns_undo_backup() {
        let path = fixture_copy("preserve");
        seed_tags(&path);
        let before = std::fs::read(&path).unwrap();
        let result = repair_tags_with_backup(
            &path,
            &TagRepair {
                title: Some("Updated title".into()),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(result.track.title.as_deref(), Some("Updated title"));
        assert_eq!(result.track.artist.as_deref(), Some("Original artist"));
        assert_eq!(result.track.album.as_deref(), Some("Original album"));
        assert_eq!(result.track.comment.as_deref(), Some("keep this comment"));
        assert_eq!(std::fs::read(&result.backup_path).unwrap(), before);
        assert_ne!(std::fs::read(&path).unwrap(), before);
    }

    #[test]
    fn clear_album_changes_only_album() {
        let path = fixture_copy("clear-album");
        seed_tags(&path);
        let result = repair_tags(
            &path,
            &TagRepair {
                clear_album: true,
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(result.album, None);
        assert_eq!(result.artist.as_deref(), Some("Original artist"));
        assert_eq!(result.title.as_deref(), Some("Original title"));
        assert_eq!(result.comment.as_deref(), Some("keep this comment"));
    }

    #[test]
    fn invalid_artwork_preserves_original_bytes_before_replacement() {
        let path = fixture_copy("invalid-art");
        seed_tags(&path);
        let before = std::fs::read(&path).unwrap();
        let error = repair_tags_with_backup(
            &path,
            &TagRepair {
                artwork: Some(b"not an image".to_vec()),
                ..Default::default()
            },
        )
        .unwrap_err();
        assert!(error.to_string().contains("invalid artwork"));
        assert_eq!(std::fs::read(&path).unwrap(), before);
    }

    #[test]
    fn extracted_artwork_names_are_stable_and_unique_per_audio_path() {
        let first = fixture_copy("art-first");
        let second = fixture_copy("art-second");
        let artwork = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/pixel.png");
        for path in [&first, &second] {
            write_tags(
                path,
                &TagPlan {
                    title: "Artwork test".into(),
                    artist: "Artist".into(),
                    artwork_path: Some(artwork.clone()),
                    ..Default::default()
                },
            )
            .unwrap();
        }
        let output =
            std::env::temp_dir().join(format!("needle-art-extract-{}", std::process::id()));
        let first_inspection = inspect_tags(&first, Some(&output)).unwrap();
        let second_inspection = inspect_tags(&second, Some(&output)).unwrap();
        let first_path = first_inspection.artwork[0].extracted_path.as_ref().unwrap();
        let second_path = second_inspection.artwork[0]
            .extracted_path
            .as_ref()
            .unwrap();
        assert_ne!(first_path, second_path);
        assert_eq!(
            std::fs::read(first_path).unwrap(),
            std::fs::read(second_path).unwrap()
        );
    }

    #[test]
    fn artwork_extraction_reports_directory_errors() {
        let path = fixture_copy("art-error");
        let artwork = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/pixel.png");
        write_tags(
            &path,
            &TagPlan {
                title: "Artwork test".into(),
                artist: "Artist".into(),
                artwork_path: Some(artwork),
                ..Default::default()
            },
        )
        .unwrap();
        let output = std::env::temp_dir().join(format!("needle-art-error-{}", std::process::id()));
        std::fs::write(&output, b"not a directory").unwrap();
        let error = inspect_tags(&path, Some(&output)).unwrap_err();
        assert!(error.to_string().contains("create artwork directory"));
    }
}
