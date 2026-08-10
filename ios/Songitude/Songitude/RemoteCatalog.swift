import Foundation
import CoreLocation

/// One published walk as listed in walks/manifest.json.
struct RemoteWalk: Identifiable, Codable {
    let id: String
    let name: String
    let creator: String?
    let about: String?
    let center: [Double]?
    let zoom: Double?
    let shapeCount: Int?
    let sizeBytes: Int?
    let artistId: String?   // absent on walks published before artist pages existed
    let artUrl: String?     // album art, when the bundle shipped one
    let updatedAt: String?  // revision stamp; a cached copy older than this is stale
    let base: String        // https://…/walks/<id>
    let mapUrl: String      // https://…/walks/<id>/map.json

    var centerCoord: CLLocationCoordinate2D? {
        guard let c = center, c.count == 2 else { return nil }
        return CLLocationCoordinate2D(latitude: c[0], longitude: c[1])
    }
    var creatorText: String { (creator?.isEmpty == false) ? creator! : "" }
}

struct WalkManifest: Codable { let version: Int; let walks: [RemoteWalk] }

/// An artist's public page, written by the editor and served from artists/<id>.json.
struct ArtistProfile: Codable {
    let id: String
    let name: String?
    let bio: String?          // markdown source
    let bgColor: String?      // "#rrggbb"

    var displayName: String { (name?.isEmpty == false) ? name! : "Unknown artist" }
}

/// Fetches artist profiles on demand and keeps them in memory for the session. Profiles are tiny
/// and live outside the manifest, so an edited bio shows up without republishing any walk.
/// Main-queue confined, like RemoteCatalog: `load` is called from views and publishes back on main.
final class ArtistStore: ObservableObject {
    @Published private(set) var profiles: [String: ArtistProfile] = [:]
    @Published private(set) var failed: Set<String> = []
    private var inFlight: Set<String> = []

    static func url(for id: String) -> URL? {
        URL(string: "https://songitude-walks.s3.amazonaws.com/artists/\(id).json")
    }

    func profile(_ id: String) -> ArtistProfile? { profiles[id] }

    func load(_ id: String) {
        guard profiles[id] == nil, !inFlight.contains(id), let url = Self.url(for: id) else { return }
        inFlight.insert(id)
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            let decoded = data.flatMap { try? JSONDecoder().decode(ArtistProfile.self, from: $0) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.inFlight.remove(id)
                if let p = decoded { self.profiles[id] = p } else { self.failed.insert(id) }
            }
        }.resume()
    }
}

/// Fetches the public catalog and keeps it sorted nearest-first using the last-known location
/// (never requests a new fix).
final class RemoteCatalog: ObservableObject {
    @Published private(set) var walks: [RemoteWalk] = []
    @Published private(set) var loading = false
    @Published var error: String?

    static let manifestURL = URL(string: "https://songitude-walks.s3.amazonaws.com/walks/manifest.json")!

    /// `completion` fires on the main queue once the catalog has settled (success or failure), so
    /// pull-to-refresh can hold its spinner for the real duration of the fetch.
    func refresh(near: CLLocationCoordinate2D?, completion: (() -> Void)? = nil) {
        loading = true
        var req = URLRequest(url: Self.manifestURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            DispatchQueue.main.async {
                defer { completion?() }
                guard let self = self else { return }
                self.loading = false
                guard let data = data, let m = try? JSONDecoder().decode(WalkManifest.self, from: data) else {
                    self.error = err?.localizedDescription ?? "Couldn't load the catalog."
                    return
                }
                self.error = nil
                self.walks = Self.sorted(m.walks, near: near)
            }
        }.resume()
    }

    /// Re-sort the current list against a (possibly newly-available) location.
    func resort(near: CLLocationCoordinate2D?) { walks = Self.sorted(walks, near: near) }

    private static func sorted(_ walks: [RemoteWalk], near: CLLocationCoordinate2D?) -> [RemoteWalk] {
        guard let here = near else {
            return walks.sorted { ($0.name).localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        let me = CLLocation(latitude: here.latitude, longitude: here.longitude)
        return walks.sorted { a, b in
            let da = a.centerCoord.map { me.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) } ?? .greatestFiniteMagnitude
            let db = b.centerCoord.map { me.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) } ?? .greatestFiniteMagnitude
            return da < db
        }
    }
}

/// Downloads a published walk's files into a local cache directory and returns a local Experience
/// (identical in shape to a bundled one, so the audio engine needs no changes).
enum WalkDownloader {
    static func cacheDir(for id: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("walks/\(id)", isDirectory: true)
    }
    static func isDownloaded(_ id: String) -> Bool {
        // A ".complete" marker is written only after every file has downloaded.
        FileManager.default.fileExists(atPath: cacheDir(for: id).appendingPathComponent(".complete").path)
    }
    private static func versionURL(_ id: String) -> URL {
        cacheDir(for: id).appendingPathComponent(".version")
    }
    private static func cachedVersion(_ id: String) -> String? {
        try? String(contentsOf: versionURL(id), encoding: .utf8)
    }

    /// A cached walk is only safe to open as-is when it matches the catalog's current revision.
    /// Republishing keeps the walk's id, so without this check an edited title, description or
    /// intro colour would never reach a device that had already downloaded the walk.
    static func isUpToDate(_ walk: RemoteWalk) -> Bool {
        isDownloaded(walk.id) && cachedVersion(walk.id) == (walk.updatedAt ?? "")
    }

    static func deleteCache(_ id: String) {
        try? FileManager.default.removeItem(at: cacheDir(for: id))
    }
    /// Every walk currently complete on disk.
    static func downloadedIds() -> Set<String> {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("walks", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: root,
                                                                    includingPropertiesForKeys: nil,
                                                                    options: [.skipsHiddenFiles])) ?? []
        return Set(entries.map(\.lastPathComponent).filter(isDownloaded))
    }

    /// Drop every downloaded walk (used by Settings → Advanced → Reset app).
    static func deleteAllCaches() {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("walks", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
    }

    /// Loads an already-downloaded walk from cache (nil if not fully present).
    static func cachedExperience(_ id: String) -> Experience? {
        let dir = cacheDir(for: id)
        guard isDownloaded(id),
              let data = try? Data(contentsOf: dir.appendingPathComponent("map.json")),
              let map = try? JSONDecoder().decode(SoundMap.self, from: data) else { return nil }
        return Experience(id: id, directory: dir, map: map)
    }

    /// Download map.json + all referenced audio + album art. progress in 0...1 on the main queue.
    /// `mapReady` fires as soon as map.json is parsed — long before the audio arrives — so the UI
    /// can show the right walk immediately instead of sitting on the previous one.
    static func download(_ walk: RemoteWalk,
                         mapReady: @escaping (SoundMap) -> Void = { _ in },
                         progress: @escaping (Double) -> Void,
                         completion: @escaping (Result<Experience, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let dir = cacheDir(for: walk.id)
                try FileManager.default.createDirectory(at: dir.appendingPathComponent("audio"),
                                                        withIntermediateDirectories: true)
                let mapData = try fetch(walk.mapUrl)
                try mapData.write(to: dir.appendingPathComponent("map.json"))
                let map = try JSONDecoder().decode(SoundMap.self, from: mapData)
                DispatchQueue.main.async { mapReady(map) }

                var rels = Set(map.shapes.compactMap { $0.audioFile }.map { "audio/\($0)" })
                if let art = map.albumArt, !art.isEmpty { rels.insert(art) }
                if let intro = map.intro, !intro.isEmpty { rels.insert("audio/\(intro)") }
                if let exit = map.exit, !exit.isEmpty { rels.insert("audio/\(exit)") }
                let list = Array(rels)
                for (i, rel) in list.enumerated() {
                    let dest = dir.appendingPathComponent(rel)
                    if !FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                                withIntermediateDirectories: true)
                        let enc = rel.split(separator: "/").map {
                            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
                        }.joined(separator: "/")
                        let data = try fetch(walk.base + "/" + enc)
                        try data.write(to: dest)
                    }
                    let done = Double(i + 1) / Double(max(1, list.count))
                    DispatchQueue.main.async { progress(done) }
                }
                try? Data().write(to: dir.appendingPathComponent(".complete"))   // mark fully downloaded
                try? (walk.updatedAt ?? "").write(to: versionURL(walk.id), atomically: true, encoding: .utf8)
                let exp = Experience(id: walk.id, directory: dir, map: map)
                DispatchQueue.main.async { completion(.success(exp)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Synchronous download-to-memory (called on a background queue). Streams via URLSession to
    /// avoid holding the whole response before we get it; fine for audio-sized files.
    private static func fetch(_ urlString: String) throws -> Data {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var result: Data?
        var thrown: Error?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { data, resp, err in
            if let err = err { thrown = err }
            else if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                thrown = URLError(.init(rawValue: URLError.badServerResponse.rawValue))
            } else { result = data }
            sem.signal()
        }.resume()
        sem.wait()
        if let thrown = thrown { throw thrown }
        guard let data = result else { throw URLError(.cannotParseResponse) }
        return data
    }
}
