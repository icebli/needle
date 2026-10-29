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

## Browser sign-in

Needle can reuse a signed-in browser session when a source requires authentication. In the desktop app, open Settings, enable Browser sign-in, and select the browser where you signed into the source site. Zen uses its default profile; an optional profile field selects another profile.

For CLI use, set the browser selector for that invocation:

```bash
NEEDLE_COOKIES_FROM_BROWSER=firefox needle search "Kendrick Lamar" "Look Out for Detox" --json
```

Selectors use yt-dlp’s `BROWSER[:PROFILE]` syntax. Needle passes the setting to source lookup, discovery, and downloads. Cookies remain in the browser; Needle does not export them to a cookie file. Clear the desktop setting or omit the environment variable to use anonymous requests.

## Inspect and repair existing files

```bash
needle inspect "/path/to/recording.mp3" --json
needle repair-suggestions "/path/to/recording.mp3" --json
needle repair "/path/to/recording.mp3" --artist "Artist" --title "Title" --album "Album" --json
needle repair "/path/to/recording.mp3" --clear-album --artwork "/path/to/cover.jpg" --json
```

Repair changes embedded tags and artwork without downloading or converting audio. A sibling backup preserves the original file; its path is returned in the JSON response. Existing provenance and unrelated tags are preserved. `--artwork-url` accepts an HTTP(S) image; images are validated and limited to 10 MiB. Suggestions do not apply changes automatically, and variant warnings help avoid replacing a remix's metadata with the original recording's.

## Inventory an existing library

```bash
needle library-scan ~/Music/needle --json
```

Recursively lists supported audio files and their embedded tags without modifying them. Hidden files, repair backups, temporary files, and symbolic links are skipped. Unreadable tags produce warnings while the file remains visible for review.

### Artist discovery

```bash
needle discover "Artist name" --source auto --json
```

Searches bounded YouTube and SoundCloud results for the artist, retaining exact URLs and reported source views/bitrate. It does not download or check Spotify availability; use Discover in the desktop app for catalog checks and review. Unknown popularity or quality stays unknown.
