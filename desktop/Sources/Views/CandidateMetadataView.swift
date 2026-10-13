import SwiftUI

enum CandidateMetadataFormatting {
    static func bitrate(_ value: UInt32?) -> String {
        guard let value, value > 0 else { return "Unknown" }
        return "\(value) kbps"
    }

    static func views(_ value: UInt64?) -> String {
        guard let value else { return "Unknown" }
        if value >= 1_000_000_000 {
            return compact(value, divisor: 1_000_000_000, suffix: "B")
        }
        if value >= 1_000_000 {
            return compact(value, divisor: 1_000_000, suffix: "M")
        }
        if value >= 1_000 {
            return compact(value, divisor: 1_000, suffix: "K")
        }
        return "\(value)"
    }

    private static func compact(_ value: UInt64, divisor: UInt64, suffix: String) -> String {
        let scaled = Double(value) / Double(divisor)
        let rounded = (scaled * 10).rounded() / 10
        let text = rounded.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
        return "\(text)\(suffix)"
    }
}

/// Small, reusable source facts row for candidate cards and future library views.
struct CandidateMetadataView: View {
    let candidate: Candidate
    @State private var inspected: Candidate?
    @State private var checking = false
    @State private var failure: String?
    @State private var inspector = NeedleCLIService()
    private var facts: Candidate { inspected ?? candidate }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
            Label("Source audio: \(CandidateMetadataFormatting.bitrate(facts.audioBitrateKbps))", systemImage: "waveform")
            Label("\(CandidateMetadataFormatting.views(facts.viewCount)) views", systemImage: "eye")
                .help(facts.viewCount.map { "\($0.formatted()) views reported by the source" } ?? "The source did not report a view count.")
            }
            if facts.audioBitrateKbps == nil {
                Button(checking ? "Checking source quality…" : "Check source quality") { inspect() }
                    .disabled(checking)
            }
            if let failure { Text(failure).foregroundStyle(.orange).lineLimit(2) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("Bitrate is the source audio reported by the provider, before conversion.")
        .accessibilityLabel("Source quality and popularity")
        .accessibilityValue("\(CandidateMetadataFormatting.bitrate(facts.audioBitrateKbps)), \(CandidateMetadataFormatting.views(facts.viewCount)) views")
    }
    private func inspect() {
        checking = true
        failure = nil
        var settings = NeedleSettings()
        settings.noMetadata = true
        Task {
            defer { checking = false }
            switch await inspector.inspectSource(artist: candidate.uploader ?? candidate.provider,
                                                  title: candidate.title, candidate: candidate, settings: settings) {
            case .success(let value):
                inspected = value
                if value.audioBitrateKbps == nil { failure = "Source bitrate is unavailable." }
            case .failure:
                failure = "Source quality could not be checked. You can retry."
            }
        }
    }

}
