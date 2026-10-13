<p align="center">
  <img src="assets/needle-banner.svg" alt="Needle — find the right recording" width="900">
</p>

# needle

Needle helps you find the exact recording you want, review the available sources, and save a clean local music file. It is a strict recording resolver, not a generic downloader: wrongness stays visible.

## Download the Mac app

The upcoming **0.2.5 friend preview** is for Apple Silicon Macs. It is unsigned and is not published yet. When it is available, download the `.dmg` from the [GitHub releases page](https://github.com/icebli/needle/releases), then follow [Getting started](docs/GETTING_STARTED.md). macOS may require **System Settings → Privacy & Security → Open Anyway** on first launch. Never disable Gatekeeper or remove quarantine attributes.

The packaged app includes the audio tools, so friends do not need Rust, Python, Xcode, or Homebrew. Check the exact release notes for its minimum macOS version.

## The friendly workflow

1. Enter an artist and title, or paste a supported source link.
2. Compare candidates using identity warnings, duration, artwork, source bitrate, play/view count, and uploader details.
3. Preview the exact candidate inside Needle before saving.
4. Save it to `~/Music/needle`. Needle tags the file, writes a provenance sidecar, and keeps the chosen source fixed.
5. Play it through Spotify Local Files, or optionally let the Needle companion add it to the named Spotify playlist after indexing.

Activity separates local saving from Spotify delivery and shows the confirmed playlist destination. Library keeps saved recordings easy to find. Advanced Settings and the full CLI remain available for direct URLs, alternate formats, duration overrides, and scripted workflows.

## Start here

| Goal | Guide |
| --- | --- |
| Install and save your first recording | [Getting started](docs/GETTING_STARTED.md) |
| Set up Spotify Local Files | [Getting started — Spotify](docs/GETTING_STARTED.md#listen-in-spotify) |
| Use advanced CLI commands | [CLI guide](docs/CLI.md) |
| Understand desktop controls | [Desktop guide](docs/desktop.md) |
| Install the Firefox / Zen extension | [Browser extension](docs/browser-extension.md) |
| Understand the resolver | [Architecture](docs/architecture.md) |
| Validate a release | [Release QA](docs/QA.md) |
| Read user-visible changes | [Changelog](CHANGELOG.md) |

## Spotify

Spotify's desktop Local Files feature works without Spicetify. Enable Local Files, add `~/Music/needle` as a source, and let Spotify index each saved recording. Optional automatic playlist delivery requires Spotify, Spicetify, and the Needle companion; Spicetify alone is not enough.

Needle captures the playlist name when you search and reports delivery separately from saving. A waiting status means Spotify is still indexing or the companion has not acknowledged the file; retry delivery from Activity instead of downloading again.

## Updates

Needle uses Sparkle for authenticated updates when an update feed is configured. Sparkle's Ed25519 signature is separate from Apple's Developer ID signing, but unsigned updates may still require manual macOS approval. The friend preview keeps automatic checks disabled until that path is tested end to end; use the official releases page for manual updates.

## Source development

For building Needle yourself, install Rust, Swift, `yt-dlp`, FFmpeg, and `ffprobe`:

```bash
cargo test
swift test --package-path desktop
./scripts/install-browser-extension.sh --skip-spotify
open "$HOME/Applications/Needle.app"
```

See [the CLI guide](docs/CLI.md) for resolver commands and [the desktop guide](docs/desktop.md) for local development details.

## License

Needle is released under the [MIT License](LICENSE). Bundled tools retain their own licenses and notices.
