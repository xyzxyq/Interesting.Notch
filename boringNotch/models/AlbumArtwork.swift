import AppKit
import ImageIO

enum AlbumArtwork {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    static func decode(_ data: Data) -> NSImage? {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let image = NSImage(size: NSSize(width: thumbnail.width, height: thumbnail.height))
        image.addRepresentation(NSBitmapImageRep(cgImage: thumbnail))
        return image
    }

    private struct Song: Decodable {
        let trackId: Int?
        let trackName: String?
        let artistName: String?
        let collectionName: String?
        let trackTimeMillis: Double?
        let artworkUrl100: URL?
    }

    static func matchedURL(in data: Data, for state: PlaybackState) throws -> URL? {
        struct Results: Decodable { let results: [Song] }
        let matches = try JSONDecoder().decode(Results.self, from: data).results.filter { song in
            if let id = state.catalogID { return song.trackId == id }
            // Never guess from a search rank: editions, artists and albums must all match.
            return [state.title, state.artist, state.album].allSatisfy { !CompactLyrics.searchKey($0).isEmpty }
                && CompactLyrics.searchKey(song.trackName ?? "") == CompactLyrics.searchKey(state.title)
                && CompactLyrics.searchKey(song.artistName ?? "") == CompactLyrics.searchKey(state.artist)
                && CompactLyrics.searchKey(song.collectionName ?? "") == CompactLyrics.searchKey(state.album)
                && state.duration.isFinite && state.duration > 0
                && abs((song.trackTimeMillis ?? -1) / 1000 - state.duration) <= 3
        }
        let urls = Set(matches.compactMap(\.artworkUrl100).filter {
            $0.scheme == "https" && ($0.host?.hasSuffix(".mzstatic.com") == true)
        })
        return urls.count == 1 ? urls.first : nil
    }

    static func fetch(for state: PlaybackState,
                      transport: Transport = { try await URLSession.shared.data(for: $0) }) async throws -> Data? {
        guard state.bundleIdentifier == "com.apple.Music", !state.title.isEmpty, !state.artist.isEmpty else { return nil }
        guard state.catalogID != nil || (!state.album.isEmpty && state.duration.isFinite && state.duration > 0) else { return nil }
        let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        let countries = chinese ? ["tw", "us"] : [Locale.current.region?.identifier.lowercased() ?? "us", "tw"]
        for (index, country) in countries.enumerated() where index == 0 || country != countries[0] {
            try Task.checkCancellation()
            var components = URLComponents(string: "https://itunes.apple.com/\(state.catalogID == nil ? "search" : "lookup")")!
            components.queryItems = [URLQueryItem(name: "country", value: country),
                URLQueryItem(name: "entity", value: "song"), URLQueryItem(name: "limit", value: "25")]
            if let id = state.catalogID {
                components.queryItems?.append(URLQueryItem(name: "id", value: String(id)))
            } else {
                components.queryItems?.append(URLQueryItem(name: "term", value: "\(state.artist) \(state.title)"))
            }
            let (data, response) = try await transport(URLRequest(url: components.url!, timeoutInterval: 10))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            guard let url = try matchedURL(in: data, for: state) else { continue }
            try Task.checkCancellation()
            let (image, imageResponse) = try await transport(URLRequest(url: url, timeoutInterval: 10))
            guard (imageResponse as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            return image
        }
        return nil
    }
}
