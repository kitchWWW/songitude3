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
    let base: String        // https://…/walks/<id>
    let mapUrl: String      // https://…/walks/<id>/map.json

    var centerCoord: CLLocationCoordinate2D? {
        guard let c = center, c.count == 2 else { return nil }
        return CLLocationCoordinate2D(latitude: c[0], longitude: c[1])
    }
    var creatorText: String { (creator?.isEmpty == false) ? creator! : "" }
}

struct WalkManifest: Codable { let version: Int; let walks: [RemoteWalk] }

/// Fetches the public catalog and keeps it sorted nearest-first using the last-known location
/// (never requests a new fix).
final class RemoteCatalog: ObservableObject {
    @Published private(set) var walks: [RemoteWalk] = []
    @Published private(set) var loading = false
    @Published var error: String?

    static let manifestURL = URL(string: "https://songitude-walks.s3.amazonaws.com/walks/manifest.json")!

    func refresh(near: CLLocationCoordinate2D?) {
        loading = true
        var req = URLRequest(url: Self.manifestURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            DispatchQueue.main.async {
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
        FileManager.default.fileExists(atPath: cacheDir(for: id).appendingPathComponent("map.json").path)
    }

    /// Loads an already-downloaded walk from cache (nil if not fully present).
    static func cachedExperience(_ id: String) -> Experience? {
        let dir = cacheDir(for: id)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("map.json")),
              let map = try? JSONDecoder().decode(SoundMap.self, from: data) else { return nil }
        return Experience(id: id, directory: dir, map: map)
    }

    /// Download map.json + all referenced audio + album art. progress in 0...1 on the main queue.
    static func download(_ walk: RemoteWalk,
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

                var rels = Set(map.shapes.compactMap { $0.audioFile }.map { "audio/\($0)" })
                if let art = map.albumArt, !art.isEmpty { rels.insert(art) }
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
