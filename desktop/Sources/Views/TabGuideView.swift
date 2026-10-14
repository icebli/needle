import SwiftUI

/// A small, self-contained guide for the currently selected part of Needle.
/// Keeping the content here makes the help button useful without sending users
/// to a separate manual or an unfamiliar web page.
struct TabGuideView: View {
    let destination: Destination
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: destination.symbol)
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text("How to use \(destination.rawValue)")
                        .font(.title2.bold())
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(sections) { section in
                        GuideSectionView(section: section)
                    }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 520, idealHeight: 650)
    }

    private var subtitle: String {
        switch destination {
        case .addMusic: "Find the right recording, listen before saving, then choose what to keep."
        case .reviewQueue: "Review a whole list at your pace while approved downloads run in the background."
        case .discover: "Find popular source recordings for your top Spotify artists, then preview and approve."
        case .activity: "See what Needle saved locally and what Spotify has confirmed."
        case .library: "Inspect and repair recording details and artwork without downloading again."
        }
    }

    private var sections: [GuideSection] {
        switch destination {
        case .addMusic: addMusicSections
        case .reviewQueue: reviewQueueSections
        case .discover: discoverySections
        case .activity: activitySections
        case .library: librarySections
        }
    }

    private var discoverySections: [GuideSection] { [
        GuideSection("Connect the companion", "Open Spotify and enable Needle’s Spicetify companion from Spotify → Spotify setup. Spotify → Sync top artists reads your top 20 artists over approximately six months. Authentication stays inside Spotify; Needle receives artist and catalog metadata only.", linkTitle: "Get Spicetify", linkURL: "https://spicetify.app/"),
        GuideSection("Choose artists", "Open Choose artists, select up to five, and choose Find recordings. Needle searches its configured sources, sorts the returned uploads by reported plays/views, and skips recordings already saved in your Library. These are popular uploads among the search results, not a complete ranking of every song."),
        GuideSection("Understand catalog checks", "An exact artist/title match is shown as Found on Spotify and appears under All recordings. No exact match on Spotify means this search did not return an exact match; alternate names, regional availability, and version details can affect the result. Spotify availability unknown means the lookup failed, never that the song is absent. Use Retry check after fixing the connection."),
        GuideSection("Preview and approve", "Choose Preview & review to place the exact source in Review Queue. Listen, scrub past an intro, and check the editable artist/title hints before choosing Approve & download. Discovery never approves or downloads a recording automatically."),
        GuideSection("Return later", "Synced artists and discovery results are saved locally. Stop ends a discovery search; completed results stay available. Sync again when you want to refresh your favorite artists."),
    ] }

    private var addMusicSections: [GuideSection] { [
        GuideSection("Find a recording", "Type the artist and song title, then choose Find recordings. You can add an album hint or paste a specific source link when you have one. Needle searches for possible uploads and explains why each one ranked where it did."),
        GuideSection("Check the important details", "Read the title and uploader carefully. The bitrate is the source audio quality Needle can download, and views show how established the upload is. Neither number proves that the recording is correct, so also check duration, version words such as remix or live, and the match warnings."),
        GuideSection("Listen before saving", "Choose Preview recording to hear the candidate inside Needle. The player covers the whole track: drag the scrubber, use the skip-intro button, or move back and forward 10 seconds. The Keep position when switching sources toggle controls whether the current timestamp carries across candidates. Preview positions last while you review this session; queue items and candidates are saved for later."),
        GuideSection("Save safely", "When you are confident, choose Save recording. Needle downloads the exact source you approved, writes the requested artist/title metadata, and keeps the local file even if Spotify is unavailable. For MP3 files, you can also choose the Spotify playlist before saving."),
        GuideSection("When a match looks wrong", "Do not save it. Try another candidate, add an album hint, or refine the artist/title. Needle keeps rejected and uncertain candidates visible so you can see why they were excluded."),
    ] }

    private var reviewQueueSections: [GuideSection] { [
        GuideSection("Drop source links", "Drag a link from your browser onto any Needle tab. Needle opens Review Queue, reads the source details, and finds candidates automatically. Check the detected artist and title before approving; use Edit request to correct them. You can drop multiple links together; duplicates in the drop are skipped. Dropping a link does not approve a download."),
        GuideSection("Add a list", "Choose Paste a list and enter one source link or one Artist — Title per line. You can paste up to 100 lines. A link is only a starting hint: check the artist and title Needle displays before searching."),
        GuideSection("Review one item at a time", "Select an item on the left. Edit the artist, title, or source link when needed, then choose Find recordings. Review the same candidate details as Add Music: title, uploader, duration, bitrate, view count, warnings, and the full-track preview."),
        GuideSection("Approve and keep going", "Choose Approve & download only after listening and checking the candidate. You can select another queue item immediately; up to two approved downloads run at once in the background. Each download uses the exact candidate you approved."),
        GuideSection("Spotify delivery", "For an MP3 item, turn on Add to [playlist] in Spotify after saving. The local file is saved first. Spotify delivery can take longer while Spotify, Spicetify, and the Needle companion are waking up; the Activity tab shows the named playlist and lets you retry or open it after confirmation.", linkTitle: "Get Spicetify", linkURL: "https://spicetify.app/"),
        GuideSection("Pause or return later", "Cancel or skip an item from its detail view. Queue state, candidates, and approvals are saved automatically. Preview positions last for the current review session. Restarting Needle does not silently resume downloads; open the queue and choose what to do."),
    ] }

    private var activitySections: [GuideSection] { [
        GuideSection("Read the status", "Activity separates the local save from Spotify delivery. Saved to your computer means the audio file is complete. Waiting for Spotify names the playlist Needle is trying to reach. Added to Spotify playlist appears only after the companion confirms the insertion."),
        GuideSection("Find the file", "Open File details to see the exact path, or choose Show in Finder. Your music remains on the computer even when Spotify is closed, slow, or not configured."),
        GuideSection("Retry Spotify", "If Spotify delivery failed or is still pending, open Spotify with Local Files enabled and make sure Spicetify and the Needle companion are installed and running. Choose Add to Spotify or Check Spotify on that row. Needle keeps the existing local file while it retries delivery."),
        GuideSection("Confirm the playlist", "The activity row names the playlist used for that track. After confirmation, Open playlist takes you to the playlist in Spotify when a playlist link is available. Spotify confirmation means the insertion was accepted; check playback in Spotify if you need to verify the file itself."),
    ] }

    private var librarySections: [GuideSection] { [
        GuideSection("Browse your collection", "Library scans your Needle music folder when you open this tab, including recordings saved through the CLI or before the desktop app. Choose Refresh after adding files outside Needle. Use the filter to find an artist, song, or album, and Open folder to view the underlying files in Finder. Scanning reads embedded tags and artwork without changing your audio files; backup and temporary files are skipped."),
        GuideSection("Repair a recording", "Choose Repair on a track to inspect the tags currently embedded in the file. You can change artist, title, and album. Use Remove album when an incorrect or unknown album should be cleared explicitly."),
        GuideSection("Fix artwork", "Choose a local image file or find artwork from the approved source, then preview it before applying. Needle embeds the image in the existing audio file and refreshes the Library thumbnail after the repair."),
        GuideSection("Use metadata suggestions carefully", "Find metadata suggestions uses authoritative lookup data to propose artist, title, and album values. Preview the changes first and choose Use metadata before applying. Variant warnings call out remix, edit, live, or similar words that you should preserve."),
        GuideSection("Backups and Spotify", "Every repair creates a backup beside the original file before the change is written. Choose Reveal backup after a repair if you need the safety copy. Repairs change the local file and its tags; Spotify may need Local Files refreshed before it notices the updated artwork or metadata."),
    ] }
}

private struct GuideSection: Identifiable {
    let id = UUID()
    let title: String
    let body: String
    let linkTitle: String?
    let linkURL: URL?

    init(_ title: String, _ body: String) {
        self.init(title, body, linkTitle: nil, linkURL: nil)
    }

    init(_ title: String, _ body: String, linkTitle: String, linkURL: String) {
        self.init(title, body, linkTitle: linkTitle, linkURL: URL(string: linkURL))
    }

    private init(_ title: String, _ body: String, linkTitle: String?, linkURL: URL?) {
        self.title = title
        self.body = body
        self.linkTitle = linkTitle
        self.linkURL = linkURL
    }
}

private struct GuideSectionView: View {
    let section: GuideSection

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(section.title).font(.headline)
            Text(section.body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let linkTitle = section.linkTitle, let linkURL = section.linkURL {
                Link(linkTitle, destination: linkURL)
                    .font(.callout.weight(.medium))
            }
        }
    }
}
