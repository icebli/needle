import Foundation

extension ReviewQueue {
    /// Discovery offers an exact source for human approval. No second source
    /// search or automatic download occurs when opening the review item.
    func addDiscovery(_ recording: DiscoveryRecording, settings: NeedleSettings) {
        if let existing = items.first(where: { $0.sourceURL == recording.candidate.url && $0.state != .skipped }) {
            selectedID = existing.id
            return
        }
        var item = ReviewItem(artist: recording.artist.name, title: recording.title,
                              sourceURL: recording.candidate.url,
                              input: "\(recording.artist.name) — \(recording.title)", settings: settings)
        item.state = .ready
        item.sourceIdentityUncertain = true
        let score = Score(confidence: nil, status: "review", positives: ["Exact source retained from discovery"],
                          warnings: ["Artist and title are source hints. Check recording identity and version before approval.", recording.availability.label], rejects: [])
        item.response = SearchResponse(ok: true, request: RequestEcho(artist: item.artist, title: item.title), metadata: nil,
                                       candidates: [CandidateResult(candidate: recording.candidate, score: score)], error: nil)
        item.detail = "\(recording.availability.label). Artist and title are source hints; listen and check them before approving."
        items.append(item)
        selectedID = item.id
    }
}
