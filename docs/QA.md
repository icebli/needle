# Needle release QA

Validate the actual packaged app before sharing a release. Source tests, successful packaging, and a local launch are distinct evidence; none alone proves that a friend can install, preview, save, and play a recording.

## Canonical recording

Use **Doechii — Nissan Altima (Whethan Remix)**, uploaded by **Whethan**, as the canonical real-source regression recording for future release checks:

- Canonical source: https://soundcloud.com/whethan/doechii-nissan-altima-whethan
- Original share link: https://on.soundcloud.com/Nqh9lDpSJclyPfJnCN
- Observed SoundCloud source ID: `2045371444`.
- Reference observation: approximately 130.583 seconds, AAC at approximately 160 kbps, and 2,038,466 views/plays reported by the provider.

The duration, available format, bitrate, and popularity figures are observations, not fixed test assertions. Source availability and provider counters can change. Preserve the exact recording identity and source URL when comparing results; never replace it silently with a different upload. This guide designates a future QA case and does not assert that every check below has already passed.

## Install and compatibility

1. Record the app version, source snapshot/tag, artifact checksum, architecture, macOS version, and packaged tool manifest.
2. Mount the DMG, drag Needle to Applications, and launch that installed copy. Test on a clean account or machine without developer-installed media tools.
3. Check the app's advertised minimum OS against the maximum deployment requirement of every bundled executable and library. Test that minimum OS directly before claiming support.
4. For a release intended for friends, verify Developer ID signatures, notarization, stapling, and Gatekeeper acceptance. An ad-hoc signed draft remains a review artifact.

The current local review package requires macOS 27 due to its bundled FFmpeg. The planned shared Apple Silicon build targets macOS 15 or later, subject to validation of its own tool manifest and actual execution.

## Find and preview the recording

1. Search using the canonical artist/title and use the source link above when needed. Check that remix markers and the upload's identity remain visible.
2. Confirm the candidate displays artwork rather than a permanent placeholder, a source link, duration, provider-reported views/plays, and source bitrate when known. Unknown data must remain explicit.
3. Use **Check source quality** when bitrate is initially unknown. Confirm the value describes the selected downloadable source, not the converted output bitrate.
4. Preview inside Needle. Confirm audible playback, pause/resume, seeking, stop, cancellation during preparation, and switching to another candidate. Previewing must not create a Library item or enqueue Spotify delivery.
5. Save the explicitly approved source and confirm Activity progresses to a saved file. Check its tags, artwork, source provenance, and readability in a player. Changing a provider's metadata must not cause a silent replacement search.

## Spotify workflows

Test these separately and record which one passed:

- **Ordinary Local Files:** disable **Add to Needle in Spotify after saving** when the companion is absent. Save, enable Spotify Local Files for the Needle music folder, and verify playback in Spotify. The app should not wait for optional playlist automation in this mode.
- **Automatic playlist delivery:** use an explicitly selected test playlist and an installed, active Needle Spicetify companion. Confirm the saved file is indexed, the expected playlist receives the correct local recording, and Activity names that playlist with a working Open playlist link. Verify audible playback independently of the companion acknowledgement.
- **Delayed delivery:** temporarily unavailable Spotify/companion should leave the saved file intact, report waiting clearly, and allow a later status check without downloading the recording again or adding duplicate playlist entries.

Playlist insertion changes Spotify state. Use the intended QA destination and recording with authorization for the test. Do not delete existing user music or playlist entries to reset a test.

## Updates

Needle uses Sparkle for in-app updates. The **Needle → Check for Updates…** menu item is disabled when the bundle lacks the expected feed URL and valid public update key, including current unsigned previews.

For a configured release, test a real version upgrade using Developer ID signed, notarized artifacts and the correct Sparkle update signature. Confirm the update is offered with appropriate notes, installation preserves music/settings, and the replacement app launches. Test that unavailable or invalid update data does not replace the running app. Do not add unsigned drafts to the production appcast.

The presence of Sparkle.framework or an empty appcast is not proof of working release updates. No production update is currently available; this acceptance check remains pending until signed artifacts and a populated verified feed exist.

## Evidence to retain

Record each acceptance result as passed, failed, or not run, with the exact artifact and environment. Keep screenshots/logs free of account credentials, personal paths, private playlist identifiers, and unrelated library data before attaching them to public release notes. Report tool/source licensing and corresponding-source readiness separately from functional QA.
