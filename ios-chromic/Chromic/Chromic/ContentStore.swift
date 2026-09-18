import Foundation

/// Everything the catalog screens show, available before the network answers.
///
/// Chromic publish rarely, so the app ships a snapshot of the manifest, the artist profile and the
/// artwork (`Seed/`, written by `tools/refresh_seed.py`). Reads go **disk cache, then seed**: the
/// disk copy is whatever the last successful fetch stored, so a returning launch shows the newest
/// content it has seen, and a fresh install shows the release's snapshot. Either way the first
/// frame is complete. Fetches still happen — the callers refresh in the background and `store`
/// the result — but nothing waits for them and nothing shows a spinner over content it has.
///
/// Chromic-only: Songitude's catalog changes too often, and across too many artists, to bake in.
enum ContentStore {
    private static let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("content", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Source URL → file name inside `Seed/`. Loaded once.
    private static let seedIndex: [String: String] = {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "json", subdirectory: "Seed"),
              let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }()

    /// The newest copy we have of `url`: the last fetched one on disk, else the seed's, else nil.
    static func cached(_ url: URL) -> Data? {
        if let d = try? Data(contentsOf: fileURL(for: url)) { return d }
        if let name = seedIndex[url.absoluteString],
           let seed = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Seed") {
            return try? Data(contentsOf: seed)
        }
        return nil
    }

    /// Keep a freshly fetched copy for the next launch. Atomic, so a crash mid-write can't leave a
    /// half file where the seed used to answer.
    static func store(_ data: Data, for url: URL) {
        try? data.write(to: fileURL(for: url), options: .atomic)
    }

    /// One file per URL, named by a stable hash of it (URLs have characters that aren't file-safe,
    /// and S3 keys can be long).
    private static func fileURL(for url: URL) -> URL {
        var h: UInt64 = 0xcbf29ce484222325           // FNV-1a
        for b in url.absoluteString.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return dir.appendingPathComponent(String(h, radix: 16) + "." + (url.pathExtension.isEmpty ? "bin" : url.pathExtension))
    }
}
