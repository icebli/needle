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
    #[serde(default)]
    pub clear_artwork: bool,
    /// Reject a stale automatic repair after taking the repair lock.
    pub expected_file_hash: Option<u64>,
    #[serde(default)]
    pub only_missing_artwork: bool,
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

/// Fingerprint the complete file so automatic repairs can reject stale lookups.
pub fn file_version_hash(path: &Path) -> Result<u64> {
    use std::hash::{Hash, Hasher};
    use std::io::Read;

    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    let mut file = std::fs::File::open(path)?;
    let mut buffer = [0u8; 65536];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        buffer[..count].hash(&mut hasher);
    }
    Ok(hasher.finish())
}

#[derive(Debug)]
struct RepairLock(std::fs::File);

impl Drop for RepairLock {
    fn drop(&mut self) {
        // Subprocesses can inherit this open file description between fork and
        // exec. Closing our descriptor alone would leave their lock held.
        if let Err(error) = self.0.unlock() {
            tracing::warn!(%error, "could not release audio repair lock");
        }
    }
}

fn repair_lock(file: &Path) -> Result<RepairLock> {
    let parent = file.parent().filter(|path| !path.as_os_str().is_empty());
    let parent = parent.unwrap_or_else(|| Path::new("."));
    let parent = std::fs::canonicalize(parent)?;
    let filename = file.file_name().context("audio file has no filename")?;
    let mut lock_name = std::ffi::OsString::from(".");
    lock_name.push(filename);
    lock_name.push(".needle-repair.lock");
    let lock_path = parent.join(lock_name);
    // This file must remain in place. Unlinking it lets another process lock a
    // different inode while the previous holder still owns its lock.
    let lock = match std::fs::File::options()
        .read(true)
        .write(true)
        .create_new(true)
        .open(&lock_path)
    {
        Ok(lock) => lock,
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            if !std::fs::symlink_metadata(&lock_path)?.file_type().is_file() {
                anyhow::bail!("repair lock must be a regular file, not a symbolic link");
            }
            std::fs::File::options()
                .read(true)
                .write(true)
                .open(&lock_path)?
        }
        Err(error) => return Err(error.into()),
    };
    let metadata = std::fs::symlink_metadata(&lock_path)?;
    if !metadata.file_type().is_file() || !lock.metadata()?.is_file() {
        anyhow::bail!("repair lock must be a regular file, not a symbolic link");
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let opened = lock.metadata()?;
        if opened.dev() != metadata.dev() || opened.ino() != metadata.ino() {
            anyhow::bail!("repair lock changed while opening it");
        }
    }
    lock.try_lock()
        .map_err(|error| anyhow::anyhow!("audio file is busy with another repair: {error}"))?;
    Ok(RepairLock(lock))
}

struct ReviewedProvenance {
    path: PathBuf,
    original: Vec<u8>,
    updated: Vec<u8>,
}

fn reviewed_provenance(
    file: &Path,
    repair: &TagRepair,
    current: &TagInspection,
    updated: &TagInspection,
    backup: &Path,
) -> Result<Option<ReviewedProvenance>> {
    if repair.artist.is_none()
        && repair.title.is_none()
        && repair.album.is_none()
        && !repair.clear_album
    {
        return Ok(None);
    }
    let path = file.with_extension("json");
    let metadata = match std::fs::symlink_metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    if !metadata.file_type().is_file() || metadata.len() > 512 * 1024 {
        anyhow::bail!("metadata review requires a regular provenance file below 512 KiB");
    }
    let original = std::fs::read(&path)?;
    let _: crate::provenance::Provenance = serde_json::from_slice(&original)
        .context("cannot record metadata review in invalid provenance")?;
    let mut value: serde_json::Value = serde_json::from_slice(&original)?;
    let prior_metadata = value["metadata"].clone();
    let keep_reviewed_album = prior_metadata["provider"] == "source_review"
        && prior_metadata["resolved_artist"].as_str() == current.artist.as_deref()
        && prior_metadata["resolved_title"].as_str() == current.title.as_deref()
        && prior_metadata["resolved_album"].as_str() == current.album.as_deref()
        && current.artist == updated.artist
        && current.title == updated.title;
    let album = if repair.album.is_some() || repair.clear_album {
        serde_json::to_value(&updated.album)?
    } else if keep_reviewed_album {
        prior_metadata["resolved_album"].clone()
    } else {
        serde_json::Value::Null
    };
    let mut prior = prior_metadata.clone();
    prior["resolved_artist"] = serde_json::to_value(&current.artist)?;
    prior["resolved_title"] = serde_json::to_value(&current.title)?;
    prior["resolved_album"] = serde_json::to_value(&current.album)?;
    prior["featured_artists"] = serde_json::json!([]);
    let repairs = value
        .as_object_mut()
        .expect("validated provenance object")
        .entry("repairs")
        .or_insert_with(|| serde_json::json!([]))
        .as_array_mut()
        .context("provenance repairs must be an array")?;
    repairs.push(serde_json::json!({
        "kind": "metadata_review",
        "prior_metadata": prior,
        "prior_catalog_metadata": prior_metadata,
        "backup_path": backup,
    }));
    value["metadata"] = serde_json::json!({
        "provider": "source_review",
        "plausibility_score": null,
        "recording_id": null,
        "resolved_artist": updated.artist,
        "resolved_title": updated.title,
        "resolved_album": album,
        "featured_artists": [],
        "re_queried": false,
        "canonical_url": null,
    });
    Ok(Some(ReviewedProvenance {
        path,
        original,
        updated: serde_json::to_vec_pretty(&value)?,
    }))
}

/// Repair tags in place using a sibling temporary file and an atomic rename.
/// The original audio remains untouched if parsing, encoding, or replacement fails.
pub fn repair_tags_with_backup(file: &Path, repair: &TagRepair) -> Result<RepairResult> {
    use lofty::config::WriteOptions;
    use lofty::file::{AudioFile, TaggedFileExt};
    use lofty::tag::{Accessor, Tag};

    let _lock = repair_lock(file)?;
    if !std::fs::symlink_metadata(file)?.file_type().is_file() {
        return Err(anyhow::anyhow!(
            "refusing to repair a symbolic link; choose the real audio file"
        ));
    }
    if let Some(expected) = repair.expected_file_hash {
        if file_version_hash(file)? != expected {
            anyhow::bail!("audio file changed during artwork lookup");
        }
    }
    if repair.only_missing_artwork && has_embedded_artwork(file)? {
        anyhow::bail!("audio file already has embedded artwork");
    }
    if repair.clear_artwork && repair.artwork.is_some() {
        anyhow::bail!("cannot clear and replace artwork in the same repair");
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
    let stem = file.file_stem().and_then(|v| v.to_str()).unwrap_or("track");
    let temp = parent.join(format!(".{stem}.needle-repair-{nonce}.{extension}"));
    std::fs::copy(file, &temp)?;
    let result = (|| -> Result<()> {
        let mut tagged = lofty::read_from_path(&temp)?;
        if repair.clear_artwork {
            let tag_types: Vec<_> = tagged.tags().iter().map(|tag| tag.tag_type()).collect();
            for tag_type in tag_types {
                let tag = tagged.tag_mut(tag_type).expect("existing tag type");
                while !tag.pictures().is_empty() {
                    tag.remove_picture(0);
                }
            }
        }
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
    let backup = parent.join(format!(".{stem}.needle-backup-{nonce}.{}", extension));
    let provenance = match (|| -> Result<_> {
        reviewed_provenance(
            file,
            repair,
            &inspect_tags(file, None)?,
            &inspect_tags(&temp, None)?,
            &backup,
        )
    })() {
        Ok(provenance) => provenance,
        Err(error) => {
            let _ = std::fs::remove_file(&temp);
            return Err(error);
        }
    };
    let provenance_temp = parent.join(format!(".{stem}.needle-review-{nonce}.json"));
    if let Some(provenance) = provenance.as_ref() {
        if let Err(error) = std::fs::write(&provenance_temp, &provenance.updated) {
            let _ = std::fs::remove_file(&temp);
            let _ = std::fs::remove_file(&provenance_temp);
            return Err(error.into());
        }
    }
    if let Err(error) = std::fs::copy(file, &backup) {
        let _ = std::fs::remove_file(&temp);
        let _ = std::fs::remove_file(&provenance_temp);
        return Err(error.into());
    }
    if let Err(error) = std::fs::rename(&temp, file) {
        let _ = std::fs::remove_file(&temp);
        let _ = std::fs::remove_file(&backup);
        let _ = std::fs::remove_file(&provenance_temp);
        return Err(error.into());
    }
    if let Some(provenance) = provenance {
        let result = (|| -> Result<()> {
            if std::fs::read(&provenance.path)? != provenance.original {
                anyhow::bail!("provenance changed during metadata repair");
            }
            std::fs::write(backup.with_extension("json"), provenance.original)?;
            // Approval becomes visible only after the matching audio tags exist.
            std::fs::rename(&provenance_temp, &provenance.path)?;
            Ok(())
        })();
        if let Err(error) = result {
            let _ = std::fs::remove_file(&provenance_temp);
            std::fs::copy(&backup, &temp)
                .and_then(|_| std::fs::rename(&temp, file))
                .context(
                    "metadata review failed and audio rollback failed; original is in backup",
                )?;
            return Err(error);
        }
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

/// Check every tag block so a secondary/manual picture is never overwritten.
pub fn has_embedded_artwork(file: &Path) -> Result<bool> {
    use lofty::file::TaggedFileExt;
    Ok(lofty::read_from_path(file)?
        .tags()
        .iter()
        .any(|tag| !tag.pictures().is_empty()))
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

    fn seed_provenance(path: &Path) -> serde_json::Value {
        let value = serde_json::json!({
            "requested": {"artist": "Requested artist", "title": "Requested title", "album": null},
            "selected_source": {"provider": "youtube", "id": "immutable", "title": "Independent source title", "duration_ms": 123000, "url": "https://example.com/source"},
            "scoring": {"confidence": 90, "reasons": ["original selection"]},
            "metadata": {"provider": "musicbrainz", "plausibility_score": 90, "recording_id": "old-recording", "resolved_artist": "Stale artist", "resolved_title": "Stale title", "resolved_album": "Stale album", "featured_artists": ["Stale guest"], "re_queried": true, "canonical_url": "https://example.com/old"},
            "created_by": "needle-test", "extension_field": "preserve"
        });
        std::fs::write(
            path.with_extension("json"),
            serde_json::to_vec(&value).unwrap(),
        )
        .unwrap();
        value
    }

    #[test]
    fn metadata_repair_records_review_without_changing_source_or_request() {
        let path = fixture_copy("provenance");
        seed_tags(&path);
        let original = seed_provenance(&path);
        let result = repair_tags_with_backup(
            &path,
            &TagRepair {
                title: Some("Reviewed title".into()),
                album: Some("Reviewed album".into()),
                ..Default::default()
            },
        )
        .unwrap();
        let reviewed: serde_json::Value =
            serde_json::from_slice(&std::fs::read(path.with_extension("json")).unwrap()).unwrap();
        assert_eq!(reviewed["requested"], original["requested"]);
        assert_eq!(reviewed["selected_source"], original["selected_source"]);
        assert_eq!(reviewed["scoring"], original["scoring"]);
        assert_eq!(reviewed["extension_field"], "preserve");
        assert_eq!(reviewed["metadata"]["provider"], "source_review");
        assert_eq!(reviewed["metadata"]["resolved_title"], "Reviewed title");
        assert_eq!(reviewed["metadata"]["resolved_album"], "Reviewed album");
        assert!(reviewed["metadata"]["recording_id"].is_null());
        assert!(reviewed["metadata"]["canonical_url"].is_null());
        assert_eq!(
            reviewed["repairs"][0]["prior_metadata"]["resolved_title"],
            "Original title"
        );
        assert_eq!(
            reviewed["repairs"][0]["prior_catalog_metadata"],
            original["metadata"]
        );
        let backup: serde_json::Value = serde_json::from_slice(
            &std::fs::read(result.backup_path.with_extension("json")).unwrap(),
        )
        .unwrap();
        assert_eq!(backup, original);
    }

    #[test]
    fn title_review_does_not_approve_an_untouched_album() {
        let path = fixture_copy("partial-review");
        seed_tags(&path);
        seed_provenance(&path);
        repair_tags_with_backup(
            &path,
            &TagRepair {
                title: Some("Reviewed title".into()),
                ..Default::default()
            },
        )
        .unwrap();
        let reviewed: serde_json::Value =
            serde_json::from_slice(&std::fs::read(path.with_extension("json")).unwrap()).unwrap();
        assert!(reviewed["metadata"]["resolved_album"].is_null());
        assert_eq!(
            inspect_tags(&path, None).unwrap().album.as_deref(),
            Some("Original album")
        );
        repair_tags_with_backup(
            &path,
            &TagRepair {
                album: Some("Approved album".into()),
                ..Default::default()
            },
        )
        .unwrap();
        repair_tags_with_backup(
            &path,
            &TagRepair {
                title: Some("Reviewed title".into()),
                ..Default::default()
            },
        )
        .unwrap();
        let reviewed: serde_json::Value =
            serde_json::from_slice(&std::fs::read(path.with_extension("json")).unwrap()).unwrap();
        assert_eq!(reviewed["metadata"]["resolved_album"], "Approved album");
        assert_eq!(reviewed["repairs"].as_array().unwrap().len(), 3);
    }

    #[test]
    fn no_op_repair_does_not_revive_a_stale_album_approval() {
        let path = fixture_copy("stale-review");
        seed_tags(&path);
        let mut provenance = seed_provenance(&path);
        provenance["metadata"]["provider"] = serde_json::json!("source_review");
        provenance["metadata"]["resolved_album"] = serde_json::json!("Original album");
        std::fs::write(
            path.with_extension("json"),
            serde_json::to_vec(&provenance).unwrap(),
        )
        .unwrap();
        repair_tags_with_backup(
            &path,
            &TagRepair {
                title: Some("Original title".into()),
                ..Default::default()
            },
        )
        .unwrap();
        let reviewed: serde_json::Value =
            serde_json::from_slice(&std::fs::read(path.with_extension("json")).unwrap()).unwrap();
        assert!(reviewed["metadata"]["resolved_album"].is_null());
    }

    #[test]
    fn artwork_repair_does_not_approve_or_require_valid_provenance() {
        let path = fixture_copy("artwork-no-review");
        seed_tags(&path);
        std::fs::write(path.with_extension("json"), b"not valid json").unwrap();
        repair_tags_with_backup(
            &path,
            &TagRepair {
                clear_artwork: true,
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(
            std::fs::read(path.with_extension("json")).unwrap(),
            b"not valid json"
        );
    }

    #[test]
    fn invalid_provenance_blocks_metadata_repair_before_audio_changes() {
        let path = fixture_copy("invalid-review");
        seed_tags(&path);
        let before = std::fs::read(&path).unwrap();
        for invalid in [b"not valid json".to_vec(), b"{}".to_vec()] {
            std::fs::write(path.with_extension("json"), &invalid).unwrap();
            assert!(repair_tags_with_backup(
                &path,
                &TagRepair {
                    title: Some("Never committed".into()),
                    ..Default::default()
                }
            )
            .is_err());
            assert_eq!(std::fs::read(&path).unwrap(), before);
            assert_eq!(std::fs::read(path.with_extension("json")).unwrap(), invalid);
        }
        let mut malformed = seed_provenance(&path);
        malformed["repairs"] = serde_json::json!({"unexpected": true});
        std::fs::write(
            path.with_extension("json"),
            serde_json::to_vec(&malformed).unwrap(),
        )
        .unwrap();
        assert!(repair_tags_with_backup(
            &path,
            &TagRepair {
                clear_album: true,
                ..Default::default()
            }
        )
        .is_err());
        assert_eq!(std::fs::read(&path).unwrap(), before);
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
    fn clear_artwork_keeps_tags_and_returns_original_backup() {
        let path = fixture_copy("clear-artwork");
        seed_tags(&path);
        let image = std::fs::read(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tests/fixtures/pixel.png"
        ))
        .unwrap();
        repair_tags_with_backup(
            &path,
            &TagRepair {
                artwork: Some(image.clone()),
                ..Default::default()
            },
        )
        .unwrap();
        let before = std::fs::read(&path).unwrap();
        assert!(repair_tags_with_backup(
            &path,
            &TagRepair {
                clear_artwork: true,
                artwork: Some(image),
                ..Default::default()
            }
        )
        .is_err());
        assert_eq!(std::fs::read(&path).unwrap(), before);
        let result = repair_tags_with_backup(
            &path,
            &TagRepair {
                clear_artwork: true,
                ..Default::default()
            },
        )
        .unwrap();
        assert!(!has_embedded_artwork(&path).unwrap());
        assert_eq!(result.track.title.as_deref(), Some("Original title"));
        assert_eq!(result.track.artist.as_deref(), Some("Original artist"));
        assert_eq!(result.track.album.as_deref(), Some("Original album"));
        assert_eq!(result.track.comment.as_deref(), Some("keep this comment"));
        assert_eq!(std::fs::read(result.backup_path).unwrap(), before);
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
    fn repair_lock_child_process() {
        let Some(path) = std::env::var_os("NEEDLE_TEST_REPAIR_LOCK_PATH") else {
            return;
        };
        let error = repair_tags_with_backup(
            Path::new(&path),
            &TagRepair {
                title: Some("Blocked concurrent edit".into()),
                ..Default::default()
            },
        )
        .unwrap_err();
        assert!(error.to_string().contains("busy with another repair"));
    }

    #[test]
    fn repair_lock_releases_while_an_inherited_descriptor_remains_open() {
        let path = fixture_copy("inherited-lock");
        let lock = repair_lock(&path).unwrap();
        // A forked subprocess retains the same open file description until exec.
        let inherited = lock.0.try_clone().unwrap();
        drop(lock);
        let next = repair_lock(&path)
            .expect("completed repair must release its lock before inherited descriptors close");
        drop(next);
        drop(inherited);
    }

    #[test]
    fn concurrent_repairs_reject_busy_and_stale_artwork_without_losing_manual_tags() {
        let path = fixture_copy("concurrent");
        seed_tags(&path);
        let original_hash = file_version_hash(&path).unwrap();
        let lock = repair_lock(&path).unwrap();
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "tag::tests::repair_lock_child_process",
                "--nocapture",
            ])
            .env("NEEDLE_TEST_REPAIR_LOCK_PATH", &path)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "child repair bypassed path lock: {} {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(file_version_hash(&path).unwrap(), original_hash);
        drop(lock);
        repair_tags_with_backup(
            &path,
            &TagRepair {
                title: Some("Manual edit survives".into()),
                ..Default::default()
            },
        )
        .unwrap();
        let manual_bytes = std::fs::read(&path).unwrap();
        let error = repair_tags_with_backup(
            &path,
            &TagRepair {
                artwork: Some(include_bytes!("../../../../tests/fixtures/pixel.png").to_vec()),
                expected_file_hash: Some(original_hash),
                only_missing_artwork: true,
                ..Default::default()
            },
        )
        .unwrap_err();
        assert!(
            error.to_string().contains("changed during artwork lookup"),
            "unexpected stale-repair error: {error:#}"
        );
        assert_eq!(std::fs::read(&path).unwrap(), manual_bytes);
        assert_eq!(
            inspect_tags(&path, None).unwrap().title.as_deref(),
            Some("Manual edit survives")
        );
    }

    #[test]
    fn missing_artwork_repair_refuses_existing_cover_inside_lock() {
        let path = fixture_copy("cover-race");
        seed_tags(&path);
        let artwork = include_bytes!("../../../../tests/fixtures/pixel.png").to_vec();
        repair_tags_with_backup(
            &path,
            &TagRepair {
                artwork: Some(artwork.clone()),
                expected_file_hash: Some(file_version_hash(&path).unwrap()),
                only_missing_artwork: true,
                ..Default::default()
            },
        )
        .unwrap();
        let before = std::fs::read(&path).unwrap();
        let error = repair_tags_with_backup(
            &path,
            &TagRepair {
                artwork: Some(artwork),
                only_missing_artwork: true,
                expected_file_hash: Some(file_version_hash(&path).unwrap()),
                ..Default::default()
            },
        )
        .unwrap_err();
        assert!(
            error.to_string().contains("already has embedded artwork"),
            "unexpected existing-artwork error: {error:#}"
        );
        assert_eq!(std::fs::read(&path).unwrap(), before);
    }

    #[cfg(unix)]
    #[test]
    fn repair_refuses_symlink_and_nonregular_lock_files() {
        for use_symlink in [false, true] {
            let path = fixture_copy("unsafe-lock");
            let filename = path.file_name().unwrap().to_str().unwrap();
            let lock_path = path.with_file_name(format!(".{filename}.needle-repair.lock"));
            if use_symlink {
                std::os::unix::fs::symlink(&path, &lock_path).unwrap();
            } else {
                std::fs::create_dir(&lock_path).unwrap();
            }
            let before = std::fs::read(&path).unwrap();
            let error = repair_tags_with_backup(&path, &TagRepair::default()).unwrap_err();
            assert!(error.to_string().contains("lock must be a regular file"));
            assert_eq!(std::fs::read(&path).unwrap(), before);
        }
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
