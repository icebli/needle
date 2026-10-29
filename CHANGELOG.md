# Changelog

User-visible changes for each release. See [Getting started](docs/GETTING_STARTED.md) for installation and updates.

## 0.9.2

- Reuse checksum-verified corresponding-source archives when upstream source servers are unavailable during release packaging.
- Update Rustls to 0.23.46 for current TLS security fixes.
- Include the album artwork and browser-session improvements prepared in 0.9.0 and 0.9.1.

## 0.9.1

- Use a selected browser session for source lookup, previews, discovery, and downloads, including Zen profiles.
- Preserve existing settings and review history when adding browser-session preferences.
- Show actionable provider errors when a selected source cannot be resolved.
- Use cookie-compatible YouTube clients for authenticated downloads.

## 0.9.0

- Fetch album covers from Cover Art Archive for the selected MusicBrainz release, with release-group fallback and retained provenance.
- Preserve album artwork in the Listening Room and bookmarks while keeping source upload thumbnails in the inspector.
- Cache covers across launches for offline display, with bounded lookups, downloads, and disk use.
- Choose a local cover or explicitly use source artwork during metadata review.
- Embed resolved catalog covers in CLI saves and discard incompatible original-release artwork for remix requests.

## 0.8.1

- Rebuilt the recording workspace around large artwork, compact source rows, and a dedicated right evidence inspector.
- Review and bookmark actions stay visible while source evidence scrolls.
- Replaced the permanent queue column with a compact recording picker.
- Playback uses one continuous bottom strip, including at narrow window widths.
- Removed promotional copy and added native Liquid Glass to search and playback controls on macOS 26 and later.

## 0.8.0

- Listening Room brings artwork-led source comparison, a persistent audition rail, and an evidence inspector to search and review.
- Inspect every match reason, warning, and rejection before reviewing metadata and approving the exact recording.
- Bookmarks gains an artwork gallery, compact list, search, source filters, sorting, and keyboard navigation.
- Updated native macOS styling and Discover presentation.
- Updated yt-dlp to 2026.10.26 and Sparkle to 2.10.1.
- Fixed stale metadata results, Swift concurrency warnings, and Sparkle lookup in desktop tests.

## 0.7.0

- Simpler Discover page with a compact artist chooser, clear review filters, and full-width recording results.
- Focused Review Queue keeps preview and approval prominent, with less-used controls in menus.
- Artwork, source bitrate, views, duration, recording warnings, and Spotify status remain visible.
- Updated in-app guides and source-quality error messages.
- Updated the bundled TLS library with a security patch.
- Includes the Spotify discovery, bulk delivery, and reliability improvements below.

## 0.6.1

- Recognize featured artists and neutral upload decorations when matching Spotify titles, while keeping remixes and live versions distinct.
- Retry failed Spotify catalog checks individually, with clear unknown, matched, and no-exact-match results.
- Companion setup now quits and reopens Spotify so the enabled extensions are active immediately.
- Includes the discovery, bulk Spotify delivery, and delivery reliability improvements below.

## 0.6.0

- Discover popular uploads from your top Spotify artists, check for exact catalog matches, and send interesting recordings to Review Queue for preview and approval.
- Add all eligible Library recordings to your chosen Spotify playlist, with duplicates and pending deliveries skipped.
- More reliable Spotify delivery: recover from local-file indexing errors, distinguish matching album metadata, and show specific waiting reasons.
- Enable or update Needle’s bundled Spicetify companion from the setup guide.

## 0.5.0

- Library discovers recordings already in your Needle folder, including CLI downloads, and reads their embedded tags and artwork.
- Refresh the folder inventory without downloading again or duplicating existing entries.

## 0.4.1

- Drag source links onto any tab to find candidates automatically in Review Queue. Check the detected details, preview, and approve each recording before downloading.
- Multiple dropped links are processed together, with clear feedback for duplicates and unsupported input.

## 0.3.0

- Clickable in-app guides explain every tab, from choosing a source to repairing artwork and understanding Spotify delivery.

- Persistent review queue for multiple source links or artist/title lines, with explicit approval and background downloads.
- Full-track previews with scrubbing, intro skipping, and timestamp comparison between candidates.
- Library artwork and metadata repair without downloading again, with original-file backups and reviewed suggestions.
- More readable candidate cards and independent download workers.

## 0.2.8

- Updated record-player logo and sharper app icon.
- Clearer Activity file details and Spotify playlist destinations.
- Unsigned Mac installer with authenticated in-app update support.

## 0.2.5 — Preview

- Clearer installation and first-launch instructions.
- Updated record-player artwork and sharper app icon.
- Cleaner Activity details with saved-file information and Spotify destination status.
- Advanced Settings and CLI commands remain available.

## 0.2.4 — Preview

- Includes a standalone runtime so audio previews and downloads do not require a separate Homebrew installation.

## 0.2.3 — Preview

- Improves compatibility of bundled audio tools in the Mac installer.

## 0.2.2 — Preview

- Updates a networking dependency to address a memory exhaustion vulnerability.

## 0.2.1 — Preview

- Keeps explicit remix titles without copying the original track’s album or track number.
- Fixes an app launch failure after copying Needle to Applications.

## 0.2.0 — Preview

- Native Mac app with Add Music, Activity, and Library.
- Candidate artwork, source bitrate, view counts, and recording identity warnings.
- In-app audio previews before saving.
- Named Spotify playlist destinations and delivery status.
- Advanced Settings and CLI commands.
