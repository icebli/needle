# Needle CLI

The CLI is the advanced interface for scripting, direct source URLs, alternate output formats, and debugging. The desktop app uses the same resolver and scoring rules.

## Requirements

For a source checkout, install Rust 2021, `yt-dlp`, FFmpeg (`ffmpeg` and `ffprobe`), and optionally Chromaprint's `fpcalc`.

```bash
cargo run --bin needle -- doctor
```

Packaged desktop releases include the required audio tools. The bundled executable is available at `Needle.app/Contents/Resources/bin/needle`.

## Commands

```bash
needle doctor
needle search "Artist" "Title" [--album "Album"] [--source auto|youtube|soundcloud]
needle get "Artist" "Title" [--album "Album"] [--source auto|youtube|soundcloud] [--yes]
```

Search without downloading:

```bash
needle search "Kendrick Lamar" "The Heart Pt. 2" --album "Overly Dedicated"
```

Interactive download:

```bash
needle get "Kendrick Lamar" "The Heart Pt. 2" --album "Overly Dedicated"
```

Auto-accept the first non-rejected candidate:

```bash
needle get "Kendrick Lamar" "The Heart Pt. 2" --album "Overly Dedicated" --yes
```

Useful flags:

```text
--source auto|youtube|soundcloud
--url URL                    direct HTTP(S) source; no replacement search
--no-metadata                skip MusicBrainz/Apple metadata lookup
--duration-override 4:54     override expected duration
--format mp3|m4a|opus|flac   choose output format
--profile default            choose an output profile
--json                       emit structured output
--strict                     preserve hard identity rejects during download
```

The short aliases `-y` and `--auto-accept` are equivalent to `--yes`.

## Search and scoring

The default `auto` source mode searches YouTube and SoundCloud. Source expansion changes the candidate pool; identity scoring still decides the ranking. SoundCloud receives a small authority penalty, and low or unknown play counts remain visible as warnings.

Candidates are grouped as **Recommended**, **Uncertain**, or **Rejected**. Scoring considers artist/title match, series markers, duration, official-source hints, source authority, and provider popularity. Hard rejects run before fuzzy scoring and cover wrong series numbers, reactions, reviews, karaoke, covers, type beats, podcasts, interviews, tutorials, analysis annotations, slowed/sped-up/nightcore/8D uploads, and invalid direct URLs.

Rejected candidates remain visible with human-readable reasons.

## Duration and metadata

Needle compares MusicBrainz and Apple metadata with candidate duration consensus. A large mismatch becomes a warning, and metadata that resolves to a different recording is ignored in favor of the requested artist/title.

Use `--duration-override` only for difficult or diagnostic cases. The selected source URL is immutable after approval; download does not perform a second search.

## Audio quality and output

Candidate results show provider-reported source bitrate and views when available. Missing values remain **Unknown**. The source bitrate describes the downloadable stream; converting it to MP3 320 kbps cannot restore quality that was absent from the source.

The default output path is:

```text
~/Music/needle/<Artist>/<Album>/<Track> - <Title>.<ext>
```

Each saved recording receives a JSON provenance sidecar containing the request, selected source, score reasons, metadata sources, and tool version.

## Browser and Spotify workflows

The Firefox / Zen extension turns the selected page or link into an immutable direct URL request. See [browser-extension.md](browser-extension.md) for installation and trust boundaries.

The optional Spicetify companion adds indexed local files to the named Spotify playlist. Ordinary Spotify Local Files playback remains available without the companion.
