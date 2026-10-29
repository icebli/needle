# Needle UI direction

Status: implemented first release. Search and queue review share the Listening Room workspace; Bookmarks supports gallery and list views. Native SDK linkage remains macOS 27 with a macOS 14 deployment floor.

## Product direction

Make Needle feel like a music curation instrument. The current form-led screens, small artwork, repeated row controls, and large blank states obscure the music and the decision the listener needs to make.

Choose the Listening Room composition. Give artwork and recording identity space, with a compact source comparison underneath and a persistent audition transport. Borrow the Studio Desk's evidence inspector for review rather than making every screen a dense table. Use native system typography for controls and modest editorial typography for recording titles. Use a restrained amber accent and strong monochrome artwork placeholders.

Keep source thumbnails distinct from authoritative release artwork. Show version conflicts, unavailable evidence, and uploader identity alongside the source choice. Approval remains explicit. Generated visual studies contain illustrative text, including fingerprint and mastering claims that Needle does not currently verify; none of those claims may appear in the product without measured evidence.

## Native macOS foundation

Link against the actual selected SDK while retaining macOS 14 as the deployment floor. The maintenance fix now passes the SDK version to the linker and verifies the installed Mach-O header.

Use standard split-view navigation, toolbar grouping, an inspector, and native search placement. On supported systems, use Liquid Glass for navigation and transport controls, background extension behind chrome, and scroll-edge treatment. Content remains readable and largely opaque. Honor Reduce Transparency, Reduce Motion, contrast, keyboard navigation, and VoiceOver. Availability-gate newer APIs.

Apple's guidance places glass in the control layer and encourages standard components to adopt the current appearance:

- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [WWDC26 session 289](https://developer.apple.com/videos/play/wwdc2026/289/)
- [WWDC26 session 269](https://developer.apple.com/videos/play/wwdc2026/269/)

## First implementation slice

Build one complete find-to-review workflow. Search accepts artist/title or a source link, results expose match reasons without opening another sheet, and the selected recording opens a stable inspector. Let listeners audition sources without losing selection or scroll position. Show a compact approval summary before saving.

Then apply the same composition to Bookmarks and Discover, including an artwork collection view and a compact list option. Empty states should offer a useful next action and demonstrate the collection structure without fake personal content.

Validate populated, empty, loading, provider-failure, missing-artwork, wrong-version, and narrow-window states. Compare source identity before and after approval. Test keyboard-only use and accessibility settings. A screenshot of a populated happy path is not sufficient acceptance evidence.

## Technology choices

Keep SwiftUI and AppKit for native behavior, Sparkle for updates, and the Rust resolver. The current work pins yt-dlp 2026.10.26 and resolves Sparkle provenance from Package.resolved. A new UI framework would not solve the composition problem. Add features when their evidence and interaction model are ready, rather than adding a dependency for novelty.

## Implementation and verification

The shared ListeningRoomView owns browsing selection independently from the save guard. Source identity includes provider, candidate ID, and URL. Changing the selected source stops playback while the preview service retains comparison timestamps. The bottom audition rail stays available while content scrolls. Wide search panes place source rows beside the evidence inspector; narrow queue panes stack them.

The inspector shows every supplied positive reason, warning, and rejection, plus actual provider facts. It labels thumbnails as source artwork, treats scores as ranking signals, and disables rejected or invalid sources. Metadata confirmation remains a separate explicit step. Preparation tasks are cancelled when their view disappears; both model paths discard late outcomes for replaced requests.

Visual QA used an isolated app with fixtures to exercise no-artwork states, source switching, exclusion, metadata confirmation, gallery scrolling/filtering, and bookmark reopening. Four new regression tests cover exact bookmark URLs, changed-URL rejection, and stale metadata failures. All 86 desktop tests, 140 Rust tests, strict Clippy/formatting checks, and 15 release tests pass. The canonical installer updates /Applications/Needle.app and its CLI/native-host copies.

The concept artwork remains a directional study. Fingerprint/mastering claims in that study are not implemented. Existing Swift concurrency warnings and the test runner's explicit Sparkle rpath requirement remain tracked separately.
