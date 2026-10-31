use super::{artwork, same_identity, ArtworkReference};
use crate::normalize::{normalize_title, NegativeMarker};
use anyhow::{bail, Result};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::{collections::HashSet, future::Future, sync::LazyLock, time::Duration};

/// A suggested release cover, without asserting authoritative recording identity.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SourceArtworkMatch {
    pub artwork: ArtworkReference,
    pub recording_id: String,
    pub release_title: String,
    pub version_labels_differ: bool,
}

#[derive(Deserialize)]
struct Search {
    #[serde(default)]
    count: Option<usize>,
    recordings: Vec<Recording>,
}

#[derive(Deserialize)]
struct Recording {
    id: String,
    title: String,
    length: Option<u64>,
    #[serde(rename = "artist-credit", default)]
    artists: Vec<Artist>,
    #[serde(default)]
    releases: Vec<Release>,
}

#[derive(Deserialize)]
struct Artist {
    name: String,
}

#[derive(Deserialize)]
struct Release {
    id: String,
    title: String,
    date: Option<String>,
    status: Option<String>,
    #[serde(rename = "release-group")]
    group: Option<Group>,
}

#[derive(Deserialize)]
struct Group {
    id: Option<String>,
    title: Option<String>,
    #[serde(rename = "primary-type")]
    primary: Option<String>,
    #[serde(rename = "secondary-types", default)]
    secondary: Vec<String>,
}

struct TitleEvidence {
    title: String,
    base: String,
    generic_mix: Option<String>,
    features: Vec<String>,
}

fn title_evidence(raw: &str) -> Option<TitleEvidence> {
    static PRESENTATION: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"(?i)[\(\[]\s*(?:official\s+(?:music\s+)?(?:video|audio)|music\s+video|lyrics?|lyric\s+video|visuali[sz]er)\s*[\)\]]").unwrap()
    });
    static BRACKETED_FEATURES: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"(?i)\(\s*(?:feat\.?|ft\.?|featuring)\s+([^()\[\]]+)\)|\[\s*(?:feat\.?|ft\.?|featuring)\s+([^()\[\]]+)\]").unwrap()
    });
    static FEATURES: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"(?i)\s+(?:feat\.?|ft\.?|featuring)\s+([^()\[\]]+)$").unwrap()
    });
    static FEATURE_SEPARATOR: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"(?i)\s*(?:,|&|;|\band\b)\s*").unwrap());
    static GENERIC_MIX: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"(?i)(?:[\(\[]\s*(remix|mix|weedmix)\s*[\)\]]|\s+(remix|mix|weedmix))\s*$")
            .unwrap()
    });
    if raw.len() > 1024 {
        return None;
    }
    let mut title = PRESENTATION.replace_all(raw, " ").trim().to_owned();
    let mut features = Vec::new();
    title = BRACKETED_FEATURES
        .replace_all(&title, |feature: &regex::Captures<'_>| {
            let names = feature.get(1).or_else(|| feature.get(2)).unwrap().as_str();
            features.extend(
                FEATURE_SEPARATOR
                    .split(names)
                    .map(str::trim)
                    .map(str::to_owned),
            );
            " "
        })
        .trim()
        .to_owned();
    if let Some(feature) = FEATURES.captures(&title) {
        features.extend(
            FEATURE_SEPARATOR
                .split(feature.get(1)?.as_str())
                .map(str::trim)
                .map(str::to_owned),
        );
        title.truncate(feature.get(0)?.start());
    }
    if features.len() > 16
        || features
            .iter()
            .any(|name| !name.chars().any(char::is_alphanumeric))
    {
        return None;
    }
    let mut base = title.clone();
    let generic_mix = GENERIC_MIX.captures(&title).and_then(|mix| {
        let label = mix.get(1).or_else(|| mix.get(2))?.as_str().to_lowercase();
        base.truncate(mix.get(0)?.start());
        Some(label)
    });
    if !base.chars().any(char::is_alphanumeric) {
        return None;
    }
    Some(TitleEvidence {
        title,
        base: base.trim().to_owned(),
        generic_mix,
        features,
    })
}

fn restricted_markers(title: &str) -> Vec<NegativeMarker> {
    normalize_title(title)
        .negative_markers
        .into_iter()
        .filter(|marker| {
            !matches!(
                marker,
                NegativeMarker::Remix
                    | NegativeMarker::Lyrics
                    | NegativeMarker::LyricVideo
                    | NegativeMarker::Visualizer
            )
        })
        .collect()
}

fn extra_version_words(title: &str) -> HashSet<String> {
    static EXTRA_VERSION: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r"(?i)\b(?:chopped|screwed|radio|edit|demo|rehearsal|extended|dub|alternate|version)\b",
        )
        .unwrap()
    });
    EXTRA_VERSION
        .find_iter(title)
        .map(|m| m.as_str().to_lowercase())
        .collect()
}

fn variants_compatible(source: &TitleEvidence, found: &TitleEvidence) -> bool {
    restricted_markers(&source.title) == restricted_markers(&found.title)
        && extra_version_words(&source.title) == extra_version_words(&found.title)
        && match (&source.generic_mix, &found.generic_mix) {
            (Some(left), Some(right)) => left == right,
            (None, Some(_)) => false,
            _ => true,
        }
}

fn release_version_conflicts(title: &str, source: &TitleEvidence) -> bool {
    if restricted_markers(title)
        .iter()
        .any(|marker| !restricted_markers(&source.title).contains(marker))
        || !extra_version_words(title).is_subset(&extra_version_words(&source.title))
    {
        return true;
    }
    if normalize_title(title)
        .negative_markers
        .contains(&NegativeMarker::Remix)
    {
        let same_mix = title_evidence(title).is_some_and(|release| {
            release.generic_mix.is_some() && release.generic_mix == source.generic_mix
        });
        return !same_mix && !same_identity(title, &source.title);
    }
    false
}

struct ReleaseMatch {
    release: Release,
    recording_id: String,
    labels_differ: bool,
}

fn eligible_matches(
    searches: Vec<Search>,
    artist: &str,
    title: &str,
    duration: Option<u64>,
    album: Option<&str>,
) -> Vec<ReleaseMatch> {
    let Some(source) = title_evidence(title) else {
        return Vec::new();
    };
    let mut matches = Vec::new();
    for recording in searches.into_iter().flat_map(|search| search.recordings) {
        let Some(found) = title_evidence(&recording.title) else {
            continue;
        };
        if !recording
            .artists
            .first()
            .is_some_and(|credit| same_identity(&credit.name, artist))
            || !same_identity(&source.base, &found.base)
            || !variants_compatible(&source, &found)
        {
            continue;
        }
        let mut found_features = found.features.clone();
        for credit in recording.artists.iter().skip(1) {
            if !found_features
                .iter()
                .any(|feature| same_identity(feature, &credit.name))
            {
                found_features.push(credit.name.clone());
            }
        }
        if source.features.len() != found_features.len()
            || !source.features.iter().all(|feature| {
                found_features
                    .iter()
                    .any(|found| same_identity(feature, found))
            })
        {
            continue;
        }
        let labels_differ = !same_identity(&source.title, &found.title);
        match (
            duration.filter(|ms| *ms > 0),
            recording.length.filter(|ms| *ms > 0),
        ) {
            (Some(source_ms), Some(catalog_ms)) => {
                let tolerance = if labels_differ {
                    (source_ms / 100).clamp(3_000, 5_000)
                } else {
                    (source_ms.saturating_mul(3) / 100).clamp(3_000, 10_000)
                };
                if source_ms.abs_diff(catalog_ms) > tolerance {
                    continue;
                }
            }
            _ if labels_differ => continue,
            _ => {}
        }
        for release in recording.releases {
            let eligible_group = release.group.as_ref().is_some_and(|group| {
                matches!(group.primary.as_deref(), Some("Album" | "Single" | "EP"))
                    && group.secondary.iter().all(|kind| kind == "Mixtape/Street")
            });
            let matches_album =
                album
                    .filter(|album| !album.trim().is_empty())
                    .is_none_or(|album| {
                        same_identity(album, &release.title)
                            || release
                                .group
                                .as_ref()
                                .and_then(|group| group.title.as_deref())
                                .is_some_and(|title| same_identity(album, title))
                    });
            if release.status.as_deref() != Some("Official")
                || !eligible_group
                || !matches_album
                || release_version_conflicts(&release.title, &source)
            {
                continue;
            }
            matches.push(ReleaseMatch {
                release,
                recording_id: recording.id.clone(),
                labels_differ,
            });
        }
    }
    matches.sort_by(|left, right| {
        let key = |candidate: &ReleaseMatch| {
            (
                candidate.labels_differ,
                match candidate
                    .release
                    .group
                    .as_ref()
                    .and_then(|group| group.primary.as_deref())
                {
                    Some("Album") => 0,
                    Some("Single") => 1,
                    _ => 2,
                },
            )
        };
        key(left)
            .cmp(&key(right))
            .then_with(|| {
                left.release
                    .date
                    .as_deref()
                    .unwrap_or("9999")
                    .cmp(right.release.date.as_deref().unwrap_or("9999"))
            })
            .then_with(|| left.release.id.cmp(&right.release.id))
            .then_with(|| left.recording_id.cmp(&right.recording_id))
    });
    if let Some(best) = matches.first().map(|candidate| candidate.labels_differ) {
        matches.retain(|candidate| candidate.labels_differ == best);
    }
    let albums: HashSet<_> = matches
        .iter()
        .map(|candidate| {
            candidate
                .release
                .group
                .as_ref()
                .and_then(|group| group.id.clone())
                .unwrap_or_else(|| {
                    candidate
                        .release
                        .title
                        .to_lowercase()
                        .chars()
                        .filter(|c| c.is_alphanumeric())
                        .collect()
                })
        })
        .collect();
    if albums.len() > 1 {
        return Vec::new();
    }
    let mut seen = HashSet::new();
    matches.retain(|candidate| seen.insert(candidate.release.id.clone()));
    matches
}

async fn first_cover<F, Fut>(
    matches: Vec<ReleaseMatch>,
    mut lookup: F,
) -> Result<Option<SourceArtworkMatch>>
where
    F: FnMut(&Release) -> Fut,
    Fut: Future<Output = Result<Option<ArtworkReference>>>,
{
    for candidate in matches.into_iter().take(8) {
        if let Some(artwork) = lookup(&candidate.release).await? {
            return Ok(Some(SourceArtworkMatch {
                artwork,
                recording_id: candidate.recording_id,
                release_title: candidate.release.title,
                version_labels_differ: candidate.labels_differ,
            }));
        }
    }
    Ok(None)
}

/// Artwork-only lookup. Never use this suggestion to change recording tags or scoring identity.
pub async fn resolve_source_artwork(
    artist: &str,
    title: &str,
    source_duration_ms: Option<u64>,
    album: Option<&str>,
) -> Result<Option<SourceArtworkMatch>> {
    let Some(source) = title_evidence(title) else {
        return Ok(None);
    };
    if artist.trim().is_empty() {
        return Ok(None);
    }
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()?;
    let mut titles = vec![source.title.clone()];
    if !same_identity(&source.title, &source.base) {
        titles.push(source.base);
    }
    let mut searches = Vec::new();
    for title in titles.into_iter().take(2) {
        // Metadata preparation has just consulted MusicBrainz; space the extra searches too.
        tokio::time::sleep(Duration::from_millis(1_100)).await;
        let escape = |value: &str| value.replace('\\', "\\\\").replace('"', "\\\"");
        let query = format!(
            "artist:\"{}\" AND recording:\"{}\"",
            escape(artist),
            escape(&title)
        );
        let url = format!(
            "https://musicbrainz.org/ws/2/recording/?query={}&fmt=json&limit=100",
            urlencoding::encode(&query)
        );
        let response = client
            .get(url)
            .header(
                "User-Agent",
                concat!(
                    "Needle/",
                    env!("CARGO_PKG_VERSION"),
                    " (source artwork review)"
                ),
            )
            .send()
            .await?
            .error_for_status()?;
        let search: Search = response.json().await?;
        if search
            .count
            .is_some_and(|count| count > search.recordings.len())
        {
            bail!("Cover search returned too many possible recordings to compare safely");
        }
        searches.push(search);
    }
    first_cover(
        eligible_matches(searches, artist, title, source_duration_ms, album),
        |release| {
            let client = client.clone();
            let id = release.id.clone();
            let group = release.group.as_ref().and_then(|group| group.id.clone());
            async move { artwork::resolve_release_artwork(client, &id, group.as_deref()).await }
        },
    )
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    };

    fn release(id: &str, group: &str, title: &str, date: &str) -> Value {
        json!({"id":id,"title":title,"status":"Official","date":date,"release-group":{"id":group,"primary-type":"Album","secondary-types":["Mixtape/Street"]}})
    }
    fn recording(title: &str, artist: &str, duration: Option<u64>, releases: Vec<Value>) -> Value {
        json!({"id":format!("rec-{title}"),"title":title,"length":duration,"artist-credit":[{"name":artist}],"releases":releases})
    }
    fn search(recordings: Vec<Value>) -> Search {
        serde_json::from_value(json!({"recordings":recordings})).unwrap()
    }
    fn candidates(title: &str, artist: &str, duration: Option<u64>) -> Vec<ReleaseMatch> {
        eligible_matches(
            vec![search(vec![recording(
                title,
                artist,
                duration,
                vec![release("cover", "group", "Album", "2014")],
            )])],
            "Artist",
            "Song (Weedmix)",
            Some(251_000),
            None,
        )
    }
    fn maan() -> Search {
        serde_json::from_str(include_str!(
            "../../../../tests/fixtures/metadata/artwork-maan.json"
        ))
        .unwrap()
    }

    fn six_sixteen() -> Search {
        serde_json::from_str(include_str!(
            "../../../../tests/fixtures/metadata/artwork-616.json"
        ))
        .unwrap()
    }

    #[test]
    fn six_sixteen_exact_title_supplies_original_single_cover() {
        let matches = eligible_matches(
            vec![six_sixteen()],
            "Kendrick Lamar",
            "6:16 in LA",
            Some(218_000),
            None,
        );
        assert_eq!(
            matches
                .iter()
                .map(|candidate| (
                    candidate.recording_id.as_str(),
                    candidate.release.id.as_str(),
                    candidate.labels_differ
                ))
                .collect::<Vec<_>>(),
            vec![(
                "88b816c6-3dd2-4fe5-8c53-a40aef20b9c6",
                "1dd02b5d-79bf-47ad-8b34-50cd71c251da",
                false
            )]
        );
    }

    #[test]
    fn six_sixteen_bootlegs_and_live_guest_never_supply_cover() {
        for duration in [None, Some(153_000), Some(218_000)] {
            let mut catalog = six_sixteen();
            catalog
                .recordings
                .retain(|recording| recording.id != "88b816c6-3dd2-4fe5-8c53-a40aef20b9c6");
            assert!(eligible_matches(
                vec![catalog],
                "Kendrick Lamar",
                "6:16 in LA",
                duration,
                None,
            )
            .is_empty());
        }
    }

    #[test]
    fn exact_title_duration_tolerance_is_three_percent_with_floor_and_cap() {
        for (source_ms, catalog_ms, accepted) in [
            (50_000, 53_000, true),
            (50_000, 53_001, false),
            (200_000, 206_000, true),
            (200_000, 206_001, false),
            (200_000, 194_000, true),
            (200_000, 193_999, false),
            (900_000, 910_000, true),
            (900_000, 910_001, false),
        ] {
            let matches = eligible_matches(
                vec![search(vec![recording(
                    "Song",
                    "Artist",
                    Some(catalog_ms),
                    vec![release("cover", "group", "Album", "2014")],
                )])],
                "Artist",
                "Song [Official Audio]",
                Some(source_ms),
                None,
            );
            assert_eq!(
                !matches.is_empty(),
                accepted,
                "source {source_ms}, catalog {catalog_ms}"
            );
        }
    }

    #[test]
    fn probable_cover_is_available_when_catalog_omits_generic_mix_label() {
        let matches = candidates("Song", "Artist", Some(250_000));
        assert_eq!(matches.len(), 1);
        assert!(matches[0].labels_differ);
    }
    #[test]
    fn maan_orphan_exact_recording_does_not_hide_original_album_editions() {
        let matches = eligible_matches(
            vec![maan()],
            "Wiz Khalifa",
            "MAAN! (Weedmix)",
            Some(251_000),
            None,
        );
        assert_eq!(matches.len(), 2);
        assert_eq!(
            matches[0].release.id,
            "c105161b-4008-41a6-8f9e-431da55156a6"
        );
        assert_eq!(matches[0].release.title, "28 Grams");
        assert!(matches.iter().all(|candidate| candidate.labels_differ));
    }
    #[test]
    fn mismatched_artist_variant_title_and_duration_never_supply_a_cover() {
        for (title, artist, duration) in [
            ("Song", "Other Artist", Some(250_000)),
            ("Songs", "Artist", Some(250_000)),
            ("Song Part 2", "Artist", Some(250_000)),
            ("Song (Snakehips Remix)", "Artist", Some(250_000)),
            ("Song (Othermix)", "Artist", Some(250_000)),
            ("Song (Live)", "Artist", Some(250_000)),
            ("Song (Acoustic)", "Artist", Some(250_000)),
            ("Song (Instrumental)", "Artist", Some(250_000)),
            ("Song (Clean)", "Artist", Some(250_000)),
            ("Song (Chopped)", "Artist", Some(250_000)),
            ("Song", "Artist", Some(258_000)),
            ("Song", "Artist", None),
        ] {
            assert!(
                candidates(title, artist, duration).is_empty(),
                "accepted {title}/{artist}/{duration:?}"
            );
        }
    }
    #[test]
    fn source_named_remixer_and_hard_versions_are_never_discarded() {
        for source in [
            "Song (Snakehips Remix)",
            "Song (SkrillexRemix)",
            "Song (DJPremierRemix)",
            "Song (Live)",
            "Song (Acoustic)",
            "Song (Instrumental)",
            "Song (Clean)",
            "Song (Chopped)",
            "Song Part 5",
        ] {
            assert!(
                eligible_matches(
                    vec![search(vec![recording(
                        "Song",
                        "Artist",
                        Some(250_000),
                        vec![release("cover", "group", "Album", "2014")]
                    )])],
                    "Artist",
                    source,
                    Some(251_000),
                    None
                )
                .is_empty(),
                "accepted {source}"
            );
        }
    }
    #[test]
    fn soft_matches_require_source_duration_with_tight_capped_tolerance() {
        for duration in [None, Some(0)] {
            assert!(eligible_matches(
                vec![maan()],
                "Wiz Khalifa",
                "MAAN (Weedmix)",
                duration,
                None
            )
            .is_empty());
        }
        assert_eq!(candidates("Song", "Artist", Some(248_000)).len(), 1);
        assert!(candidates("Song", "Artist", Some(247_999)).is_empty());
        for (source_ms, catalog_ms, accepted) in [
            (400_000, 404_000, true),
            (400_000, 404_001, false),
            (900_000, 905_000, true),
            (900_000, 905_001, false),
        ] {
            let got = eligible_matches(
                vec![search(vec![recording(
                    "Song",
                    "Artist",
                    Some(catalog_ms),
                    vec![release("cover", "group", "Album", "2014")],
                )])],
                "Artist",
                "Song (Remix)",
                Some(source_ms),
                None,
            );
            assert_eq!(!got.is_empty(), accepted);
        }
    }
    #[test]
    fn different_albums_are_ambiguous_but_recording_duplicates_and_editions_are_not() {
        let recordings = |other_group| {
            vec![
                recording(
                    "Song",
                    "Artist",
                    Some(250_000),
                    vec![release("original", "group", "Album", "2014")],
                ),
                recording(
                    "Song",
                    "Artist",
                    Some(249_500),
                    vec![release("edition", other_group, "Album (Deluxe)", "2015")],
                ),
            ]
        };
        assert_eq!(
            eligible_matches(
                vec![search(recordings("group"))],
                "Artist",
                "Song (Remix)",
                Some(251_000),
                None
            )
            .len(),
            2
        );
        assert!(eligible_matches(
            vec![search(recordings("other"))],
            "Artist",
            "Song (Remix)",
            Some(251_000),
            None
        )
        .is_empty());
    }
    #[test]
    fn catalog_release_cannot_introduce_a_conflicting_version() {
        for album in [
            "Album (Live)",
            "Album (Chopped)",
            "Album (Instrumental)",
            "Album (Clean)",
            "Album (Skrillex Remix)",
        ] {
            let matches = eligible_matches(
                vec![search(vec![recording(
                    "Song",
                    "Artist",
                    Some(250_000),
                    vec![release("cover", "group", album, "2014")],
                )])],
                "Artist",
                "Song (Weedmix)",
                Some(251_000),
                None,
            );
            assert!(matches.is_empty(), "accepted {album}");
        }
    }
    #[test]
    fn known_album_constrains_the_suggested_cover() {
        let fixture = || {
            search(vec![recording(
                "Song",
                "Artist",
                Some(250_000),
                vec![release("cover", "group", "Album", "2014")],
            )])
        };
        assert!(eligible_matches(
            vec![fixture()],
            "Artist",
            "Song (Remix)",
            Some(251_000),
            Some("Other Album")
        )
        .is_empty());
        assert_eq!(
            eligible_matches(
                vec![fixture()],
                "Artist",
                "Song (Remix)",
                Some(251_000),
                Some("ALBUM")
            )
            .len(),
            1
        );
    }
    #[test]
    fn presentation_and_feature_formatting_do_not_change_recording_evidence() {
        let mut rec = recording(
            "Song",
            "ARTIST",
            Some(250_000),
            vec![release("cover", "group", "Album", "2014")],
        );
        rec["artist-credit"] = json!([{"name":"ARTIST"},{"name":"Guest"}]);
        for title in [
            "Song (Weedmix) (feat. Guest) [Official Video]",
            "Song (feat. Guest) (Weedmix) [Official Video]",
            "Song [ft. Guest] (Weedmix)",
            "Song (Weedmix) [featuring Guest]",
        ] {
            assert_eq!(
                eligible_matches(
                    vec![search(vec![rec.clone()])],
                    "Artist",
                    title,
                    Some(251_000),
                    None
                )
                .len(),
                1,
                "failed {title}"
            );
        }
    }
    #[test]
    fn feature_clauses_do_not_hide_live_named_remix_or_part_conflicts() {
        let mut rec = recording(
            "Song",
            "Artist",
            Some(250_000),
            vec![release("cover", "group", "Album", "2014")],
        );
        rec["artist-credit"] = json!([{"name":"Artist"},{"name":"Guest"}]);
        for title in [
            "Song (feat. Guest) (Live)",
            "Song (Live) (feat. Guest)",
            "Song (feat. Guest) (Snakehips Remix)",
            "Song (Snakehips Remix) (feat. Guest)",
            "Song (feat. Guest) (SkrillexRemix)",
            "Song (SkrillexRemix) (feat. Guest)",
            "Song Part 2 (feat. Guest) (Weedmix)",
            "Song Part 2 (Weedmix) (feat. Guest)",
        ] {
            assert!(
                eligible_matches(
                    vec![search(vec![rec.clone()])],
                    "Artist",
                    title,
                    Some(251_000),
                    None
                )
                .is_empty(),
                "accepted {title}"
            );
        }
    }

    #[tokio::test]
    async fn definitive_missing_cover_continues_but_transient_error_stops() {
        let matches = || {
            eligible_matches(
                vec![maan()],
                "Wiz Khalifa",
                "MAAN (Weedmix)",
                Some(251_000),
                None,
            )
        };
        let count = Arc::new(AtomicUsize::new(0));
        let requests = count.clone();
        let found = first_cover(matches(), move |release| {
            let index = requests.fetch_add(1, Ordering::SeqCst);
            let id = release.id.clone();
            async move {
                Ok((index > 0).then_some(ArtworkReference {
                    url: "https://archive.org/front.jpg".into(),
                    provider: "cover_art_archive".into(),
                    release_id: Some(id),
                    release_group_id: None,
                }))
            }
        })
        .await
        .unwrap()
        .unwrap();
        assert_eq!(count.load(Ordering::SeqCst), 2);
        assert_eq!(
            found.artwork.release_id.as_deref(),
            Some("834a8ae9-4c35-4945-825f-1776b23f7fcb")
        );
        assert_eq!(found.release_title, "28 Grams (Trap Wiz)");
        let count = Arc::new(AtomicUsize::new(0));
        let requests = count.clone();
        assert!(first_cover(matches(), move |_| {
            requests.fetch_add(1, Ordering::SeqCst);
            async { bail!("HTTP 503") }
        })
        .await
        .is_err());
        assert_eq!(count.load(Ordering::SeqCst), 1);
    }
}
