import Foundation
import CoreLocation
import SwiftUI

/// How a sound area behaves when the listener is inside it.
/// Semantics are identical to the web editor's preview (see ../shared/FORMAT.md).
enum PlaybackMode: String, Codable {
    case loop        // loops while inside; fades in/out
    case oneshot     // plays once to completion on entry; no fades
    case dialogue    // plays once ever; if another dialogue is sounding it queues and plays after
    case syncedLoop  // starts with playback and loops forever in sample-lock with all other
                     // synced loops; location only gates its volume (silent, still running, when outside)
}

/// The playback state of a dialogue area, reflected by its color on the map (in the app and editor).
enum DialogueState: String {
    case unplayed    // not yet entered
    case queued      // entered while another dialogue is playing; waiting its turn
    case playing     // sounding right now
    case finished    // has played (won't play again this session)

    /// Fill opacity that gives each state its look (finished is faded + see-through).
    var fillOpacity: CGFloat {
        switch self {
        case .unplayed: return 0.25
        case .queued:   return 0.42
        case .playing:  return 0.60
        case .finished: return 0.08
        }
    }
}

/// Per-walk palette for the four dialogue states (authored in the editor, stored in map.json).
struct DialogueColors: Codable {
    var unplayed: String, queued: String, playing: String, finished: String

    init(unplayed: String = "#8a63d2", queued: String = "#f5a623",
         playing: String = "#2ecc71", finished: String = "#ffffff") {
        self.unplayed = unplayed; self.queued = queued; self.playing = playing; self.finished = finished
    }
    // Tolerate a partial/absent object — fall back to defaults per key.
    init(from decoder: Decoder) throws {
        var d = DialogueColors()
        if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            d.unplayed = (try? c.decode(String.self, forKey: .unplayed)) ?? d.unplayed
            d.queued   = (try? c.decode(String.self, forKey: .queued))   ?? d.queued
            d.playing  = (try? c.decode(String.self, forKey: .playing))  ?? d.playing
            d.finished = (try? c.decode(String.self, forKey: .finished)) ?? d.finished
        }
        self = d
    }

    func hex(for state: DialogueState) -> String {
        switch state {
        case .unplayed: return unplayed
        case .queued:   return queued
        case .playing:  return playing
        case .finished: return finished
        }
    }
}

/// Where a transportable walk starts, and which way it faces there. When a bundle carries one, a
/// player rigidly moves and rotates the whole walk so this pin lands on the listener, pointing the
/// way they are pointing. Absent ⇒ the walk stays where it was authored.
struct WalkAnchor: Codable {
    let lat: Double
    let lng: Double
    let heading: Double          // degrees clockwise from true north

    var coord: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }
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
    var center: [Double]?        // [lat, lng]
    let radius: Double?          // meters

    // polygon
    var points: [[Double]]?      // [[lat, lng], ...]

    let audioFile: String?
    let mode: PlaybackMode
    let gain: Double
    let fadeIn: Double
    let fadeOut: Double
    let loopMode: String        // loop mode only: "simple" | "crossfade" (absent ⇒ "simple")
    let crossfade: Double       // seconds; overlap for crossfade loops
    let falloff: Falloff        // circle loops: proximity gain toward the center
    /// Standing inside a soloed area ducks every non-soloed area the listener is also inside.
    /// Absent in older bundles ⇒ false ⇒ areas simply layer, as they always did.
    let solo: Bool
    /// Sounds normally but is never drawn on the map for a listener. Absent ⇒ false ⇒ drawn.
    let hidden: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, type, color, center, radius, points, audioFile, mode, gain, fadeIn, fadeOut,
             loopMode, crossfade, falloff, solo, hidden
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
        loopMode = (try? c.decode(String.self, forKey: .loopMode)) ?? "simple"
        crossfade = (try? c.decode(Double.self, forKey: .crossfade)) ?? 1.0
        falloff = (try? c.decode(Falloff.self, forKey: .falloff)) ?? .none
        solo = (try? c.decode(Bool.self, forKey: .solo)) ?? false
        hidden = (try? c.decode(Bool.self, forKey: .hidden)) ?? false
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
    var isCrossfadeLoop: Bool { mode == .loop && loopMode == "crossfade" }
}

/// A drawn suggestion of where to walk: an open path with a marker at each end. Purely visual — a
/// route carries no audio, has no containment test, and has no bearing on playback of any kind.
/// Absent in older bundles ⇒ nothing is drawn, which is exactly right. A caption near a route is a
/// `MapLabel`, placed wherever it reads best rather than welded to an endpoint.
struct SuggestedRoute: Codable, Identifiable {
    let id: String
    let name: String
    var points: [[Double]]      // [[lat, lng], ...] in walking order
    let color: String           // "#rrggbb"
    let width: Double           // stroke width in points

    enum CodingKeys: String, CodingKey { case id, name, points, color, width }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        points = (try? c.decode([[Double]].self, forKey: .points)) ?? []
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? c.decode(String.self, forKey: .name)) ?? "Route"
        color = (try? c.decode(String.self, forKey: .color)) ?? "#111111"
        width = (try? c.decode(Double.self, forKey: .width)) ?? 6
    }

    /// A route needs two points to be a line; anything less simply isn't drawn.
    var isDrawable: Bool { points.count >= 2 }
    var coords: [CLLocationCoordinate2D] {
        points.compactMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
    }
}

/// A free-standing map marking: a caption on a plate, or a small image, pinned to one point.
/// Purely visual exactly like a `SuggestedRoute` — no audio, no containment test, no bearing on
/// playback. Absent in older bundles ⇒ nothing is drawn, which is exactly right.
///
/// Labels replaced the routes' old `startLabel`/`endLabel` captions, which could only ever sit on
/// an endpoint. Those were removed outright rather than kept for compatibility.
struct MapLabel: Codable, Identifiable {
    let id: String
    let name: String
    var point: [Double]         // [lat, lng]
    let text: String
    let textColor: String       // "#rrggbb"
    let bgColor: String         // "#rrggbb", or "none" for bare text with no plate
    let image: String?          // filename under images/ ⇒ drawn instead of the text
    let size: Double            // text ⇒ font size in points; image ⇒ width in points

    enum CodingKeys: String, CodingKey { case id, name, point, text, textColor, bgColor, image, size }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        point = (try? c.decode([Double].self, forKey: .point)) ?? []
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? c.decode(String.self, forKey: .name)) ?? "Label"
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        textColor = (try? c.decode(String.self, forKey: .textColor)) ?? "#000000"
        bgColor = (try? c.decode(String.self, forKey: .bgColor)) ?? "#ffffff"
        image = try? c.decode(String.self, forKey: .image)
        // The default follows the kind, matching every other reader: 48pt wide for artwork, 14pt
        // type for a caption.
        size = (try? c.decode(Double.self, forKey: .size)) ?? ((try? c.decode(String.self, forKey: .image)) != nil ? 48 : 14)
    }

    var coord: CLLocationCoordinate2D? {
        point.count == 2 ? CLLocationCoordinate2D(latitude: point[0], longitude: point[1]) : nil
    }
    /// Nothing to draw when there is neither artwork nor text.
    var isDrawable: Bool { coord != nil && (image != nil || !text.isEmpty) }
    var hasPlate: Bool { bgColor.lowercased() != "none" }
    /// `size` is a width for an image label, so it means nothing as a font size — text standing in
    /// for a missing image is drawn at the ordinary default instead.
    var textSize: Double { image == nil ? size : 14 }
}

/// The full map definition (`map.json`).
struct SoundMap: Codable {
    let version: Int
    let name: String
    let creator: String?        // author/composer (absent on very early bundles)
    let about: String?          // description shown on the intro card
    let introColor: String?     // "#rrggbb" backdrop for the intro card (absent ⇒ "#101014")
    let albumArt: String?
    let intro: String?          // audio/ filename played once at the start of a walk
    let introGain: Double?      // 0..1 level for the intro clip (absent ⇒ 1.0)
    let exit: String?           // audio/ filename played when the listener ends the session
    let exitGain: Double?       // 0..1 level for the exit clip (absent ⇒ 1.0)
    var center: [Double]?
    let zoom: Double?
    let dialogueColors: DialogueColors?
    let startAnchor: WalkAnchor?    // present ⇒ the walk is transportable; absent ⇒ fixed in space
    /// How areas are drawn for listeners: "classic" or "fuzzy". Absent ⇒ "classic", the outlined
    /// look every bundle published before this field had.
    let displayStyle: String?
    var shapes: [SoundShape]
    /// Suggested routes drawn over the map. Optional — older bundles have none.
    var routes: [SuggestedRoute]?
    /// Free-standing markings drawn over the map. Optional — older bundles have none.
    var labels: [MapLabel]?

    var drawableRoutes: [SuggestedRoute] { (routes ?? []).filter { $0.isDrawable } }
    var drawableLabels: [MapLabel] { (labels ?? []).filter { $0.isDrawable } }

    var centerCoord: CLLocationCoordinate2D {
        if let c = center, c.count == 2 { return CLLocationCoordinate2D(latitude: c[0], longitude: c[1]) }
        return CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.006)
    }
    var dialoguePalette: DialogueColors { dialogueColors ?? DialogueColors() }
    var isFuzzy: Bool { displayStyle == "fuzzy" }
}

/// A loadable bundle on disk: a folder containing `map.json`, `audio/`, and optional album art.
struct Experience: Identifiable {
    let id: String              // folder name
    let directory: URL
    let map: SoundMap

    var displayName: String { map.name.isEmpty ? id : map.name }
    func audioURL(for file: String) -> URL { directory.appendingPathComponent("audio").appendingPathComponent(file) }
    /// Label artwork lives under images/, alongside audio/ in the same unpacked bundle folder.
    func imageURL(for file: String) -> URL { directory.appendingPathComponent("images").appendingPathComponent(file) }
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
