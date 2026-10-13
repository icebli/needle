# Getting started with Needle

Needle helps you find the right recording, listen to a preview, and save it to your music collection. You choose the audio source before anything is saved.

## Get the app

The first shared build is planned for **Apple Silicon Macs (M1 or newer) running macOS 15 Sequoia or later**. Always check the minimum macOS version in the exact release you download. Intel Macs and Windows are not included in this first installer.

1. Open [Needle releases](https://github.com/icebli/needle/releases). Public releases can be downloaded without a GitHub account.
2. Choose the latest release and download its `.dmg` file from **Assets**. You do not need the “Source code” downloads.
3. Open the downloaded disk image and drag **Needle** onto **Applications**.
4. Open **Applications → Needle**, then eject the disk image.
5. If macOS says it cannot verify the developer, click **Done**, then open **System Settings → Privacy & Security**. Scroll to the Security section, click **Open Anyway** for Needle, and confirm **Open** in the second dialog. This approval is needed because the preview is unsigned. macOS may ask again after a later manually downloaded build.

**Unsigned app:** this build does not have Apple's Developer ID identity or notarization ticket. Check the exact release notes for the supported Apple Silicon and macOS versions. Never disable Gatekeeper, run commands that remove quarantine, or install a build from an untrusted mirror.

The Mac installer includes its audio tools. You do not need Rust, Xcode, Homebrew, or Terminal to use it.

## Save your first recording

1. In **Add Music**, enter the artist and song title. Use the optional album hint or source link when needed.
2. Choose **Find recordings**.
3. Review the source title, duration, views, and source bitrate. **Unknown** means the provider did not report a value. **Check source quality** can retrieve missing bitrate information.
4. Use **Preview** to listen to an excerpt inside Needle. Previewing does not save the track to your collection.
5. If you have not installed the optional Needle Spotify companion, turn off **Add to Needle in Spotify after saving** (the name changes with your chosen playlist) and choose **Save recording**. This checkbox starts enabled; turning it off avoids waiting for a companion you have not installed. If you use automatic playlist delivery, check the playlist name before saving.

**Activity** shows download progress and Spotify delivery separately. **Library** contains your saved recordings and can reveal them in Finder. The default music folder is `~/Music/needle` — the `needle` folder inside your home folder's **Music** folder.

A high bitrate does not prove a recording is the right version. Needle shows identity warnings, and converting audio cannot restore quality missing from the source.

## Listen in Spotify

Spotify's desktop app can play the files Needle saves. Set this up once:

1. Open Spotify on your Mac and open **Settings**.
2. Find **Local Files** and enable **Show Local Files**.
3. Choose **Add a source** and select **Music → needle** in your home folder. Save a recording in Needle first if the folder does not exist yet.
4. Open **Local Files** in your Spotify library. Let Spotify index the new recording, then play it or add it to a playlist.

This local-file workflow does not require Spicetify. Leave **“Add to [playlist] in Spotify after saving” turned off** in Needle when using it. You do not need to connect a Spotify account inside Needle.

### Optional automatic playlist delivery

Automatic delivery additionally requires Spicetify **and the Needle companion installed and active in Spotify**. Having Spicetify alone is not enough. The desktop app and drag-to-Applications installer do not silently modify Spotify. See the [companion setup guide](browser-extension.md) if you want this advanced integration.

In Needle's **Settings**, choose the default playlist name; the initial default is **Needle**. The destination is captured when you search, so run a new search after changing it. Saving with delivery enabled queues that recording for the named playlist. Automatic delivery currently supports MP3.

**Saved** means the file is on your Mac. **Waiting for Spotify** means playlist delivery has not been acknowledged yet. Spotify may need several minutes to index a new local file. Keep Spotify open, check its Local Files settings, and use **Check Spotify** in Activity when available. Do not download the recording again merely because delivery is waiting.

After delivery, Activity shows the destination playlist and an **Open playlist** action. That status confirms playlist insertion; use Spotify to confirm playback.

## Update Needle

Choose **Needle → Check for Updates…** when available and follow the update window. Unsigned versions may require **System Settings → Privacy & Security → Open Anyway** after an update.

If that menu item is unavailable, quit Needle, download a newer version from the official [releases page](https://github.com/icebli/needle/releases), and drag its app into **Applications**, replacing the old app when Finder asks. Your music stays in **Music → needle**.

## Advanced settings and help

Needle's Settings keeps source selection, output format, metadata controls, album hints, and duration overrides available. MP3 is the simplest choice for the Spotify workflow.

The full CLI is also inside the app bundle. Installing the app does not add a `needle` command to your shell. Advanced users can run:

```bash
PATH="/Applications/Needle.app/Contents/Resources/bin:$PATH" \
  /Applications/Needle.app/Contents/Resources/bin/needle --help
```

If something fails, note the Needle version, macOS version, the artist/title or source URL, and the exact Activity message. Share those details with the person who gave you Needle. You do not need to share your Spotify password, cookies, or complete music library.
