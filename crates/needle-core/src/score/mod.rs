use crate::normalize::{NegativeMarker, NormalizedTitle};
use crate::search::Candidate;
use serde::{Deserialize, Serialize};
use strsim::jaro_winkler;

/// Classification after scoring
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ScoreStatus {
    Recommended,
    Uncertain,
    Rejected,
}

/// Explainable score result
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CandidateScore {
    pub confidence: u8,
    pub status: ScoreStatus,
    pub positives: Vec<String>,
    pub warnings: Vec<String>,
    pub rejects: Vec<String>,
}

/// Configuration for scorer
#[derive(Debug, Clone)]
pub struct ScorerConfig {
    pub hard_reject_part_mismatch: bool,
    pub hard_reject_negative_markers: bool,
    pub duration_strictness: DurationStrictness,
    pub allow_instrumental: bool,
    pub allow_live: bool,
    pub allow_lyrics: bool,
    /// Reference metadata duration can be wrong. If false, duration only adds
    /// warnings and positives, never hard rejection.
    pub trust_reference_duration: bool,
}

#[derive(Debug, Clone, Copy, Default)]
pub enum DurationStrictness {
    #[default]
    Normal,
    Strict,
    Loose,
}

impl Default for ScorerConfig {
    fn default() -> Self {
        Self {
            hard_reject_part_mismatch: true,
            hard_reject_negative_markers: true,
            duration_strictness: DurationStrictness::Normal,
            allow_instrumental: false,
            allow_live: false,
            allow_lyrics: true,
            trust_reference_duration: false,
        }
    }
}

impl ScorerConfig {
    fn is_hard_reject_marker(&self, m: &NegativeMarker) -> bool {
        if !self.hard_reject_negative_markers {
            return false;
        }
        match m {
            // Always hard reject regardless of config
            NegativeMarker::Reaction
            | NegativeMarker::Review
            | NegativeMarker::Karaoke
            | NegativeMarker::Cover
            | NegativeMarker::TypeBeat
            | NegativeMarker::Podcast
            | NegativeMarker::Interview
            | NegativeMarker::Tutorial
            | NegativeMarker::SlowedReverb
            | NegativeMarker::SpedUp
            | NegativeMarker::Nightcore
            | NegativeMarker::EightD
            | NegativeMarker::BassBoost => true,
            NegativeMarker::Instrumental => !self.allow_instrumental,
            NegativeMarker::Live => !self.allow_live,
            NegativeMarker::Lyrics | NegativeMarker::LyricVideo => !self.allow_lyrics,
            // Configurable soft markers
            _ => m.is_hard_reject_default(),
        }
    }
}

/// Score a candidate against request and optional metadata
pub fn score_candidate(
    request_artist: &str,
    request_title: &NormalizedTitle,
    candidate: &Candidate,
    expected_duration_ms: Option<u64>,
    config: &ScorerConfig,
) -> CandidateScore {
    let cand_norm = NormalizedTitle::from_raw(&candidate.title);
    let requested_remix_match = request_title
        .negative_markers
        .contains(&NegativeMarker::Remix)
        && cand_norm.negative_markers.contains(&NegativeMarker::Remix)
        && canonical_title_phrase(&candidate.title.to_lowercase())
            .contains(&canonical_title_phrase(&request_title.raw.to_lowercase()));
    let requested_remix = request_title
        .negative_markers
        .contains(&NegativeMarker::Remix);
    let missing_requested_remix =
        requested_remix && !cand_norm.negative_markers.contains(&NegativeMarker::Remix);
    let title_score = if requested_remix_match {
        1.0
    } else if missing_requested_remix {
        fuzzy_title_match(request_title, &cand_norm).min(0.7)
    } else {
        fuzzy_title_match(request_title, &cand_norm)
    };
    let artist_score = fuzzy_artist_match(
        request_artist,
        &candidate.title,
        candidate.uploader.as_deref(),
    );
    let matching_remix = cand_norm.negative_markers.contains(&NegativeMarker::Remix)
        && (requested_remix_match
            || (!requested_remix
                && (title_score >= 0.95 || title_contains_request(request_title, &cand_norm))))
        && artist_score > 0.9;

    let mut rejects = Vec::new();
    let mut warnings = Vec::new();
    let mut positives = Vec::new();
    if missing_requested_remix {
        warnings.push("requested remix not identified".to_string());
    }

    // ─── Hard rejects (more important than scoring) ────────────────────────

    // Series marker mismatch
    if config.hard_reject_part_mismatch {
        if let (Some(ref req_sm), Some(ref cand_sm)) =
            (&request_title.series_marker, &cand_norm.series_marker)
        {
            if req_sm.kind == cand_sm.kind && req_sm.value != cand_sm.value {
                rejects.push(format!(
                    "{} number mismatch: requested {}, found {}",
                    req_sm.kind, req_sm.value, cand_sm.value
                ));
            }
        }
    }

    if let Some(reason) = content_reject_reason(&candidate.title, request_title) {
        rejects.push(reason);
    }

    // Negative markers
    for m in &cand_norm.negative_markers {
        if *m == NegativeMarker::Remix && matching_remix {
            warnings.push(m.label().to_string());
        } else if config.is_hard_reject_marker(m) {
            rejects.push(m.label().to_string());
        } else {
            warnings.push(m.label().to_string());
        }
    }

    // Duration rejection. Only hard-reject duration when identity is not strong.
    // Metadata providers can return edits/snippets with bad durations, and a
    // strong title/series match should remain visible as uncertain.
    if let Some(expected) = expected_duration_ms {
        if let Some(cand_dur) = candidate.duration_ms {
            let delta_ms = expected.abs_diff(cand_dur);
            let threshold = duration_reject_threshold_ms(config.duration_strictness, expected);
            if config.trust_reference_duration && delta_ms > threshold && title_score < 0.95 {
                rejects.push(format!(
                    "duration mismatch: expected {}, found {}",
                    fmt_duration(expected),
                    fmt_duration(cand_dur)
                ));
            }
        }
    }

    // If hard-rejected, return immediately (but still compute reasons for display)
    if !rejects.is_empty() {
        return CandidateScore {
            confidence: 0,
            status: ScoreStatus::Rejected,
            positives: Vec::new(),
            warnings,
            rejects,
        };
    }

    // ─── Positive scoring ──────────────────────────────────────────────────
    let mut score: f32 = 0.0;

    // Artist match (0-25)
    score += artist_score * 25.0;
    if artist_score > 0.9 {
        positives.push("artist exact".to_string());
    } else if artist_score > 0.7 {
        positives.push("artist close".to_string());
    } else if artist_score > 0.5 {
        warnings.push("artist fuzzy".to_string());
    } else {
        warnings.push("artist weak match".to_string());
    }

    // Title match (0-35)
    score += title_score * 35.0;
    if title_score > 0.9 {
        positives.push("title exact".to_string());
    } else if title_score > 0.7 {
        positives.push("title close".to_string());
    } else if title_score > 0.5 {
        warnings.push("title fuzzy".to_string());
    } else {
        warnings.push("title weak match".to_string());
    }

    // Duration match (0-25). Default metadata duration is untrusted because
    // APIs often return edits/snippets. Large mismatch becomes warning-only
    // unless caller explicitly trusts reference duration.
    if let Some(expected) = expected_duration_ms {
        if let Some(cand_dur) = candidate.duration_ms {
            let delta_ms = expected.abs_diff(cand_dur);
            let delta_sec = delta_ms / 1000;
            if delta_sec <= 5 {
                score += 25.0;
                positives.push("duration exact".to_string());
            } else if delta_sec <= 15 {
                score += 15.0;
                positives.push("duration close".to_string());
            } else if delta_sec <= 30 {
                score += 5.0;
                warnings.push("duration suspicious".to_string());
            } else if !config.trust_reference_duration {
                warnings.push("duration mismatched (reference untrusted)".to_string());
            } else {
                score -= 15.0;
                warnings.push("duration mismatched".to_string());
            }
        } else {
            warnings.push("duration unknown".to_string());
        }
    } else {
        warnings.push("no reference duration".to_string());
    }

    // Officialness (0-10)
    if candidate.query_origin == "canonical" {
        score += 15.0;
        positives.push("canonical source (MusicBrainz)".to_string());
    } else if candidate.channel_is_verified == Some(true)
        && candidate.uploader.as_deref().is_some_and(|uploader| {
            !request_artist.trim().is_empty()
                && uploader.trim().eq_ignore_ascii_case(request_artist.trim())
        })
    {
        score += 10.0;
        positives.push("verified artist channel".to_string());
    } else if is_official_channel(candidate) {
        score += 10.0;
        positives.push("official channel".to_string());
    } else if candidate
        .uploader
        .as_deref()
        .unwrap_or("")
        .to_ascii_lowercase()
        .contains("vevo")
    {
        score += 8.0;
        positives.push("vevo upload".to_string());
    } else {
        warnings.push("artist affiliation unconfirmed".to_string());
    }

    apply_provider_prior(candidate, &mut score, &mut warnings);
    apply_popularity_penalty(candidate, &mut score, &mut warnings);

    // Soft negative marker penalty
    let soft_penalty: f32 = cand_norm
        .negative_markers
        .iter()
        .filter(|m| {
            !config.is_hard_reject_marker(m)
                || (**m == NegativeMarker::Remix && matching_remix && !requested_remix_match)
        })
        .count() as f32
        * 5.0;
    score -= soft_penalty;

    // Clamp to 0-100
    let confidence = score.clamp(0.0, if missing_requested_remix { 49.0 } else { 100.0 }) as u8;

    let status = if missing_requested_remix {
        ScoreStatus::Uncertain
    } else if confidence >= 85 {
        ScoreStatus::Recommended
    } else if confidence >= 50 || (rejects.is_empty() && title_score >= 0.95) {
        ScoreStatus::Uncertain
    } else {
        ScoreStatus::Rejected
    };

    CandidateScore {
        confidence,
        status,
        positives,
        warnings,
        rejects,
    }
}

/// Infer likely track duration from candidate consensus.
///
/// Used when metadata providers return a radio edit/snippet duration. Only exact
/// identity matches participate, then durations are bucketed in 10-second bins.
/// A consensus needs at least 3 candidates in one bucket and at least 50% of
/// eligible candidates, so isolated bad uploads cannot define truth.
pub fn infer_consensus_duration_ms(
    request_artist: &str,
    request_title: &NormalizedTitle,
    candidates: &[Candidate],
) -> Option<u64> {
    use std::collections::BTreeMap;

    let eligible: Vec<u64> = candidates
        .iter()
        .filter(|c| fuzzy_artist_match(request_artist, &c.title, c.uploader.as_deref()) > 0.9)
        .filter(|c| fuzzy_title_match(request_title, &NormalizedTitle::from_raw(&c.title)) >= 0.95)
        .filter_map(|c| c.duration_ms)
        .filter(|d| (60_000..=900_000).contains(d))
        .collect();

    if eligible.len() < 3 {
        return None;
    }

    let mut buckets: BTreeMap<u64, Vec<u64>> = BTreeMap::new();
    for duration in eligible.iter().copied() {
        let bucket = duration / 10_000;
        buckets.entry(bucket).or_default().push(duration);
    }

    let best = buckets
        .into_values()
        .max_by_key(|durations| durations.len())?;

    if best.len() < 3 || best.len() * 2 < eligible.len() {
        return None;
    }

    let sum: u64 = best.iter().sum();
    Some(sum / best.len() as u64)
}

// ─── Helpers ────────────────────────────────────────────────────────────────

fn fuzzy_artist_match(request_artist: &str, candidate_title: &str, uploader: Option<&str>) -> f32 {
    let req_lower = request_artist.to_ascii_lowercase();
    let cand_lower = candidate_title.to_ascii_lowercase();
    let up_lower = uploader.map(|u| u.to_ascii_lowercase());

    // Exact match in title or uploader
    if cand_lower.contains(&req_lower) || up_lower.as_ref().is_some_and(|u| u.contains(&req_lower))
    {
        return 1.0;
    }

    // Jaro-Winkler on title + uploader combined
    let combined = format!("{} {}", cand_lower, up_lower.as_deref().unwrap_or(""));
    jaro_winkler(&req_lower, &combined) as f32
}

fn fuzzy_title_match(req: &NormalizedTitle, cand: &NormalizedTitle) -> f32 {
    if cand.base_title.contains(&req.base_title) {
        return match (&req.series_marker, &cand.series_marker) {
            (Some(r), Some(c)) if r.kind == c.kind && r.value == c.value => 1.0,
            (None, None) => 1.0,
            _ => 0.9,
        };
    }

    // Base title match
    let base_sim = jaro_winkler(&req.base_title, &cand.base_title) as f32;

    // If series markers both exist and match, bonus
    let series_bonus = match (&req.series_marker, &cand.series_marker) {
        (Some(r), Some(c)) if r.kind == c.kind && r.value == c.value => 0.15,
        (None, None) => 0.05,
        (Some(_), None) | (None, Some(_)) => -0.1,
        _ => 0.0,
    };

    (base_sim + series_bonus).clamp(0.0, 1.0)
}

fn title_contains_request(request: &NormalizedTitle, candidate: &NormalizedTitle) -> bool {
    let request_title = canonical_title_phrase(&request.base_title);
    let candidate_title = canonical_title_phrase(&candidate.base_title);

    !request_title.is_empty() && candidate_title.contains(&request_title)
}

fn canonical_title_phrase(title: &str) -> String {
    title
        .chars()
        .filter_map(|c| {
            if c == '\'' || c == '’' {
                None
            } else if c.is_alphanumeric() {
                Some(c)
            } else {
                Some(' ')
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn is_official_channel(candidate: &Candidate) -> bool {
    let up = candidate
        .uploader
        .as_deref()
        .unwrap_or("")
        .to_ascii_lowercase();
    let title = candidate.title.to_ascii_lowercase();

    // YouTube: topic channels, vevo, official in title
    if up.contains("- topic") || up.ends_with("vevo") || title.contains("(official") {
        return true;
    }

    // SoundCloud/YouTube: label/entertainment channels
    // Common patterns: "records", "entertainment", "music", "label", "official"
    let label_patterns = [
        "records",
        "recordings",
        "entertainment",
        "music group",
        "label",
        "official",
        "publishing",
        "productions",
    ];
    if label_patterns.iter().any(|p| up.contains(p)) {
        return true;
    }

    // Many labels abbreviate "Entertainment" as "Ent" at end of username.
    // RocNation, TopDawgEnt, AftermathEnt, etc. — common pattern with low
    // false positives since personal accounts rarely end with "ent".
    if up.len() >= 6 && up.ends_with("ent") {
        return true;
    }

    false
}

fn content_reject_reason(title: &str, request_title: &NormalizedTitle) -> Option<String> {
    let t = title.to_ascii_lowercase();
    let specific = [
        ("rhyme scheme", "analysis/rhyme scheme"),
        ("favourite verse", "interview/clip"),
        ("favorite verse", "interview/clip"),
        ("on-screen lyrics", "lyrics video"),
    ];
    if let Some(reason) = specific.iter().find_map(|(needle, label)| {
        t.contains(needle)
            .then(|| format!("non-recording content: {label}"))
    }) {
        return Some(reason);
    }

    let annotation = annotation_text(&t);
    let request = request_title.raw.to_ascii_lowercase();
    let request_base = request_title.base_title.to_ascii_lowercase();
    let ambiguous = [
        ("highlighted", "analysis/highlighted"),
        ("analysis", "analysis"),
        ("explained", "analysis/explained"),
        ("breakdown", "analysis/breakdown"),
        ("no intro", "edited/no intro"),
    ];
    ambiguous.iter().find_map(|(needle, label)| {
        if request.contains(needle) {
            return None;
        }
        let in_annotation = annotation.contains(needle);
        let extra_on_matching_title =
            t.contains(needle) && !request_base.is_empty() && t.contains(&request_base);
        (in_annotation || extra_on_matching_title)
            .then(|| format!("non-recording content: {label}"))
    })
}

fn annotation_text(title: &str) -> String {
    let mut out = String::new();
    let mut depth = 0i32;
    for ch in title.chars() {
        match ch {
            '(' | '[' | '{' => depth += 1,
            ')' | ']' | '}' => depth = (depth - 1).max(0),
            _ if depth > 0 => out.push(ch),
            _ => {}
        }
    }
    if let Some((_, after_pipe)) = title.split_once('|') {
        out.push(' ');
        out.push_str(after_pipe);
    }
    out
}

fn apply_popularity_penalty(candidate: &Candidate, score: &mut f32, warnings: &mut Vec<String>) {
    let Some(views) = candidate.view_count else {
        if candidate.provider == "soundcloud" {
            warnings.push("popularity unknown".to_string());
            *score -= 5.0;
        }
        return;
    };

    let penalty = match candidate.provider.as_str() {
        "youtube" if views < 1_000 => 15.0,
        "youtube" if views < 10_000 => 5.0,
        "soundcloud" if views < 500 => 20.0,
        "soundcloud" if views < 5_000 => 10.0,
        _ => 0.0,
    };

    if penalty > 0.0 {
        *score -= penalty;
        warnings.push(format!("low popularity ({views} views)"));
    }
}

fn apply_provider_prior(candidate: &Candidate, score: &mut f32, warnings: &mut Vec<String>) {
    // Skip source penalty if it's the canonical source from MusicBrainz
    if candidate.query_origin == "canonical" {
        return;
    }
    if candidate.provider == "soundcloud" {
        *score -= 5.0;
        warnings.push("source less authoritative".to_string());
    }
}

fn duration_reject_threshold_ms(strictness: DurationStrictness, _expected: u64) -> u64 {
    match strictness {
        DurationStrictness::Strict => 15_000, // 15s
        DurationStrictness::Normal => 45_000, // 45s
        DurationStrictness::Loose => 120_000, // 2min
    }
}

fn fmt_duration(ms: u64) -> String {
    let total_sec = ms / 1000;
    let m = total_sec / 60;
    let s = total_sec % 60;
    format!("{}:{:02}", m, s)
}

// Re-export

#[cfg(test)]
mod tests {
    use super::*;
    use crate::normalize::normalize_title;
    use crate::search::Candidate;

    fn make_candidate(title: &str, duration_ms: Option<u64>) -> Candidate {
        Candidate {
            provider: "youtube".into(),
            id: "test".into(),
            url: "https://youtu.be/test".into(),
            title: title.into(),
            uploader: Some("Uploader".into()),
            channel_is_verified: None,
            duration_ms,
            thumbnail_url: None,
            view_count: None,
            audio_codec: None,
            audio_bitrate_kbps: None,
            query_origin: "test".into(),
        }
    }

    fn with_provider_and_views(
        mut candidate: Candidate,
        provider: &str,
        views: Option<u64>,
    ) -> Candidate {
        candidate.provider = provider.into();
        candidate.view_count = views;
        candidate
    }

    #[test]
    fn hard_rejects_part_mismatch() {
        let req_norm = normalize_title("The Heart Pt. 2");
        let cand = make_candidate("The Heart Part 5", Some(332_000));
        let score = score_candidate(
            "Kendrick Lamar",
            &req_norm,
            &cand,
            Some(294_000),
            &ScorerConfig::default(),
        );
        assert_eq!(score.status, ScoreStatus::Rejected);
        assert!(score.rejects.iter().any(|r| r.contains("mismatch")));
    }

    #[test]
    fn hard_rejects_reaction() {
        let req_norm = normalize_title("The Heart Pt. 2");
        let cand = make_candidate("The Heart Pt. 2 REACTION", Some(294_000));
        let score = score_candidate(
            "Kendrick Lamar",
            &req_norm,
            &cand,
            Some(294_000),
            &ScorerConfig::default(),
        );
        assert_eq!(score.status, ScoreStatus::Rejected);
        assert!(score.rejects.iter().any(|r| r.contains("reaction")));
    }

    #[test]
    fn allows_matching_remix() {
        let req_norm = normalize_title("Let's Get It Started");
        let cand = make_candidate(
            "The Black Eyed Peas - Let's Get It Started (Levity x Crankdat Remix)",
            Some(223_000),
        );
        let score = score_candidate(
            "Levity",
            &req_norm,
            &cand,
            Some(223_000),
            &ScorerConfig::default(),
        );

        assert_ne!(score.status, ScoreStatus::Rejected);
        assert!(score.rejects.is_empty());
        assert!(score.warnings.iter().any(|w| w == "remix"));
    }

    #[test]
    fn allows_explicitly_requested_remix_with_parenthesized_version() {
        let request = normalize_title("Wanderlust Snakehips remix");
        let candidate = make_candidate("The Weeknd - Wanderlust (Snakehips Remix)", Some(223_000));
        let score = score_candidate(
            "The Weeknd",
            &request,
            &candidate,
            None,
            &ScorerConfig::default(),
        );
        assert_ne!(score.status, ScoreStatus::Rejected, "{score:?}");
        assert!(score.rejects.is_empty());
    }

    #[test]
    fn requested_remix_ranks_above_original_recording() {
        let request = normalize_title("Wanderlust Snakehips remix");
        let mut original = make_candidate("Wanderlust", Some(307_000));
        original.uploader = Some("The Weeknd".into());
        let remix = make_candidate("The Weeknd - Wanderlust (Snakehips Remix)", Some(223_000));
        let original_score = score_candidate(
            "The Weeknd",
            &request,
            &original,
            None,
            &ScorerConfig::default(),
        );
        let remix_score = score_candidate(
            "The Weeknd",
            &request,
            &remix,
            None,
            &ScorerConfig::default(),
        );
        assert!(
            remix_score.confidence > original_score.confidence,
            "remix: {remix_score:?}, original: {original_score:?}"
        );
        assert!(original_score
            .warnings
            .iter()
            .any(|w| w.contains("requested remix")));
        assert!(!original_score.positives.iter().any(|p| p == "title exact"));

        original.channel_is_verified = Some(true);
        let parenthesized = normalize_title("Wanderlust (Snakehips Remix)");
        let original_score = score_candidate(
            "The Weeknd",
            &parenthesized,
            &original,
            Some(307_000),
            &ScorerConfig::default(),
        );
        let remix_score = score_candidate(
            "The Weeknd",
            &parenthesized,
            &remix,
            Some(307_000),
            &ScorerConfig::default(),
        );
        assert!(
            remix_score.confidence > original_score.confidence,
            "remix: {remix_score:?}, original: {original_score:?}"
        );
    }

    #[test]
    fn unknown_channel_is_not_claimed_to_be_unofficial() {
        let request = normalize_title("Wanderlust");
        let mut candidate = make_candidate("Wanderlust", Some(307_000));
        candidate.uploader = Some("The Weeknd".into());
        let score = score_candidate(
            "The Weeknd",
            &request,
            &candidate,
            None,
            &ScorerConfig::default(),
        );
        assert!(!score.warnings.iter().any(|w| w == "unofficial upload"));
    }

    #[test]
    fn identifies_verified_matching_artist_channel() {
        let request = normalize_title("Wanderlust");
        let mut candidate = make_candidate("Wanderlust", Some(307_000));
        candidate.uploader = Some("The Weeknd".into());
        candidate.channel_is_verified = Some(true);
        let score = score_candidate(
            "The Weeknd",
            &request,
            &candidate,
            None,
            &ScorerConfig::default(),
        );
        assert!(score
            .positives
            .iter()
            .any(|p| p == "verified artist channel"));
        assert!(!score
            .warnings
            .iter()
            .any(|w| w == "artist affiliation unconfirmed"));
    }

    #[test]
    fn verified_unrelated_channel_is_not_identified_as_artist() {
        let request = normalize_title("Wanderlust");
        let mut candidate = make_candidate("The Weeknd - Wanderlust", Some(307_000));
        candidate.uploader = Some("Majestic Casual".into());
        candidate.channel_is_verified = Some(true);
        let score = score_candidate(
            "The Weeknd",
            &request,
            &candidate,
            None,
            &ScorerConfig::default(),
        );
        assert!(!score
            .positives
            .iter()
            .any(|p| p == "verified artist channel"));
    }

    #[test]
    fn rejects_a_different_remix_when_a_version_is_requested() {
        let request = normalize_title("Wanderlust Snakehips remix");
        let candidate = make_candidate("The Weeknd - Wanderlust (Other Remix)", Some(223_000));
        let score = score_candidate(
            "The Weeknd",
            &request,
            &candidate,
            None,
            &ScorerConfig::default(),
        );
        assert_eq!(score.status, ScoreStatus::Rejected);
        assert!(score.rejects.iter().any(|reason| reason == "remix"));
    }

    #[test]
    fn rejects_wrong_remixer_for_parenthesized_request() {
        let request = normalize_title("Wanderlust (Snakehips Remix)");
        let candidate = make_candidate("The Weeknd - Wanderlust (Pharrell Remix)", Some(223_000));
        let score = score_candidate(
            "The Weeknd",
            &request,
            &candidate,
            None,
            &ScorerConfig::default(),
        );
        assert_eq!(score.status, ScoreStatus::Rejected);
        assert!(score.rejects.iter().any(|reason| reason == "remix"));
    }

    #[test]
    fn hard_rejects_unmatched_remix() {
        let req_norm = normalize_title("Let's Get It Started");
        let cand = make_candidate("Toxic (Levity Remix)", Some(223_000));
        let score = score_candidate(
            "Levity",
            &req_norm,
            &cand,
            Some(223_000),
            &ScorerConfig::default(),
        );

        assert_eq!(score.status, ScoreStatus::Rejected);
        assert!(score.rejects.iter().any(|r| r == "remix"));
    }

    #[test]
    fn accepts_exact_match() {
        let req_norm = normalize_title("The Heart Pt. 2");
        let mut cand = make_candidate("Kendrick Lamar - The Heart Pt. 2", Some(294_000));
        cand.uploader = Some("Kendrick Archive".into());
        let score = score_candidate(
            "Kendrick Lamar",
            &req_norm,
            &cand,
            Some(294_000),
            &ScorerConfig::default(),
        );
        assert_eq!(score.status, ScoreStatus::Recommended);
        assert!(score.confidence > 80);
    }

    #[test]
    fn lyrics_marked_uncertain() {
        let req_norm = normalize_title("The Heart Pt. 2");
        let cand = make_candidate("Kendrick Lamar - The Heart Part 2 Lyrics", Some(294_000));
        let score = score_candidate(
            "Kendrick Lamar",
            &req_norm,
            &cand,
            Some(294_000),
            &ScorerConfig::default(),
        );
        // Lyrics is soft marker by default → uncertain not rejected
        assert!(matches!(
            score.status,
            ScoreStatus::Uncertain | ScoreStatus::Recommended
        ));
    }

    #[test]
    fn strong_title_match_survives_bad_reference_duration() {
        let req_norm = normalize_title("The Heart Pt. 2");
        let cand = make_candidate("Kendrick Lamar - The Heart Pt. 2", Some(296_000));
        let score = score_candidate(
            "Kendrick Lamar",
            &req_norm,
            &cand,
            Some(224_000),
            &ScorerConfig::default(),
        );
        assert_ne!(score.status, ScoreStatus::Rejected);
        assert!(score.rejects.is_empty());
        assert!(score.warnings.iter().any(|w| w.contains("duration")));
    }

    #[test]
    fn analysis_video_scores_below_full_track_when_duration_reference_bad() {
        let req_norm = normalize_title("The Heart Pt. 2");
        let analysis = make_candidate(
            "Kendrick Lamar, The Heart Part 2 | Rhyme Scheme Highlighted",
            Some(216_000),
        );
        let track = make_candidate("Kendrick Lamar - The Heart Pt. 2 - Lyrics", Some(294_000));
        let analysis_score = score_candidate(
            "Kendrick Lamar",
            &req_norm,
            &analysis,
            Some(224_000),
            &ScorerConfig::default(),
        );
        let track_score = score_candidate(
            "Kendrick Lamar",
            &req_norm,
            &track,
            Some(224_000),
            &ScorerConfig::default(),
        );

        assert_eq!(
            analysis_score.status,
            ScoreStatus::Rejected,
            "{analysis_score:?}"
        );
        assert!(analysis_score
            .rejects
            .iter()
            .any(|reason| reason.contains("analysis")));
        assert_ne!(track_score.status, ScoreStatus::Rejected, "{track_score:?}");
        assert!(
            track_score.confidence > analysis_score.confidence,
            "track={track_score:?} analysis={analysis_score:?}"
        );
    }

    #[test]
    fn real_title_breakdown_is_not_an_analysis_reject() {
        let req_norm = normalize_title("Breakdown");
        let track = make_candidate("Artist - Breakdown", Some(200_000));
        let score = score_candidate(
            "Artist",
            &req_norm,
            &track,
            Some(200_000),
            &ScorerConfig::default(),
        );

        assert!(
            score
                .rejects
                .iter()
                .all(|reason| !reason.contains("analysis")),
            "{score:?}"
        );
    }

    #[test]
    fn parenthetical_analysis_tag_is_rejected() {
        let req_norm = normalize_title("Song");
        let analysis = make_candidate("Artist - Song (Analysis)", Some(200_000));
        let score = score_candidate(
            "Artist",
            &req_norm,
            &analysis,
            Some(200_000),
            &ScorerConfig::default(),
        );

        assert_eq!(score.status, ScoreStatus::Rejected, "{score:?}");
        assert!(score
            .rejects
            .iter()
            .any(|reason| reason.contains("analysis")));
    }

    #[test]
    fn infers_consensus_duration_from_exact_candidate_cluster() {
        let req_norm = normalize_title("The Heart Pt. 2");
        let candidates = vec![
            make_candidate("Kendrick Lamar - The Heart Pt. 2", Some(294_000)),
            make_candidate("Kendrick Lamar - The Heart Pt. 2 - Lyrics", Some(296_000)),
            make_candidate(
                "Kendrick Lamar ft. Dash Snow - The Heart Pt 2",
                Some(297_000),
            ),
            make_candidate(
                "Kendrick Lamar, The Heart Part 2 | Rhyme Scheme Highlighted",
                Some(216_000),
            ),
            make_candidate("Kendrick Lamar - The Heart Part 5", Some(332_000)),
        ];

        let inferred =
            infer_consensus_duration_ms("Kendrick Lamar", &req_norm, &candidates).unwrap();
        assert!(
            (294_000..=297_000).contains(&inferred),
            "inferred={inferred}"
        );
    }

    #[test]
    fn does_not_infer_consensus_from_weak_cluster() {
        let req_norm = normalize_title("The Heart Pt. 2");
        let candidates = vec![
            make_candidate("Kendrick Lamar - The Heart Pt. 2", Some(294_000)),
            make_candidate("Kendrick Lamar - The Heart Pt. 2", Some(216_000)),
            make_candidate("Kendrick Lamar - The Heart Pt. 2", Some(86_000)),
        ];

        assert_eq!(
            infer_consensus_duration_ms("Kendrick Lamar", &req_norm, &candidates),
            None
        );
    }

    #[test]
    fn low_popularity_soundcloud_candidate_is_penalized() {
        let req_norm = normalize_title("The Heart Pt. 2");
        let popular = with_provider_and_views(
            make_candidate("Kendrick Lamar - The Heart Pt. 2", Some(294_000)),
            "youtube",
            Some(100_000),
        );
        let low_popularity = with_provider_and_views(
            make_candidate("Kendrick Lamar - The Heart Pt. 2", Some(294_000)),
            "soundcloud",
            Some(100),
        );

        let popular_score = score_candidate(
            "Kendrick Lamar",
            &req_norm,
            &popular,
            Some(294_000),
            &ScorerConfig::default(),
        );
        let low_score = score_candidate(
            "Kendrick Lamar",
            &req_norm,
            &low_popularity,
            Some(294_000),
            &ScorerConfig::default(),
        );

        assert!(
            popular_score.confidence > low_score.confidence,
            "popular={popular_score:?} low={low_score:?}"
        );
        assert!(low_score
            .warnings
            .iter()
            .any(|w| w.contains("low popularity")));
    }
}
