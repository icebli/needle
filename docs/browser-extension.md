# Firefox / Zen extension

The Needle extension sends a user-selected media page to the local Needle CLI. It never searches for a second source: the page or link selected in Firefox becomes `needle get --url`'s immutable candidate. Needle still resolves authoritative metadata, applies its hard identity checks, writes cleaned tags, moves the file into the library, and writes provenance.

## Advanced installation on macOS

Prerequisites:

- A Needle source checkout, Rust, and Firefox or Zen
- `yt-dlp`, `ffmpeg`, and `ffprobe`
- Spicetify when Spotify playlist sync is wanted
- Spotify local files enabled and pointed at `~/Music/needle`

Run:

```bash
./scripts/install-browser-extension.sh
```

The installer builds release binaries, installs the Firefox native-messaging manifest under `~/Library/Application Support/Mozilla/NativeMessagingHosts`, installs and applies the Spicetify companion, and creates `target/browser-extension/needle-firefox.xpi`.

Firefox-derived production builds normally require signed extensions. For temporary use in Firefox or Zen, open `about:debugging#/runtime/this-firefox`, choose **Load Temporary Add-on**, and select `browser-extension/manifest.json`. The native host and Spicetify companion persist; only the temporary browser add-on must be reloaded after a browser restart.

## Use

- Open the Needle toolbar popup to review or edit the detected artist/title, then choose **Download with Needle**.
- Right-click a YouTube, SoundCloud, or other HTTP(S) media page and choose **Download this page with Needle**.
- Right-click a media link and choose **Download linked track with Needle**. YouTube and SoundCloud cards include better artist hints; ambiguous title-only links are rejected and can be corrected in the popup.
- Leave **Add to Needle playlist** enabled to create/reuse a private Spotify playlist named `Needle` and add the newly indexed local file.

The popup detector has dedicated handling for YouTube and SoundCloud, consumes `MusicRecording` JSON-LD on sites such as Bandcamp, and falls back to common `Artist - Title` page titles. Any HTTP(S) URL accepted by the installed `yt-dlp` can still be submitted after filling the artist/title fields.

## Permissions and privacy

Needle reads the selected page when you click its toolbar button or context menu. On YouTube and SoundCloud, it also reads the selected card's artist and title. Downloads happen on your Mac through the installed Needle tools.

Automatic playlist delivery uses your existing Spotify desktop session through the optional companion. Needle does not ask for your Spotify password.

## Troubleshooting

- **Needle cannot connect:** rerun the installer for the native browser bridge, then restart the browser.
- **Extension disappeared after restarting:** temporary add-ons must be loaded again through `about:debugging`.
- **Artist or title is wrong:** edit the fields in the popup before downloading.
- **Spotify delivery waits:** confirm Spotify Local Files includes `~/Music/needle` and the Needle companion is active. Disable playlist delivery if you only want the saved file.
