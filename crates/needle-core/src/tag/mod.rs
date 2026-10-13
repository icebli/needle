use serde::{Deserialize, Serialize};
use anyhow::Result;
use std::path::{Path, PathBuf};
use tracing::debug;

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
    use lofty::tag::{ItemKey, Tag, TagType, TagExt};
    use lofty::picture::{Picture, PictureType};
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
    let mut file_handle = OpenOptions::new()
        .read(true)
        .write(true)
        .open(file)?;
    tag.save_to(&mut file_handle, WriteOptions::default())?;

    Ok(())
}

fn guess_mime_type(path: &Path) -> lofty::picture::MimeType {
    let ext = path.extension()
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
