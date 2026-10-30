use super::{artwork, ArtworkReference};
use crate::normalize::{normalize_title, NegativeMarker};
use anyhow::Result;
use regex::Regex;
use serde::Deserialize;
use std::{collections::HashSet, future::Future, sync::LazyLock};
use unicode_normalization::UnicodeNormalization;

/// Compare full catalog identities without discarding remix/version qualifiers.
pub fn same_identity(left: &str, right: &str) -> bool {
    fn normalized(value: &str) -> String {
        value
            .nfkc()
            .flat_map(char::to_lowercase)
            .filter(|c| c.is_alphanumeric())
            .collect()
    }
    let left = normalized(left);
    !left.is_empty() && left == normalized(right)
}

#[derive(Deserialize)]
struct Search {
    recordings: Vec<Recording>,
}
#[derive(Deserialize)]
struct Recording {
    title: String,
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
    #[serde(rename = "primary-type")]
    primary: Option<String>,
    #[serde(rename = "secondary-types", default)]
    secondary: Vec<String>,
}

struct RecordingIdentity {
    title: String,
    features: Vec<String>,
}

fn recording_identity(title: &str) -> Option<RecordingIdentity> {
    static BRACKETED: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"(?i)\(\s*(?:feat\.?|ft\.?|featuring)\s+([^()\[\]]+)\)|\[\s*(?:feat\.?|ft\.?|featuring)\s+([^()\[\]]+)\]").unwrap()
    });
    static TRAILING: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"(?i)\s+(?:feat\.?|ft\.?|featuring)\s+([^()\[\]]+)$").unwrap()
    });
    static FEATURE_MARKER: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"(?i)\b(?:feat|ft|featuring)\b").unwrap());

    if title.len() > 1024 {
        return None;
    }
    let mut identity = RecordingIdentity {
        title: String::new(),
        features: Vec::new(),
    };
    let mut offset = 0;
    for clause in BRACKETED.captures_iter(title) {
        let full = clause.get(0)?;
        identity.title.push_str(&title[offset..full.start()]);
        identity.title.push(' ');
        add_features(
            &mut identity.features,
            clause.get(1).or_else(|| clause.get(2))?.as_str(),
        )?;
        offset = full.end();
    }
    identity.title.push_str(&title[offset..]);
    if let Some(clause) = TRAILING.captures(&identity.title) {
        add_features(&mut identity.features, clause.get(1)?.as_str())?;
        identity.title.truncate(clause.get(0)?.start());
    }
    identity.title = identity.title.trim().to_owned();
    if identity.title.is_empty() || FEATURE_MARKER.is_match(&identity.title) {
        return None;
    }
    Some(identity)
}

fn add_features(features: &mut Vec<String>, names: &str) -> Option<()> {
    static SEPARATOR: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"(?i)\s*(?:,|&|;|\band\b)\s*").unwrap());
    for name in SEPARATOR.split(names) {
        let name = name.trim();
        if !name.chars().any(char::is_alphanumeric) {
            return None;
        }
        if !features.iter().any(|feature| same_identity(feature, name)) {
            features.push(name.to_owned());
        }
        if features.len() > 16 {
            return None;
        }
    }
    Some(())
}

fn recording_matches(recording: &Recording, artist: &str, requested: &RecordingIdentity) -> bool {
    let Some(mut found) = recording_identity(&recording.title) else {
        return false;
    };
    if recording.artists.is_empty()
        || recording.artists.len() > 17
        || !same_identity(&recording.artists[0].name, artist)
        || !same_identity(&found.title, &requested.title)
    {
        return false;
    }
    for credit in recording.artists.iter().skip(1) {
        if !credit.name.chars().any(char::is_alphanumeric) {
            return false;
        }
        if !found
            .features
            .iter()
            .any(|feature| same_identity(feature, &credit.name))
        {
            found.features.push(credit.name.clone());
        }
    }
    found.features.len() == requested.features.len()
        && found.features.iter().all(|feature| {
            requested
                .features
                .iter()
                .any(|wanted| same_identity(feature, wanted))
        })
}

fn introduces_version(release_title: &str, requested_title: &str) -> bool {
    let requested = normalize_title(requested_title);
    let released = normalize_title(release_title);
    let derivative = released.negative_markers.iter().any(|marker| {
        !matches!(
            marker,
            NegativeMarker::Lyrics | NegativeMarker::LyricVideo | NegativeMarker::Visualizer
        ) && !requested.negative_markers.contains(marker)
    });
    static EDITION: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r"(?i)\b(?:deluxe|expanded|anniversary|reissue|reissued|reloaded|bonus|edition)\b",
        )
        .unwrap()
    });
    derivative
        || EDITION.find_iter(release_title).any(|marker| {
            !EDITION
                .find_iter(requested_title)
                .any(|requested| requested.as_str().eq_ignore_ascii_case(marker.as_str()))
        })
}

fn eligible_releases(search: Search, artist: &str, title: &str, album: &str) -> Vec<Release> {
    let Some(requested) = recording_identity(title) else {
        return Vec::new();
    };
    let mut releases: Vec<_> = search
        .recordings
        .into_iter()
        .filter(|recording| recording_matches(recording, artist, &requested))
        .flat_map(|recording| recording.releases)
        .filter(|release| release.status.as_deref() == Some("Official"))
        .filter(|release| {
            if !album.trim().is_empty() {
                same_identity(&release.title, album)
            } else {
                !introduces_version(&release.title, &requested.title)
                    && release.group.as_ref().is_some_and(|group| {
                        group.secondary.iter().all(|kind| kind == "Mixtape/Street")
                            && matches!(group.primary.as_deref(), Some("Album" | "Single" | "EP"))
                    })
            }
        })
        .collect();
    releases.sort_by(|a, b| {
        let rank = |release: &Release| match release
            .group
            .as_ref()
            .and_then(|group| group.primary.as_deref())
        {
            Some("Album") => 0,
            Some("Single") => 1,
            _ => 2,
        };
        (rank(a), a.date.as_deref().unwrap_or("9999"), &a.id).cmp(&(
            rank(b),
            b.date.as_deref().unwrap_or("9999"),
            &b.id,
        ))
    });
    let mut seen = HashSet::new();
    releases.retain(|release| seen.insert(release.id.clone()));
    releases
}

async fn first_release_artwork<F, Fut>(
    releases: Vec<Release>,
    mut lookup: F,
) -> Result<Option<ArtworkReference>>
where
    F: FnMut(Release) -> Fut,
    Fut: Future<Output = Result<Option<ArtworkReference>>>,
{
    // Bound retries across editions; only a definitive missing cover permits the next lookup.
    for release in releases.into_iter().take(8) {
        if let Some(artwork) = lookup(release).await? {
            return Ok(Some(artwork));
        }
    }
    Ok(None)
}

/// Resolve only verified recording releases; never substitute a release-group cover.
pub async fn resolve_artwork(
    artist: &str,
    title: &str,
    album: &str,
) -> Result<Option<ArtworkReference>> {
    let Some(requested) = recording_identity(title) else {
        return Ok(None);
    };
    if artist.trim().is_empty() {
        return Ok(None);
    }
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .build()?;
    let escape = |s: &str| s.replace('\\', "\\\\").replace('"', "\\\"");
    let mut query = format!(
        "artist:\"{}\" AND recording:\"{}\"",
        escape(artist),
        escape(&requested.title)
    );
    if !album.trim().is_empty() {
        query.push_str(&format!(" AND release:\"{}\"", escape(album)));
    }
    let search: Search = client
        .get(format!(
            "https://musicbrainz.org/ws/2/recording/?query={}&fmt=json&limit=100",
            urlencoding::encode(&query)
        ))
        .header("User-Agent", "needle/0.1.0 (strict artwork resolver)")
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;
    first_release_artwork(eligible_releases(search, artist, title, album), |release| {
        let client = client.clone();
        async move {
            artwork::resolve_release_artwork(
                client,
                &release.id,
                release.group.as_ref().and_then(|group| group.id.as_deref()),
            )
            .await
        }
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> Search {
        serde_json::from_str(r#"{"recordings":[{"title":"Song (Remix)","artist-credit":[{"name":"Artist"}],"releases":[{"id":"comp","title":"Hits","status":"Official","release-group":{"primary-type":"Album","secondary-types":["Compilation"]}},{"id":"single","title":"Song (Remix)","status":"Official","release-group":{"primary-type":"Single"}},{"id":"album","title":"The Album","status":"Official","release-group":{"primary-type":"Album"}}]}]}"#).unwrap()
    }
    #[test]
    fn exact_album_hint_wins_over_single() {
        assert_eq!(
            eligible_releases(fixture(), "artist", "Song (Remix)", "The Album")
                .first()
                .unwrap()
                .id,
            "album"
        );
    }
    #[test]
    fn mismatches_stay_missing() {
        assert!(eligible_releases(fixture(), "Artist", "Song", "").is_empty());
        assert!(eligible_releases(fixture(), "Other Artist", "Song (Remix)", "").is_empty());
        assert!(eligible_releases(fixture(), "Artist", "Song (Remix)", "Other Album").is_empty());
    }
    #[test]
    fn blank_album_uses_deterministic_noncompilation() {
        assert_eq!(
            eligible_releases(fixture(), "Artist", "Song (Remix)", "")
                .first()
                .unwrap()
                .id,
            "album"
        );
    }
    #[test]
    fn unicode_case_punctuation_but_full_version() {
        assert!(same_identity(
            "Beyoncé — Café",
            "BEYONCE\u{301} CAFE\u{301}"
        ));
        assert!(!same_identity("Song (Live)", "Song"));
        assert!(!same_identity("Song Part 2", "Song Part 5"));
    }

    fn recording(title: &str, artists: &[&str], releases: serde_json::Value) -> Search {
        serde_json::from_value(serde_json::json!({"recordings": [{
            "title": title,
            "artist-credit": artists.iter().map(|name| serde_json::json!({"name": name})).collect::<Vec<_>>(),
            "releases": releases,
        }]})).unwrap()
    }

    fn official_release(id: &str, title: &str, secondary: &[&str]) -> serde_json::Value {
        serde_json::json!({
            "id": id, "title": title, "status": "Official",
            "release-group": {"primary-type": "Album", "secondary-types": secondary},
        })
    }

    #[test]
    fn official_mixtape_can_supply_its_original_cover() {
        let search = recording(
            "Free the Robots",
            &["Capital STEEZ"],
            serde_json::json!([official_release(
                "original",
                "AmeriKKKan Korruption",
                &["Mixtape/Street"]
            )]),
        );
        assert!(!eligible_releases(search, "Capital STEEZ", "Free the Robots", "").is_empty());
    }

    #[test]
    fn explicit_features_can_be_stored_as_separate_catalog_credits() {
        let search = recording(
            "Song (Named Remix)",
            &["Artist", "Guest"],
            serde_json::json!([official_release("album", "Album", &[])]),
        );
        assert!(
            !eligible_releases(search, "Artist", "Song (Named Remix) (feat. Guest)", "").is_empty()
        );
    }

    #[test]
    fn feature_spelling_can_differ_without_losing_version_identity() {
        let search = recording(
            "Song [featuring Guest] (Named Remix)",
            &["Artist"],
            serde_json::json!([official_release("album", "Album", &[])]),
        );
        assert!(
            !eligible_releases(search, "Artist", "Song (Named Remix) (ft. Guest)", "").is_empty()
        );
    }

    #[test]
    fn unknown_album_cannot_introduce_a_remastered_edition() {
        let search = recording(
            "Free the Robots",
            &["Capital STEEZ"],
            serde_json::json!([official_release(
                "remastered",
                "AmeriKKKan Korruption (Remastered & Reloaded)",
                &[]
            )]),
        );
        assert!(eligible_releases(search, "Capital STEEZ", "Free the Robots", "").is_empty());
    }

    #[test]
    fn features_match_as_a_set_across_title_and_credits() {
        let search = recording(
            "Song (feat. Guest B & Guest A)",
            &["Artist", "Guest A", "Guest B"],
            serde_json::json!([official_release("album", "Album", &[])]),
        );
        assert!(
            !eligible_releases(search, "Artist", "Song featuring Guest A, Guest B", "").is_empty()
        );
    }

    #[test]
    fn extra_missing_or_wrong_features_and_primary_artists_stay_missing() {
        for (catalog_title, credits, wanted) in [
            ("Song", vec!["Artist"], "Song (feat. Guest)"),
            ("Song", vec!["Artist", "Guest"], "Song"),
            ("Song", vec!["Artist", "Other"], "Song (feat. Guest)"),
            (
                "Song",
                vec!["Artist", "Guest", "Other"],
                "Song (feat. Guest)",
            ),
            (
                "Song (feat. Guest & Other)",
                vec!["Artist"],
                "Song (feat. Guest)",
            ),
            ("Song", vec!["Guest", "Artist"], "Song (feat. Guest)"),
            ("Song", vec!["Artist & Guest"], "Song (feat. Guest)"),
            ("Song (Live)", vec!["Artist", "Guest"], "Song (feat. Guest)"),
            (
                "Song (Other Remix)",
                vec!["Artist", "Guest"],
                "Song (Named Remix) (feat. Guest)",
            ),
        ] {
            let search = recording(
                catalog_title,
                &credits,
                serde_json::json!([official_release("album", "Album", &[])]),
            );
            assert!(
                eligible_releases(search, "Artist", wanted, "").is_empty(),
                "{catalog_title}, {credits:?}, {wanted}"
            );
        }
    }

    #[test]
    fn only_explicit_well_formed_feature_clauses_are_removed() {
        let identity =
            recording_identity("Song (Named Remix) [ft. Guest] (Live at Venue)").unwrap();
        assert!(same_identity(
            &identity.title,
            "Song (Named Remix) (Live at Venue)"
        ));
        assert_eq!(identity.features, ["Guest"]);
        for malformed in [
            "Song (feat.)",
            "Song (feat. Guest]",
            "Song (feat. Guest",
            "Song feat. Guest &",
        ] {
            assert!(recording_identity(malformed).is_none(), "{malformed}");
        }
        assert!(recording_identity(&"a".repeat(1025)).is_none());
        let too_many = (0..17)
            .map(|n| format!("Guest {n}"))
            .collect::<Vec<_>>()
            .join(", ");
        assert!(recording_identity(&format!("Song (feat. {too_many})")).is_none());
    }

    #[test]
    fn blank_album_filters_derivative_editions_and_unsafe_secondary_types() {
        for name in [
            "Album (Live)",
            "Album (Acoustic)",
            "Album (Clean)",
            "Album (Radio Edit)",
            "Album (Chopped Not Slopped)",
            "Album (Deluxe)",
            "Album (Expanded)",
            "Album (10th Anniversary)",
            "Album Reloaded",
            "Album (Reissue)",
        ] {
            let search = recording(
                "Song",
                &["Artist"],
                serde_json::json!([official_release("edition", name, &[])]),
            );
            assert!(
                eligible_releases(search, "Artist", "Song", "").is_empty(),
                "{name}"
            );
        }
        for kind in ["Compilation", "Live", "Remix", "Soundtrack", "Demo"] {
            let search = recording(
                "Song",
                &["Artist"],
                serde_json::json!([official_release(
                    "edition",
                    "Album",
                    &["Mixtape/Street", kind]
                )]),
            );
            assert!(
                eligible_releases(search, "Artist", "Song", "").is_empty(),
                "{kind}"
            );
        }
        assert!(!introduces_version("Album (Lyric Video)", "Song"));
        assert!(!introduces_version("Album Remastered", "Song (Remastered)"));
    }

    #[test]
    fn explicit_album_keeps_its_full_edition_and_official_status_requirement() {
        let releases = serde_json::json!([
            official_release("original", "Album", &[]),
            official_release("remaster", "Album (Remastered)", &[]),
            {"id": "bootleg", "title": "Album (Remastered)", "status": "Bootleg"},
            {"id": "unknown", "title": "Album (Remastered)"},
        ]);
        let found = eligible_releases(
            recording("Song", &["Artist"], releases),
            "Artist",
            "Song",
            "Album (Remastered)",
        );
        assert_eq!(
            found
                .iter()
                .map(|release| release.id.as_str())
                .collect::<Vec<_>>(),
            ["remaster"]
        );
    }

    fn editions() -> Vec<Release> {
        let mut newer = official_release("newer", "Album", &[]);
        newer["date"] = "2012-01-01".into();
        let mut older = official_release("older", "Album", &[]);
        older["date"] = "2010-01-01".into();
        eligible_releases(
            recording(
                "Song",
                &["Artist"],
                serde_json::json!([
                    newer,
                    older,
                    official_release("older", "Album", &[]),
                    official_release("other-album", "Other Album", &[]),
                    official_release("remastered", "Album (Remastered)", &[]),
                ]),
            ),
            "Artist",
            "Song",
            "Album",
        )
    }

    fn cover(id: &str) -> ArtworkReference {
        ArtworkReference {
            url: format!("https://coverartarchive.org/release/{id}/front"),
            provider: "cover_art_archive".into(),
            release_id: Some(id.into()),
            release_group_id: None,
        }
    }

    #[tokio::test]
    async fn missing_cover_tries_the_next_ordered_exact_album_edition_once() {
        let mut visited = Vec::new();
        let result = first_release_artwork(editions(), |release| {
            visited.push(release.id.clone());
            std::future::ready(Ok((release.id == "newer").then(|| cover(&release.id))))
        })
        .await
        .unwrap()
        .unwrap();
        assert_eq!(visited, ["older", "newer"]);
        assert_eq!(result.release_id.as_deref(), Some("newer"));
    }

    #[tokio::test]
    async fn transient_cover_error_never_falls_through_to_a_different_edition() {
        let mut visited = Vec::new();
        let result = first_release_artwork(editions(), |release| {
            visited.push(release.id.clone());
            std::future::ready(Err(anyhow::anyhow!("CAA temporary failure")))
        })
        .await;
        assert!(result.is_err());
        assert_eq!(visited, ["older"]);
    }

    #[tokio::test]
    async fn edition_lookups_are_bounded_and_do_not_try_a_release_group() {
        let releases = (0..10)
            .map(|n| official_release(&format!("release-{n:02}"), "Album", &[]))
            .collect::<Vec<_>>();
        let search = recording("Song", &["Artist"], serde_json::json!(releases));
        let mut visited = Vec::new();
        let result = first_release_artwork(
            eligible_releases(search, "Artist", "Song", "Album"),
            |release| {
                visited.push(release.id);
                std::future::ready(Ok(None))
            },
        )
        .await
        .unwrap();
        assert!(result.is_none());
        assert_eq!(
            visited,
            (0..8)
                .map(|n| format!("release-{n:02}"))
                .collect::<Vec<_>>()
        );
    }
}
