# Changelog

User-visible changes are collected here for each release. GitHub is the planned sharing and release channel for reviewed source snapshots; Forgejo remains the everyday development remote.

## 0.2.1 — Draft preview

### Fixed

- Explicit remix requests retain their recording identity when the metadata resolver returns the base album track.
- Packaged apps now locate their bundled Sparkle framework after being copied to Applications, fixing a launch failure caused by a missing framework runtime search path.

### Verification and availability

- Verified the canonical Whethan SoundCloud recording's source quality display (160 kbps and approximately 2 million provider-reported plays) and in-app preview playback progress. These provider values may change.
- Restarted the save test and verified correctly named remix tags, actual membership in the Needle Spotify playlist, and local playback.
- This is still an unsigned draft for review. Production sharing requires signing, notarization, compatibility validation, and bundled-tool corresponding sources/notices. In-app updates remain disabled in unsigned previews.
- The existing 0.2.0 source tag remains unchanged; the packaging fix is delivered under a new version.

## 0.2.0 — Draft preview

This release is in preparation. The first shared package is planned for Apple Silicon Macs with macOS 15 or later, pending compatibility validation. The current local review package requires macOS 27 because its bundled FFmpeg targets macOS 27; it is not the planned broadly shared artifact. Signing, notarization, and bundled-tool redistribution checks must be completed before a production release is described as ready for friends.

### Added

- Native macOS app with Add Music, Activity, and Library views.
- Source review with recording identity warnings and an explicit save choice.
- In-app audio previews with playback, pause, seeking, and stop controls.
- Candidate artwork, source bitrate, and view counts, with a quality lookup when bitrate is unknown.
- Named Spotify playlist destinations, delivery status, and an Open playlist action.
- Advanced desktop settings and continued access to the full CLI.
- Sparkle update support and a Check for Updates menu item, gated on a configured signed release and a verified update feed.
- Release packaging scripts, a beginner setup guide, and a documented secondary GitHub release workflow.
- Curated GitHub source exports with separate release-only history and required secret/private-data scans before public sharing.

### Improved

- Sharper app icon and a more compact search screen.
- Optional search fields, excluded-recording visibility, source counts, and Library filtering.
- Clearer separation between a saved file and Spotify playlist delivery, including longer delivery checks and retry actions.

### Preview limitations

- Intel Macs and Windows do not have a packaged build in this release.
- Minimum macOS support depends on the complete bundled toolchain. The Swift GUI's macOS 14 source deployment target does not establish installer compatibility.
- Developer ID signing and notarization are not yet available; initial artifacts remain draft previews.
- Audio-tool bundling requires package-specific portability and license/source verification before redistribution.
- Automatic playlist delivery requires the optional Needle Spicetify companion and Spotify local-file indexing. Ordinary local-file importing works without the companion.
- In-app updates remain disabled in unsigned previews. No signed, notarized production update has been published to the feed.

## 0.1.0 — Development baseline

- Rust recording resolver and CLI for searching, reviewing, downloading, converting, and tagging audio.
- Metadata lookup, explainable candidate scoring, hard identity rejects, and source provenance.
- Browser integration and optional Spicetify companion for local-file playlist delivery.
