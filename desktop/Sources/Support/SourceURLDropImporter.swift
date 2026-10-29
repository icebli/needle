import Foundation
import UniformTypeIdentifiers

/// Starts loading source links while the drop receiver still has access to the
/// item providers, then delivers only valid HTTP(S) URLs to the main queue.
enum SourceURLDropImporter {
    static let supportedContentTypes = [UTType.url.identifier, UTType.plainText.identifier]
    static let maximumProviders = 50
    static let maximumPayloadBytes = 1_048_576
    static let maximumURLs = 100

    @MainActor
    static func start(providers: [NSItemProvider], completion: @escaping (SourceURLDropResult) -> Void) -> Bool {
        guard !providers.isEmpty else { return false }

        let group = DispatchGroup()
        let providerCount = min(providers.count, maximumProviders)
        let collector = Collector(count: providerCount)

        for (index, provider) in providers.prefix(maximumProviders).enumerated() {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                let loadFallback: @MainActor @Sendable () -> Void = {
                    if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                        Self.loadText(provider, at: index, collector: collector, group: group)
                    } else {
                        group.leave()
                    }
                }
                provider.loadObject(ofClass: NSURL.self) { object, _ in
                    if let url = object as? NSURL, let value = url.absoluteString {
                        if value.utf8.count <= maximumPayloadBytes {
                            collector.set(value, at: index)
                        } else {
                            collector.markOversized()
                        }
                        group.leave()
                    } else {
                        Task { await loadFallback() }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                Self.loadText(provider, at: index, collector: collector, group: group)
            }
        }

        group.notify(queue: .main) {
            var result = parseResult(collector.values)
            result.ignoredProviderCount = providers.count > providerCount ? providers.count - providerCount : 0
            result.oversizedProviderCount = collector.oversizedCount
            completion(result)
        }
        return true
    }

    private static func loadText(_ provider: NSItemProvider, at index: Int, collector: Collector, group: DispatchGroup) {
        provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
            if let data {
                if data.count <= maximumPayloadBytes, let value = String(data: data, encoding: .utf8) {
                    collector.set(value, at: index)
                } else {
                    collector.markOversized()
                }
            }
            group.leave()
        }
    }

    /// Parses browser text drops as one or more links, rejecting local files,
    /// scripts, and other non-source schemes before they reach the queue.
    static func parse(_ values: [String]) -> [String] {
        parseResult(values).accepted
    }

    static func parseResult(_ values: [String]) -> SourceURLDropResult {
        var seen = Set<String>()
        var result = SourceURLDropResult()
        for value in values.flatMap({ $0.split(whereSeparator: { $0.isWhitespace }).map(String.init) }) {
                let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = validatedURL(candidate) else {
                    result.invalidCount += 1
                    continue
                }
                let normalized = url.absoluteString
                guard seen.insert(normalized).inserted else {
                    result.duplicateCount += 1
                    continue
                }
                guard result.accepted.count < maximumURLs else {
                    result.truncatedCount += 1
                    continue
                }
                result.accepted.append(normalized)
        }
        return result
    }

    private static func validatedURL(_ text: String) -> URL? {
        guard let url = URL(string: text),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        return url
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var slots: [String?]
        private(set) var oversizedCount = 0

        init(count: Int) {
            slots = Array(repeating: nil, count: count)
        }

        func set(_ value: String, at index: Int) {
            lock.lock()
            slots[index] = value
            lock.unlock()
        }

        func markOversized() {
            lock.lock()
            oversizedCount += 1
            lock.unlock()
        }

        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return slots.compactMap { $0 }
        }
    }
}

struct SourceURLDropResult: Equatable {
    var accepted: [String] = []
    var duplicateCount = 0
    var invalidCount = 0
    var truncatedCount = 0
    var ignoredProviderCount = 0
    var oversizedProviderCount = 0
}
