<p align="center">
  <img src="assets/needle-banner.svg" alt="Needle — find the right recording" width="900">
</p>

# needle

Needle helps you find the exact recording you want, review the available sources, and save a clean local music file. It is a strict recording resolver, not a generic downloader: wrongness stays visible.

## Download the Mac app

Download **[Needle 0.2.8](https://github.com/icebli/needle/releases/tag/v0.2.8)** for **Apple Silicon Macs (M1 or newer), macOS 15 Sequoia or later**. Open the `.dmg` and drag Needle to Applications. Follow [Getting started](docs/GETTING_STARTED.md) for your first recording and Spotify setup.

The app is unsigned. On first launch, macOS may require **System Settings → Privacy & Security → Open Anyway**. The installer includes its audio tools; you do not need Rust, Python, Xcode, or Homebrew.

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
| Read user-visible changes | [Changelog](CHANGELOG.md) |

## Spotify

Spotify's desktop Local Files feature works without Spicetify. Enable Local Files, add `~/Music/needle` as a source, and let Spotify index each saved recording. Optional automatic playlist delivery requires Spotify, Spicetify, and the Needle companion; Spicetify alone is not enough.

Needle captures the playlist name when you search and reports delivery separately from saving. A waiting status means Spotify is still indexing or the companion has not acknowledged the file; retry delivery from Activity instead of downloading again.

## Updates

Choose **Needle → Check for Updates…** when available. If it is unavailable, download a newer version from the official releases page and replace the app in Applications. Your saved music stays in `~/Music/needle`. Unsigned versions may require **Open Anyway** again.

## License

Needle is released under the [MIT License](LICENSE). Bundled tools retain their own licenses and notices.
