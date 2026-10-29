import CryptoKit
import Foundation
import ImageIO

actor AlbumArtworkCache {
    static let shared = AlbumArtworkCache()
    private static let maximumImageBytes = 20 * 1_024 * 1_024
    private let directory: URL
    private let loader: @Sendable (URL) async throws -> Data
    private var requests: [URL: Task<Data?, Never>] = [:]

    init(directory: URL? = nil, loader: @escaping @Sendable (URL) async throws -> Data = AlbumArtworkCache.download) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.tege.Needle/AlbumArtwork", isDirectory: true)
        self.loader = loader
    }

    func data(for url: URL) async -> Data? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        let path = cacheURL(for: url)
        if let cached = try? Data(contentsOf: path, options: .mappedIfSafe), Self.validImage(cached) {
            return cached
        }
        if let request = requests[url] { return await request.value }
        let loader = loader
        let request = Task<Data?, Never> {
            guard let data = try? await loader(url), Self.validImage(data) else { return nil }
            return data
        }
        requests[url] = request
        let data = await request.value
        requests[url] = nil
        if let data {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: path, options: .atomic)
            pruneCache(keeping: path)
        }
        return data
    }

    private func cacheURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest)
    }

    private func pruneCache(keeping current: URL) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles) else { return }
        let entries = files.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var bytes = entries.reduce(0) { $0 + $1.1 }
        var count = entries.count
        for (url, size, _) in entries where url != current {
            guard bytes > 64 * 1_024 * 1_024 || count > 256 else { break }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                bytes -= size
                count -= 1
            }
        }
    }

    private static func validImage(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = values[kCGImagePropertyPixelWidth] as? Int,
              let height = values[kCGImagePropertyPixelHeight] as? Int else { return false }
        return width > 0 && height > 0 && width <= 8_192 && height <= 8_192 && width * height <= 32_000_000
    }

    private static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
              response.expectedContentLength <= maximumImageBytes else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumImageBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }
}
