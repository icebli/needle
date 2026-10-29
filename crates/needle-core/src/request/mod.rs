use anyhow::{bail, Result};
use serde::{Deserialize, Serialize};

/// Raw user request before parsing
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrackRequest {
    /// Free-form artist string
    pub artist: String,
    /// Free-form title string
    pub title: String,
    /// Optional album hint
    pub album: Option<String>,
    /// Explicit URL to use (skip search)
    pub url: Option<String>,
    /// Desired output format
    pub format: OutputFormat,
    /// Output profile name
    pub profile: String,
}

impl TrackRequest {
    pub fn new(artist: impl Into<String>, title: impl Into<String>) -> Self {
        Self {
            artist: artist.into(),
            title: title.into(),
            album: None,
            url: None,
            format: OutputFormat::Mp3,
            profile: "default".into(),
        }
    }

    /// Parse "Artist - Title" free-form string
    pub fn from_combined(s: &str) -> Result<Self> {
        let parts: Vec<&str> = s.splitn(2, " - ").collect();
        match parts.as_slice() {
            [artist, title] => Ok(Self::new(artist.trim(), title.trim())),
            _ => bail!("expected 'Artist - Title' format, got: {s:?}"),
        }
    }
}

/// Parsed + validated request
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ParsedRequest {
    pub artist: String,
    pub title: String,
    pub album: Option<String>,
    pub url: Option<String>,
    pub format: OutputFormat,
    pub profile: String,
}

impl From<TrackRequest> for ParsedRequest {
    fn from(r: TrackRequest) -> Self {
        Self {
            artist: r.artist.trim().to_string(),
            title: r.title.trim().to_string(),
            album: r.album,
            url: r.url,
            format: r.format,
            profile: r.profile,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum OutputFormat {
    #[default]
    Mp3,
    M4a,
    Opus,
    Flac,
}

impl OutputFormat {
    pub fn extension(&self) -> &'static str {
        match self {
            Self::Mp3 => "mp3",
            Self::M4a => "m4a",
            Self::Opus => "opus",
            Self::Flac => "flac",
        }
    }

    pub fn ffmpeg_codec(&self) -> &'static str {
        match self {
            Self::Mp3 => "libmp3lame",
            Self::M4a => "aac",
            Self::Opus => "libopus",
            Self::Flac => "flac",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_combined() {
        let r = TrackRequest::from_combined("Kendrick Lamar - The Heart Pt. 2").unwrap();
        assert_eq!(r.artist, "Kendrick Lamar");
        assert_eq!(r.title, "The Heart Pt. 2");
    }

    #[test]
    fn parse_combined_err() {
        assert!(TrackRequest::from_combined("no dash here").is_err());
    }

    #[test]
    fn output_format_names_match_ffmpeg_codecs() {
        assert_eq!(OutputFormat::default(), OutputFormat::Mp3);
        let cases = [
            (OutputFormat::Mp3, "mp3", "libmp3lame"),
            (OutputFormat::M4a, "m4a", "aac"),
            (OutputFormat::Opus, "opus", "libopus"),
            (OutputFormat::Flac, "flac", "flac"),
        ];
        for (format, extension, codec) in cases {
            assert_eq!(format.extension(), extension);
            assert_eq!(format.ffmpeg_codec(), codec);
        }
    }
}
