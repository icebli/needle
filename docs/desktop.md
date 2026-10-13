# Needle desktop

Needle is a macOS companion for bringing recordings into your Spotify local-file library. Search for a recording or supply a source link, review its identity warnings, explicitly select the source, and save tagged audio. Phone transfer is outside this release.

## Build, install and open

Development prerequisites: macOS 14+, a Swift toolchain, Rust, yt-dlp, ffmpeg and ffprobe. No third-party Swift packages are required.

```bash
./scripts/install-browser-extension.sh --skip-spotify
open "$HOME/Applications/Needle.app"
```

This installs the desktop app, its bundled CLI and bridge, the PATH CLI at `~/.cargo/bin/needle`, and the browser native-host copies. `--skip-spotify` preserves Spotify's configuration and companion files. Omitting the flag stages and applies the companion when Spicetify is available, matching the existing installation workflow. `--cli-only` preserves the CLI/browser-only install path without requiring Swift.

For local development, the Codex Run action calls:

```bash
./script/build_and_run.sh --verify
```

The build script produces `target/desktop/Needle.app`. This is a locally ad-hoc signed app, not a notarized public distribution. Audio tools must already be installed; the app does not silently download or install them.

## Preview before saving

Use Preview on a source card to listen inside Needle. The app prepares a temporary excerpt of up to 30 seconds from that exact source, with playback, pause, and seeking controls. Only one preview plays at a time. If a provider cannot download a section, Needle temporarily fetches the source audio and trims it locally; preparation can take longer. Switching sources or leaving Add Music stops it; saving is still a separate explicit action. Preview files are temporary and do not enter the music library or Spotify queue.

## Spotify setup

In Spotify desktop Settings, enable Show Local Files and add `~/Music/needle` as a source. Needle saves files into this stable folder. Optional automatic playlist delivery uses the existing Spicetify companion; ordinary local-file importing remains available without it.

File completion and Spotify delivery are separate. A saved track can remain waiting while Spotify indexes it or the companion starts. Activity names the captured destination playlist and opens the acknowledged playlist link after completion. Companion acknowledgement records playlist insertion, not independently verified playback. Opening Spotify or retrying delivery should never redownload a successfully saved file.

## Source quality

Every candidate card shows provider-reported views and source audio bitrate when available. Flat search results can omit bitrate: use Check source quality for a direct audio-format lookup before saving. Missing values remain Unknown; Needle never substitutes the MP3 conversion bitrate for the original stream bitrate. Hover over a shortened view count to see the exact reported count.

## Advanced workflow

Desktop Settings exposes supported source, format and metadata controls. MP3 is the default. Other formats are advanced outputs and must be checked for compatibility with the intended player. A higher output bitrate does not improve the source recording's quality.

The full CLI remains available:

```bash
needle search "Artist" "Title" --album "Album" --source soundcloud
needle get "Artist" "Title" --url "https://example.com/recording" --format mp3
needle search "Artist" "Title" --no-metadata --duration-override 4:54
needle search "Artist" "Title" --json
needle doctor --json
needle get --help
```

The app confirms a source before starting a download. Its download command uses the selected URL and does not run a replacement source search. The GUI uses `get --strict` to enforce hard rejects even if the source changes after review. The existing CLI direct-URL override remains available for expert users; the desktop app never enables that override.

## Verification

```bash
cargo test
cargo clippy --workspace --all-targets
swift test --package-path desktop
node --test browser-extension/tests/*.test.js spicetify/tests/*.test.js
bash -n scripts/build-desktop.sh script/build_and_run.sh scripts/install-browser-extension.sh
```

Synthetic tests do not contact Spotify or download real recordings. A real Spotify playback check requires a user-approved recording and a working Spotify setup; source/build/install evidence alone does not establish that result.
