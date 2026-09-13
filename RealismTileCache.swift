import Foundation

/// Disk cache for every realism-tile fetch (catalog.json, meta.json, ground.json, .obj tiles,
/// textures). First visit to an area pulls from the network like before; every later visit —
/// even after relaunching the app — reads straight off disk, so there's no network wait and
/// no lag re-entering somewhere you've already been.
enum RealismTileCache {
    private static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RealismTiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static func key(for url: URL) -> String {
        var hasher = Hasher()
        hasher.combine(url.absoluteString)
        return String(format: "%016llx", UInt64(bitPattern: Int64(hasher.finalize())))
    }

    /// Fetches `url`, transparently caching to disk. `maxAge` only governs when we bother
    /// re-checking the network (mesh/building/tree tiles are effectively static once built),
    /// and a network failure always falls back to whatever's cached, however old.
    static func data(for url: URL, maxAge: TimeInterval = 6 * 3600) async -> Data? {
        let file = dir.appendingPathComponent(key(for: url))
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < maxAge,
           let cached = try? Data(contentsOf: file) {
            return cached
        }
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            return try? Data(contentsOf: file)
        }
        try? data.write(to: file, options: .atomic)
        return data
    }

    static func clear() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}
