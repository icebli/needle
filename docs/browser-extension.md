# Browser companion

The Needle browser companion sends a user-selected media page to the local Needle CLI. It never searches for a second source: the page or link selected in the browser becomes `needle get --url`'s immutable candidate. Needle still resolves authoritative metadata, applies its hard identity checks, writes cleaned tags, moves the file into the library, and writes provenance.

The automatic Spotify playlist feature also uses a small Spicetify companion. Install [Spicetify from its official site](https://spicetify.app/) first, then return here to install Needle's companion and browser bridge.

## Install the companion bundle

The latest [Needle release](https://github.com/icebli/needle/releases) includes `needle-companion.zip` in **Assets**. It contains the Chrome extension, a Firefox/Zen package, the optional Spicetify companion, and an installer that uses the native host bundled inside Needle.app. Unzip it into its own permanent folder, such as `Downloads/needle-companion`, so the browser can keep using the files.

1. Install Needle in `/Applications` or `~/Applications` first.
2. Download and unzip `needle-companion.zip`.
3. Double-click **Install Needle Companion.command** and press Return when it finishes. The installer registers the native bridge for Chrome, Firefox, and Zen and opens Chrome's extensions page.
4. In Chrome, enable **Developer mode** at `chrome://extensions`, choose **Load unpacked**, and select the bundle's `chrome-extension` folder. Chrome requires this developer-mode installation because the companion is not distributed through the Chrome Web Store. Keep that folder in place after loading it.
5. In Firefox or Zen, open `about:debugging#/runtime/this-firefox`, choose **Load Temporary Add-on**, and select the included `needle-firefox.xpi`. The unsigned extension is temporary and must be loaded again after each browser restart; the native bridge remains installed.

The companion installer does not change Spotify by default. After installing [Spicetify](https://spicetify.app/) with its [official installation guide](https://spicetify.app/docs/advanced-usage/installation/), run the installer with `--setup-spicetify`:

```bash
"$HOME/Downloads/needle-companion/Install Needle Companion.command" --setup-spicetify
```

If you chose another folder, replace the path with that folder's location. In Finder, you can open Terminal, type the opening quote and path, drag **Install Needle Companion.command** into the Terminal window, then type ` --setup-spicetify` and press Return. This copies Needle's Spotify companion into Spicetify and applies it. Restart Spotify if it was open. Ordinary Spotify Local Files playback does not require this step.

## Advanced source installation

For contributors or users who want to build the browser bridge themselves, use a Needle source checkout with Rust installed and run:

```bash
./scripts/install-browser-extension.sh
```

The installer builds release binaries, installs the Firefox, Zen, and Chrome native-messaging manifests, installs and applies the Spicetify companion, and creates `target/browser-extension/needle-firefox.xpi` plus `target/browser-extension/needle-chrome.zip`.

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
