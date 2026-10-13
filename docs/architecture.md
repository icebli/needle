# needle Architecture

## Overview

needle is a strict recording resolver. It is not a generic downloader. Its purpose is to find the exact song a user requested, present candidates with explainable scores, let the human confirm the audio source unless automation is explicitly requested, then handle download, conversion, tagging, library placement, and provenance.

## Core Principle

Separate two concerns that existing tools blur together:

1. **Identity resolution**: what recording did the user request?
2. **Source selection**: which upload/stream is the best available audio source for that recording?

Identity always wins over source breadth. Adding more providers must not make wrong matches easier to accept.

## Data Flow

```text
User Request
    ↓
Request Parser → ParsedRequest (artist, title, album, format, profile)
    ↓
Metadata Resolver → TrackMetadata candidate (MusicBrainz, Apple)
    ↓
Metadata Compatibility Guard → discard mismatched metadata
    ↓
Query Builder → SearchQuery[] (exact, normalized, album-hinted, audio)
    ↓
Candidate Fetcher (yt-dlp) → Candidate[] from selected SearchSource
    ↓
Duration Consensus → inferred duration from exact-match candidate cluster
    ↓
Candidate Normalizer → NormalizedTitle per candidate
    ↓
Candidate Scorer → CandidateScore (confidence + positives/warnings/rejects)
    ↓
CLI Display → recommended / uncertain / rejected groups
    ↓
Human Selection or --yes auto-select first non-rejected candidate
    ↓
Immutable Selected Source
    ↓
Downloader (yt-dlp) → raw audio file
    ↓
Audio Processor (ffmpeg) → target codec/format
    ↓
Tagger (lofty) → compatible metadata or request fallback
    ↓
Library Writer → final path
    ↓
Provenance JSON sidecar
```

## Search Sources

`SearchSource` controls source breadth:

- `auto`: YouTube + SoundCloud
- `youtube`: YouTube only
- `soundcloud`: SoundCloud only

All source search currently goes through yt-dlp search prefixes:

- YouTube: `ytsearch`
- SoundCloud: `scsearch`

Provider results are merged and deduplicated by `provider:id`. The scorer sees all candidates together.

### Source Safety

SoundCloud is useful, but noisy. It is not trusted equally by default:

- SoundCloud gets a small source-authority penalty.
- Low SoundCloud view/play counts are penalized more aggressively than low YouTube counts.
- Unknown SoundCloud popularity is a warning.
- SoundCloud can still win if identity and evidence are clearly better.

## Scoring Model

Scoring is explainable and conservative.

### Hard Rejects Before Fuzzy Scoring

Hard rejects run before positive scoring:

- Series/part mismatch, for example Part 2 vs Part 5
- Reaction/review/karaoke/cover/type beat/podcast/interview/tutorial
- Analysis annotations such as rhyme-scheme, highlighted, breakdown, explained, and no-intro tags
- Slowed/sped-up/nightcore/8D/bass-boost
- Direct source URLs that are not HTTP or HTTPS

Rejected candidates are displayed with reasons. A matching remix can remain visible when the requested artist and title are exact.

### Positive Signals

- Artist match
- Title match
- Series marker match
- Duration match
- Official/topic/VEVO hint

### Warnings and Penalties

- Lyrics/clean markers
- Unofficial upload
- Source less authoritative
- Low popularity
- Unknown duration or popularity

## Duration Strategy

Metadata duration is useful but not authoritative. APIs can return edits, snippets, or entirely wrong songs.

Current policy:

1. Resolve MusicBrainz/Apple metadata.
2. Search candidates.
3. Infer consensus duration from exact artist/title candidates.
4. If metadata and consensus differ by more than 30 seconds, use consensus.
5. If duration reference is untrusted, mismatch is warning-only rather than hard reject.

This prevents a bad metadata duration from hiding good candidates.

## Metadata Guard

Metadata must be compatible with requested artist/title before it can control tags or output paths.

If incompatible metadata appears, it is ignored:

```text
⚠ Ignoring mismatched metadata: NEEDTOBREATHE — The Heart
```

Fallback tags use the original request. This prevents a correct source from being saved under the wrong artist or album.

## Immutable Source Reference

After selection, needle stores the chosen source:

```rust
struct SelectedSource {
    provider: String,
    id: String,
    url: String,
    title: String,
    duration_ms: Option<u64>,
}
```

There is no second search during download. The selected URL is the source of truth.

## Trust Model

Default mode is human-in-the-loop:

```bash
needle get "Artist" "Title"
```

Automation is explicit:

```bash
needle get "Artist" "Title" --yes
```

`--yes` chooses the first non-rejected candidate after scoring. It does not accept rejected candidates.

## Audio Quality Model

Current quality handling is delegated to yt-dlp and ffmpeg:

- yt-dlp selects source format.
- ffmpeg converts to requested output format.
- Scoring mostly optimizes identity, not codec quality.

Important caveat: high-bitrate output does not improve low-bitrate source audio.

Planned improvements:

- Capture yt-dlp format metadata before download.
- Display codec/bitrate/sample rate in candidate table.
- Use quality only as a tie-breaker after identity.
- Save source format details in provenance.
- Add ffprobe post-download report.
- Add Chromaprint/AcoustID verification.

## Crate Separation

### needle-core

Pure Rust library. Contains request parsing, normalization, metadata, search, scoring, download, tagging, library output, provenance, and toolchain discovery.

### needle-cli

Thin terminal UI over core:

- `needle doctor`
- `needle search "Artist" "Title"`
- `needle get "Artist" "Title"`

### Future GUI

Tauri 2 desktop app or another native wrapper can call into `needle-core` or shell out to the CLI.

## Build Phases

1. **Resolver MVP**: single-track search, explainable scoring, manual selection, download, convert, tag.
2. **Trust MVP**: hard rejects, metadata guard, duration consensus, provenance.
3. **Source Quality MVP**: format probing, quality display, quality tie-breaks.
4. **Batch/Library**: CSV batch, output profiles, collision handling, dedupe.
5. **Fingerprint**: Chromaprint/AcoustID post-download verification.
6. **GUI**: desktop app.

## Library Safety

Library paths are built from user input and remote metadata, then confined to the output profile root. Artist, album, title, and extension values are sanitized before templating so separators and `..` cannot create directories outside `~/Music/needle`.

Repeat downloads do not replace an existing file by default. The placement step keeps both copies unless a future explicit collision strategy says to skip or overwrite.

Direct `--url` input must be an HTTP(S) page. Needle does not launch yt-dlp for `file:`, local paths, or other schemes.

YouTube downloads request yt-dlp's Android player client because the default web client can return media URLs that fail on the follow-up request. This changes transport only; it does not change the selected recording.

