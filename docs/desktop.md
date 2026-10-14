# Needle desktop

Needle is a macOS companion for bringing recordings into your Spotify local-file library. Search for a recording or supply a source link, review its identity warnings, explicitly select the source, and save tagged audio. Phone transfer is outside this release.

## Find and save a recording

Follow [Getting started](GETTING_STARTED.md) to install Needle. In **Add Music**, enter an artist and title or paste a source link, then choose **Find recordings**. Compare the results, preview a candidate, and choose **Save recording** when it matches what you want.

Drag a source link from your browser onto any tab to add it to **Review Queue**. Needle finds candidates automatically. Check the detected artist and title, then preview and approve the recording. Use **Edit request** to correct source hints. Multiple dropped links join the queue together; downloads still require approval.

**Review Queue** also accepts one link or `Artist — Title` per line, persists your review progress, and runs up to two approved downloads in the background. Each recording requires explicit source approval.

**Library → Repair** edits embedded tags and artwork in place, with a backup before each change. Metadata and original-source artwork are suggestions you approve. See [Getting started](GETTING_STARTED.md#repair-a-saved-recording).

**Activity** shows saving progress and Spotify delivery. **Library** scans `~/Music/needle` when opened, including existing recordings saved through the CLI. Choose **Refresh** after adding files outside the app. Embedded tags supply artist, song, and album; filenames are used when tags are missing. Scanning does not change audio files, and backup/temporary files are skipped. Use **Show in Finder** to find a file.

## Preview before saving

Use Preview on a source card to listen to the exact source. Needle prepares full-track temporary audio with playback, pause, scrubbing, ten-second jumps, and Skip intro. Keep position between candidates compares versions at the same timestamp; turning it off remembers each candidate's own position. Only one preview plays at a time. Preparation can take longer for large recordings. Preview files stay outside the music library and Spotify queue.

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

Needle saves the source you selected; it does not search again during download. For scripting and direct-URL options, see the [CLI guide](CLI.md).

## Troubleshooting

- **Preview takes a while:** Needle may need to download the source before trimming the excerpt. Try another candidate if the provider fails.
- **Unknown bitrate or views:** the provider has not supplied that information. Try **Check source quality** for bitrate.
- **Waiting for Spotify:** keep Spotify open, confirm Local Files includes your Needle folder, and check that the optional companion is active. Retry delivery in Activity rather than saving the track again.
- **Wrong recording:** compare the title, duration, identity warnings, and preview before saving. Use an exact source link or duration override for difficult matches.

For help, include the app version and exact error message. Keep passwords and account credentials private.

## In-app guides

Choose the **?** button in any tab to open its guide. Guides explain the controls, common problems, and next steps without leaving Needle.
