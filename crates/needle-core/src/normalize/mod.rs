use regex::Regex;
use serde::{Deserialize, Serialize};
use std::sync::OnceLock;
use unicode_normalization::UnicodeNormalization;

/// A title fully broken down for comparison
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct NormalizedTitle {
    pub raw: String,
    pub normalized: String,
    pub base_title: String,
    pub series_marker: Option<SeriesMarker>,
    pub version_markers: Vec<String>,
    pub negative_markers: Vec<NegativeMarker>,
}

impl NormalizedTitle {
    pub fn from_raw(raw: &str) -> Self {
        normalize_title(raw)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SeriesMarker {
    pub kind: SeriesKind,
    pub value: u32,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SeriesKind {
    Part,
    Volume,
    Chapter,
    Episode,
    Season,
    Side,
}

impl std::fmt::Display for SeriesKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Part => write!(f, "part"),
            Self::Volume => write!(f, "volume"),
            Self::Chapter => write!(f, "chapter"),
            Self::Episode => write!(f, "episode"),
            Self::Season => write!(f, "season"),
            Self::Side => write!(f, "side"),
        }
    }
}

/// Markers that indicate a derivative/unwanted version
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum NegativeMarker {
    // Hard rejects by default
    Reaction,
    Review,
    Instrumental,
    Karaoke,
    Cover,
    Remix,
    TypeBeat,
    Podcast,
    Interview,
    Tutorial,
    // Usually hard rejects
    SlowedReverb,
    SpedUp,
    Nightcore,
    EightD,
    BassBoost,
    ChoppedNotSlopped,
    // Soft rejects (configurable)
    Lyrics,
    LyricVideo,
    Visualizer,
    Live,
    Acoustic,
    CleanVersion,
    RadioEdit,
    Remaster,
}

impl NegativeMarker {
    pub fn is_hard_reject_default(&self) -> bool {
        matches!(
            self,
            Self::Reaction
                | Self::Review
                | Self::Instrumental
                | Self::Karaoke
                | Self::Cover
                | Self::Remix
                | Self::TypeBeat
                | Self::Podcast
                | Self::Interview
                | Self::Tutorial
                | Self::SlowedReverb
                | Self::SpedUp
                | Self::Nightcore
                | Self::EightD
                | Self::BassBoost
                | Self::ChoppedNotSlopped
        )
    }

    pub fn label(&self) -> &'static str {
        match self {
            Self::Reaction => "reaction",
            Self::Review => "review",
            Self::Instrumental => "instrumental",
            Self::Karaoke => "karaoke",
            Self::Cover => "cover",
            Self::Remix => "remix",
            Self::TypeBeat => "type beat",
            Self::Podcast => "podcast",
            Self::Interview => "interview",
            Self::Tutorial => "tutorial",
            Self::SlowedReverb => "slowed/reverb",
            Self::SpedUp => "sped up",
            Self::Nightcore => "nightcore",
            Self::EightD => "8d audio",
            Self::BassBoost => "bass boost",
            Self::ChoppedNotSlopped => "chopped not slopped",
            Self::Lyrics => "lyrics",
            Self::LyricVideo => "lyric video",
            Self::Visualizer => "visualizer",
            Self::Live => "live",
            Self::Acoustic => "acoustic",
            Self::CleanVersion => "clean",
            Self::RadioEdit => "radio edit",
            Self::Remaster => "remaster",
        }
    }
}

// ─── Regex helpers ────────────────────────────────────────────────────────────

fn re_series() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r"(?i)\b(part|pt\.?|volume|vol\.?|chapter|ch\.?|episode|ep\.?|season|side)\s*\.?\s*(i{1,3}v?|v?i{1,3}|[0-9]+)\b"
        ).unwrap()
    })
}

fn re_feat() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?i)\s*[\(\[](feat\.?|ft\.?|featuring)[^\)\]]*[\)\]]").unwrap())
}

fn re_parens() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\s*[\(\[][^\)\]]*[\)\]]").unwrap())
}

// ─── Roman numeral parser ─────────────────────────────────────────────────────

/// Convert common roman numerals (I..XII) to u32. Returns None if not recognized.
fn roman_to_u32(s: &str) -> Option<u32> {
    match s.to_ascii_uppercase().as_str() {
        "I" => Some(1),
        "II" => Some(2),
        "III" => Some(3),
        "IV" => Some(4),
        "V" => Some(5),
        "VI" => Some(6),
        "VII" => Some(7),
        "VIII" => Some(8),
        "IX" => Some(9),
        "X" => Some(10),
        "XI" => Some(11),
        "XII" => Some(12),
        _ => None,
    }
}

/// Normalize a series kind token to canonical SeriesKind
fn parse_series_kind(s: &str) -> SeriesKind {
    let s = s.to_ascii_lowercase();
    let s = s.trim_end_matches('.');
    match s {
        "part" | "pt" => SeriesKind::Part,
        "volume" | "vol" => SeriesKind::Volume,
        "chapter" | "ch" => SeriesKind::Chapter,
        "episode" | "ep" => SeriesKind::Episode,
        "season" => SeriesKind::Season,
        "side" => SeriesKind::Side,
        _ => SeriesKind::Part,
    }
}

// ─── Negative marker detection ────────────────────────────────────────────────

fn detect_negative_markers(normalized: &str) -> Vec<NegativeMarker> {
    let mut markers = Vec::new();
    let n = normalized;

    if n.contains("reaction") {
        markers.push(NegativeMarker::Reaction);
    }
    if n.contains("review") {
        markers.push(NegativeMarker::Review);
    }
    if n.contains("instrumental") {
        markers.push(NegativeMarker::Instrumental);
    }
    if n.contains("karaoke") {
        markers.push(NegativeMarker::Karaoke);
    }
    // "cover" but not "discover" / "recover"
    if regex_contains(n, r"\bcover\b") {
        markers.push(NegativeMarker::Cover);
    }
    if regex_contains(n, r"\bremix\b") {
        markers.push(NegativeMarker::Remix);
    }
    // catch compound mix tags: "waowmix", "drumix", "jazzymix" etc.
    // \b[a-z]{2,}mix\b won't match "climax"/"matrix" (don't end in "mix")
    if !markers.contains(&NegativeMarker::Remix) && regex_contains(n, r"\b[a-z]{2,}mix\b") {
        markers.push(NegativeMarker::Remix);
    }
    if n.contains("type beat") {
        markers.push(NegativeMarker::TypeBeat);
    }
    if n.contains("podcast") {
        markers.push(NegativeMarker::Podcast);
    }
    if n.contains("interview") {
        markers.push(NegativeMarker::Interview);
    }
    if n.contains("tutorial") {
        markers.push(NegativeMarker::Tutorial);
    }
    if n.contains("slowed") || (n.contains("slow") && n.contains("reverb")) {
        markers.push(NegativeMarker::SlowedReverb);
    }
    if n.contains("sped up") || n.contains("speed up") {
        markers.push(NegativeMarker::SpedUp);
    }
    if n.contains("nightcore") {
        markers.push(NegativeMarker::Nightcore);
    }
    if regex_contains(n, r"\b8\s*d\b") {
        markers.push(NegativeMarker::EightD);
    }
    if n.contains("bass boost") {
        markers.push(NegativeMarker::BassBoost);
    }
    if n.contains("chopped not slopped") || n.contains("chopped & slopped") {
        markers.push(NegativeMarker::ChoppedNotSlopped);
    }
    if regex_contains(n, r"\blyric\b") {
        markers.push(NegativeMarker::Lyrics);
    }
    if n.contains("lyric video") {
        markers.push(NegativeMarker::LyricVideo);
    }
    if n.contains("visualizer") || n.contains("visualiser") {
        markers.push(NegativeMarker::Visualizer);
    }
    if regex_contains(n, r"\blive\b") {
        markers.push(NegativeMarker::Live);
    }
    if regex_contains(n, r"\bacoustic\b") {
        markers.push(NegativeMarker::Acoustic);
    }
    if regex_contains(n, r"\bclean\b") {
        markers.push(NegativeMarker::CleanVersion);
    }
    if n.contains("radio edit") {
        markers.push(NegativeMarker::RadioEdit);
    }
    if n.contains("remaster") || n.contains("remastered") {
        markers.push(NegativeMarker::Remaster);
    }

    markers
}

fn regex_contains(s: &str, pattern: &str) -> bool {
    Regex::new(pattern)
        .map(|re| re.is_match(s))
        .unwrap_or(false)
}

// ─── Main normalizer ──────────────────────────────────────────────────────────

/// Normalize a raw track title for comparison
pub fn normalize_title(raw: &str) -> NormalizedTitle {
    // Unicode NFC
    let normalized: String = raw.nfc().collect::<String>().to_ascii_lowercase();

    // Remove feat. parentheticals first
    let no_feat = re_feat().replace_all(&normalized, "").to_string();

    // Detect negative markers before stripping parens
    let negative_markers = detect_negative_markers(&no_feat);

    // Strip remaining parentheticals for base comparison
    let stripped = re_parens().replace_all(&no_feat, "").to_string();

    // Extract series marker
    let series_marker = extract_series_marker(&stripped);

    // Remove series marker from title to get base
    let base_title = re_series().replace_all(&stripped, "").trim().to_string();
    let base_title = clean_trailing_punctuation(&base_title);

    // Version markers (explicit, unofficial, etc.)
    let version_markers = detect_version_markers(raw);

    NormalizedTitle {
        raw: raw.to_string(),
        normalized: stripped.trim().to_string(),
        base_title,
        series_marker,
        version_markers,
        negative_markers,
    }
}

fn extract_series_marker(s: &str) -> Option<SeriesMarker> {
    let re = re_series();
    re.captures(s).and_then(|caps| {
        let kind_str = caps.get(1)?.as_str();
        let num_str = caps.get(2)?.as_str();

        let kind = parse_series_kind(kind_str);
        let value = num_str
            .parse::<u32>()
            .ok()
            .or_else(|| roman_to_u32(num_str))?;

        Some(SeriesMarker { kind, value })
    })
}

fn detect_version_markers(raw: &str) -> Vec<String> {
    let mut markers = Vec::new();
    let lower = raw.to_ascii_lowercase();
    if lower.contains("official") {
        markers.push("official".into());
    }
    if lower.contains("explicit") {
        markers.push("explicit".into());
    }
    if lower.contains("hd") || lower.contains("hq") {
        markers.push("hd/hq".into());
    }
    markers
}

fn clean_trailing_punctuation(s: &str) -> String {
    s.trim_end_matches(|c: char| c == '-' || c == ',' || c == ':' || c.is_whitespace())
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_pt2() {
        let n = normalize_title("The Heart Pt. 2");
        assert_eq!(
            n.series_marker,
            Some(SeriesMarker {
                kind: SeriesKind::Part,
                value: 2
            })
        );
        assert!(n.base_title.contains("the heart"));
    }

    #[test]
    fn normalizes_part_ii() {
        let n = normalize_title("The Heart Part II");
        assert_eq!(
            n.series_marker,
            Some(SeriesMarker {
                kind: SeriesKind::Part,
                value: 2
            })
        );
    }

    #[test]
    fn part_5_is_different_from_part_2() {
        let req = normalize_title("The Heart Pt. 2");
        let cand = normalize_title("The Heart Part 5");
        assert_ne!(req.series_marker, cand.series_marker);
    }

    #[test]
    fn detects_reaction() {
        let n = normalize_title("Kendrick Lamar - The Heart Pt. 2 REACTION");
        assert!(n.negative_markers.contains(&NegativeMarker::Reaction));
    }

    #[test]
    fn detects_instrumental() {
        let n = normalize_title("The Heart Pt. 2 Instrumental");
        assert!(n.negative_markers.contains(&NegativeMarker::Instrumental));
    }

    #[test]
    fn detects_remix() {
        let n = normalize_title("Look Out for Detox (remix)");
        assert!(n.negative_markers.contains(&NegativeMarker::Remix));
    }

    #[test]
    fn detects_compound_mix_tag() {
        let n = normalize_title("Look Out for Detox (oddlogic waowmix)");
        assert!(n.negative_markers.contains(&NegativeMarker::Remix));
    }

    #[test]
    fn does_not_flag_normal_title_as_remix() {
        let n = normalize_title("Look Out for Detox");
        assert!(!n.negative_markers.contains(&NegativeMarker::Remix));
    }

    #[test]
    fn detects_slowed() {
        let n = normalize_title("The Heart Pt. 2 (slowed + reverb)");
        assert!(n.negative_markers.contains(&NegativeMarker::SlowedReverb));
    }

    #[test]
    fn detects_chopped_not_slopped() {
        let n = normalize_title("Threatz (Chopped Not Slopped)");
        assert!(n
            .negative_markers
            .contains(&NegativeMarker::ChoppedNotSlopped));
    }

    #[test]
    fn base_title_strips_series() {
        let n = normalize_title("The Heart Part 2");
        assert_eq!(n.base_title, "the heart");
    }

    #[test]
    fn vol3_detected() {
        let n = normalize_title("Tha Carter Vol. 3");
        assert_eq!(
            n.series_marker,
            Some(SeriesMarker {
                kind: SeriesKind::Volume,
                value: 3
            })
        );
    }
}
