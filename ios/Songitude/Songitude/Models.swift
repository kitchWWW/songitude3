import Foundation
import CoreLocation
import SwiftUI

/// How a sound area behaves when the listener is inside it.
/// Semantics are identical to the web editor's preview (see ../shared/FORMAT.md).
enum PlaybackMode: String, Codable {
    case loop        // loops while inside; fades in/out
    case oneshot     // plays once to completion on entry; no fades
    case dialogue    // like oneshot, but ducks out when another dialogue starts
    case syncedLoop  // starts with playback and loops forever in sample-lock with all other
                     // synced loops; location only gates its volume (silent, still running, when outside)
}

enum ShapeType: String, Codable {
    case circle
    case polygon
}

/// One drawn area on the map with an associated sound.
struct SoundShape: Codable, Identifiable {
    let id: String
    let name: String
    let type: ShapeType
    let color: String            // "#rrggbb"

    // circle
    let center: [Double]?        // [lat, lng]
    let radius: Double?          // meters

    // polygon
    let points: [[Double]]?      // [[lat, lng], ...]

    let audioFile: String?
    let mode: PlaybackMode
    let gain: Double
    let fadeIn: Double
    let fadeOut: Double
    let falloff: Falloff        // circle loops: proximity gain toward the center

    enum CodingKeys: String, CodingKey {
        case id, name, type, color, center, radius, points, audioFile, mode, gain, fadeIn, fadeOut, falloff
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Area"
        type = try c.decode(ShapeType.self, forKey: .type)
        color = (try? c.decode(String.self, forKey: .color)) ?? "#5b8cff"
        center = try? c.decode([Double].self, forKey: .center)
        radius = try? c.decode(Double.self, forKey: .radius)
        points = try? c.decode([[Double]].self, forKey: .points)
        audioFile = try? c.decode(String.self, forKey: .audioFile)
        mode = (try? c.decode(PlaybackMode.self, forKey: .mode)) ?? .loop
        gain = (try? c.decode(Double.self, forKey: .gain)) ?? 1.0
        fadeIn = (try? c.decode(Double.self, forKey: .fadeIn)) ?? 2.0
        fadeOut = (try? c.decode(Double.self, forKey: .fadeOut)) ?? 3.0
        falloff = (try? c.decode(Falloff.self, forKey: .falloff)) ?? .none
    }
}

/// Proximity gain profile for circle loops: the clip's gain scales by how far the listener is
/// from the circle's center (1 at the center → 0 at the edge). Mirrors the editor.
enum Falloff: String, Codable {
    case none          // whole circle at full gain (binary in/out)
    case linear        // 1 - r
    case exponential   // (1 - r)^2
    case edge          // flat 1 from center to 0.5r, linear drop 0.5r → edge

    /// `r` is distance/radius in [0, 1]. Returns a 0..1 multiplier.
    func level(_ r: Double) -> Double {
        let x = min(max(r, 0), 1)
        switch self {
        case .none:        return 1
        case .linear:      return 1 - x
        case .exponential: return (1 - x) * (1 - x)
        case .edge:        return x <= 0.5 ? 1 : max(0, 2 * (1 - x))
        }
    }
}

extension SoundShape {
    var centerCoord: CLLocationCoordinate2D? {
        guard let c = center, c.count == 2 else { return nil }
        return CLLocationCoordinate2D(latitude: c[0], longitude: c[1])
    }
    var ringCoords: [CLLocationCoordinate2D] {
        (points ?? []).compactMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
    }
    var swiftUIColor: Color { Color(hex: color) }
}

/// The full map definition (`map.json`).
struct SoundMap: Codable {
    let version: Int
    let name: String
    let albumArt: String?
    let center: [Double]?
    let zoom: Double?
    let shapes: [SoundShape]

    var centerCoord: CLLocationCoordinate2D {
        if let c = center, c.count == 2 { return CLLocationCoordinate2D(latitude: c[0], longitude: c[1]) }
        return CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.006)
    }
}

/// A loadable bundle on disk: a folder containing `map.json`, `audio/`, and optional album art.
struct Experience: Identifiable {
    let id: String              // folder name
    let directory: URL
    let map: SoundMap

    var displayName: String { map.name.isEmpty ? id : map.name }
    func audioURL(for file: String) -> URL { directory.appendingPathComponent("audio").appendingPathComponent(file) }
    var albumArtURL: URL? {
        guard let a = map.albumArt else { return nil }
        return directory.appendingPathComponent(a)
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b: Double
        if s.count == 6 {
            r = Double((v >> 16) & 0xff) / 255.0
            g = Double((v >> 8) & 0xff) / 255.0
            b = Double(v & 0xff) / 255.0
        } else { r = 0.36; g = 0.55; b = 1.0 }
        self = Color(red: r, green: g, blue: b)
    }
}
