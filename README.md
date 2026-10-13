# needle

Strict recording resolver for local music libraries.

needle is not a generic YouTube downloader. It takes an artist and title, searches supported audio sources, ranks candidates with visible reasons, lets you choose the source, then downloads, converts, tags, and saves the file.

Core promise: wrongness stays visible. `The Heart Pt. 2` should never silently become `The Heart Part 5`.

## Get the Mac app

Needle's desktop app lets you review recording sources, listen to previews, compare source bitrate and views, and save music for Spotify's local-file library. Advanced settings and the full CLI remain available.

- [Download releases](https://github.com/icebli/needle/releases)
- [Getting started: install, save a song, and set up Spotify](docs/GETTING_STARTED.md)
- [What's new](CHANGELOG.md)
- [Release QA checks](docs/QA.md)

The first shared installer is planned for **Apple Silicon Macs with macOS 15 or later**, subject to verification of its bundled tools. Check the exact release's minimum macOS version: the current local review build requires macOS 27 because of its bundled FFmpeg. Version 0.2.1 is being prepared as a draft preview; a signed, notarized release is not available yet. A verified release package is intended to include the audio tools, so friends can use the app without a development toolchain. Check each release's verification notes before sharing it.

Needle includes Sparkle update support through **Needle → Check for Updates…**. It is enabled only for configured release builds; unsigned previews keep it disabled. The update feed must contain Developer ID signed, notarized artifacts with Sparkle update signatures. No production update is available yet.

## Development and releases

Forgejo remains the main everyday development remote (`origin`). GitHub is the secondary sharing channel for reviewed source snapshots, versioned installers, and changelogs. Public sharing is gated on source/privacy checks. GitHub receives a separate release-only history; private development notes and Forgejo's original commit history are not exported. See [the release workflow](docs/RELEASING.md).

The Rust resolver, CLI, browser integration, and native macOS app share the same recording checks. Batch mode and fingerprint verification are outside the current release.

For local development installation:

```bash
./scripts/install-browser-extension.sh --skip-spotify
open "$HOME/Applications/Needle.app"
```

This source installer requires the development and audio tools below. See [desktop development](docs/desktop.md) for build commands and advanced controls. Friends downloading a packaged release should follow [Getting started](docs/GETTING_STARTED.md) instead.

## Requirements

- Rust 2021 toolchain
- [`yt-dlp`](https://github.com/yt-dlp/yt-dlp)
- [`ffmpeg`](https://ffmpeg.org/) and `ffprobe`
- Optional later: Chromaprint `fpcalc`

Check tools:

```bash
cargo run --bin needle -- doctor
```

`yt-dlp`, `ffmpeg`, and `ffprobe` are required. `fpcalc` is optional and is shown as unavailable, not as a toolchain failure, until fingerprint verification is implemented.

## Build

```bash
cargo build --release
```

Binary:

```bash
target/release/needle
```

## Quick usage

Search only:

```bash
cargo run --bin needle -- search "Kendrick Lamar" "The Heart Pt. 2" --album "Overly Dedicated"
```

Interactive download:

```bash
cargo run --bin needle -- get "Kendrick Lamar" "The Heart Pt. 2" --album "Overly Dedicated"
```

Auto-accept first non-rejected candidate:

```bash
cargo run --bin needle -- get "Kendrick Lamar" "The Heart Pt. 2" --album "Overly Dedicated" --yes
```

Aliases:

```bash
-y
--auto-accept
```

## Search sources

Default source mode is `auto`:

```bash
needle search "Artist" "Title" --source auto
```

Supported modes:

```bash
--source auto        # YouTube + SoundCloud
--source youtube     # YouTube only
--source soundcloud  # SoundCloud only
```

All sources use `yt-dlp` search backends. Source expansion only changes candidate pool. Identity scoring still decides ranking.

SoundCloud is treated cautiously because it has plenty of junk:

- exact title/artist still required for high scores
- SoundCloud gets a small source-authority penalty
- low view/play counts are penalized
- unknown SoundCloud popularity gets a small warning

## How ranking works

Candidates are grouped as:

- `Recommended`
- `Uncertain`
- `Rejected`

Scoring inputs:

- artist match
- title match
- series marker match, for example `Pt. 2`
- expected duration
- official/topic/VEVO hints
- source authority
- popularity/view count
- negative markers, for example reaction, cover, slowed, analysis, no intro

Hard rejects happen before fuzzy scoring:

- wrong part/series number
- reaction/review/karaoke/cover/type beat/podcast/interview/tutorial
- analysis annotations such as rhyme-scheme, highlighted, breakdown, explained, or no-intro tags
- slowed/sped-up/nightcore/8D/bass-boost
- direct URLs that are not HTTP or HTTPS

Rejected candidates are still shown with reasons.

## Duration handling

Metadata APIs can return wrong durations. needle does not blindly trust them.

Current behavior:

1. Try MusicBrainz and Apple metadata.
2. Search candidate sources.
3. Infer a consensus duration from exact artist/title candidate clusters.
4. If metadata duration conflicts strongly with candidate consensus, consensus wins.
5. Large duration mismatches become warnings unless duration was explicitly trusted.

Manual escape hatch:

```bash
needle search "Artist" "Title" --duration-override 4:54
```

This is for debugging or difficult cases, not normal use.

## Metadata and tagging

Metadata comes from MusicBrainz and Apple when compatible with the request.

If metadata resolves to the wrong song, needle ignores it and falls back to requested artist/title for tags and output path.

Example warning:

```text
⚠ Ignoring mismatched metadata: NEEDTOBREATHE — The Heart
```

This prevents a correct download from being saved under the wrong artist or album.

## Audio quality

Current quality behavior is simple:

- download uses `yt-dlp`
- source format selection is delegated to `yt-dlp`
- output defaults to MP3 conversion
- scoring is mostly identity-first, not quality-first

Important: converting to MP3 320k does not make a low-bitrate source high quality. If the source is YouTube Opus around 128-160 kbps, conversion can only preserve or degrade it.

Candidate cards show views and source bitrate when reported. Missing values remain Unknown; Check source quality can retrieve bitrate through a direct source lookup. The bitrate describes the downloadable audio source, not the later MP3 conversion.

Planned quality improvements:

- record sample rate from `yt-dlp`
- use quality as a tie-breaker after identity
- save source format in provenance JSON
- post-download `ffprobe` report
- optional fingerprint verification with Chromaprint/AcoustID

## Output

Default output path:

```text
~/Music/needle/<Artist>/<Album>/<Track> - <Title>.<ext>
```

A JSON provenance sidecar is written next to the audio file. It records request, selected source, score reasons, metadata sources, and tool version.

## Commands

```bash
needle doctor
needle search "Artist" "Title" [--album "Album"] [--source auto|youtube|soundcloud]
needle get "Artist" "Title" [--album "Album"] [--source auto|youtube|soundcloud] [--yes]
```

Useful flags:

```bash
--no-metadata              # skip metadata lookup
--duration-override 4:54   # override expected duration
--format mp3|m4a|opus|flac # output format
--profile default          # output profile, currently basic
--url URL                  # direct yt-dlp-supported URL
```

## Firefox / Zen extension

Needle includes a Firefox extension for downloading the current YouTube, SoundCloud, Bandcamp, or other `yt-dlp`-supported HTTP(S) page. Its toolbar popup lets you review the detected artist/title, and its page/link context menus send the selected URL through Needle's normal metadata, hard-reject, tagging, library, and provenance flow.

An optional Spicetify companion creates/reuses a private `Needle` playlist and adds the cleaned `spotify:local:` recording after Spotify indexes it. See [docs/browser-extension.md](docs/browser-extension.md) for installation, trust boundaries, and development checks.

## Development

```bash
cargo check
cargo test
cargo test -p needle-core --lib
cargo run --bin needle -- doctor
```

## Roadmap

- richer source quality reporting
- config file for output profiles and scorer policy
- batch mode from CSV
- local library dedupe before download
- Chromaprint/AcoustID verification
- standalone signed desktop distribution
