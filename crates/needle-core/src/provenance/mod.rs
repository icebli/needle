use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Immutable record of how a file was produced
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Provenance {
    pub requested: RequestedTrack,
    pub selected_source: SelectedSource,
    pub scoring: ScoringRecord,
    pub metadata: MetadataRecord,
    pub created_by: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MetadataRecord {
    /// Which provider won ("musicbrainz" | "itunes" | "none")
    pub provider: String,
    pub plausibility_score: Option<i32>,
    pub recording_id: Option<String>,
    /// What the provider returned for artist, title, album
    pub resolved_artist: Option<String>,
    pub resolved_title: Option<String>,
    pub resolved_album: Option<String>,
    pub featured_artists: Vec<String>,
    pub re_queried: bool,
    pub canonical_url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RequestedTrack {
    pub artist: String,
    pub title: String,
    pub album: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SelectedSource {
    pub provider: String,
    pub id: String,
    pub title: String,
    pub duration_ms: Option<u64>,
    pub url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScoringRecord {
    pub confidence: u8,
    pub reasons: Vec<String>,
}

impl Provenance {
    pub fn write(&self, path: &PathBuf) -> anyhow::Result<()> {
        let json = serde_json::to_string_pretty(self)?;
        std::fs::write(path, json)?;
        Ok(())
    }
}
