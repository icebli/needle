# Firefox / Zen extension

The Needle extension sends a user-selected media page to the local Needle CLI. It never searches for a second source: the page or link selected in Firefox becomes `needle get --url`'s immutable candidate. Needle still resolves authoritative metadata, applies its hard identity checks, writes cleaned tags, moves the file into the library, and writes provenance.

## Install on macOS

Prerequisites:

- Firefox or Zen
- `yt-dlp`, `ffmpeg`, and `ffprobe`
- Spicetify when Spotify playlist sync is wanted
- Spotify local files enabled and pointed at `~/Music/needle`

Run:

```bash
./scripts/install-browser-extension.sh
```

The installer builds release binaries, installs the Firefox native-messaging manifest under `~/Library/Application Support/Mozilla/NativeMessagingHosts`, installs and applies the Spicetify companion, and creates `target/browser-extension/needle-firefox.xpi`.

Firefox-derived production builds normally require signed extensions. For local Zen development, open `about:debugging#/runtime/this-firefox`, choose **Load Temporary Add-on**, and select `browser-extension/manifest.json`. The native host and Spicetify companion persist; only the temporary browser add-on must be reloaded after a browser restart.

## Use

- Open the Needle toolbar popup to review or edit the detected artist/title, then choose **Download with Needle**.
- Right-click a YouTube, SoundCloud, or other HTTP(S) media page and choose **Download this page with Needle**.
- Right-click a media link and choose **Download linked track with Needle**. YouTube and SoundCloud cards include better artist hints; ambiguous title-only links are rejected and can be corrected in the popup.
- Leave **Add to Needle playlist** enabled to create/reuse a private Spotify playlist named `Needle` and add the newly indexed local file.

The popup detector has dedicated handling for YouTube and SoundCloud, consumes `MusicRecording` JSON-LD on sites such as Bandcamp, and falls back to common `Artist - Title` page titles. Any HTTP(S) URL accepted by the installed `yt-dlp` can still be submitted after filling the artist/title fields.

## Trust boundary

- Page access uses Firefox `activeTab`: generic pages are inspected only after the user clicks Needle or its context-menu item.
- A small context listener is preloaded only on YouTube and SoundCloud so right-clicked cards retain their artist/title text.
- The native host accepts only HTTP(S) URLs and passes all values as process arguments, never through a shell.
- Spotify handoff is a JSON queue in Needle's user config directory. Its server binds only to `127.0.0.1:29878`, accepts browser CORS requests only from Spotify's known desktop origins, and exits 30 seconds after the queue is empty.
- Spicetify creates the playlist through Spotify's authenticated Web API wrapper, then uses the desktop `LocalFilesAPI` and `PlaylistAPI` for the `spotify:local:` item. Existing playlist items are deduplicated by both URI and cleaned artist/title.

## Development checks

```bash
node --test browser-extension/tests/*.test.js spicetify/tests/*.test.js
npx web-ext lint --source-dir browser-extension --ignore-files 'tests/**'
cargo test -p needle-browser-host
cargo test -p needle-cli direct_url_resolution_does_not_run_a_search
```
