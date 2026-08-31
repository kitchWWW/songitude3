import Foundation
import CoreLocation

/// Geometry helpers shared by the audio engine (containment) and the map overlay.
enum GeoUtils {

    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Even-odd ray casting on lat/lng. Matches the editor's `pointInPolygon`.
    static func pointInPolygon(_ p: CLLocationCoordinate2D, ring: [CLLocationCoordinate2D]) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let yi = ring[i].latitude, xi = ring[i].longitude
            let yj = ring[j].latitude, xj = ring[j].longitude
            let intersect = (yi > p.latitude) != (yj > p.latitude) &&
                p.longitude < (xj - xi) * (p.latitude - yi) / (yj - yi + 1e-15) + xi
            if intersect { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Is `coord` inside `shape`, after applying a display/test `offset` to the shape's geometry?
    static func contains(_ shape: SoundShape, coord: CLLocationCoordinate2D, offset: CoordinateOffset) -> Bool {
        switch shape.type {
        case .circle:
            guard let c = shape.centerCoord, let r = shape.radius else { return false }
            return distance(offset.apply(c), coord) <= r
        case .polygon:
            let ring = shape.ringCoords.map { offset.apply($0) }
            return pointInPolygon(coord, ring: ring)
        }
    }
}

/// A lat/lng shift used by the "re-center map over me" debug feature, so a map authored for
/// one city can be tested wherever the user physically is.
/// A rigid move-and-turn of a whole walk: the authored anchor is carried onto the listener and
/// spun so the direction the anchor faced now points where the listener is facing. Distances and
/// angles between shapes are preserved, so the walk plays exactly as composed — just somewhere else.
struct WalkTransposition {
    let from: CLLocationCoordinate2D      // authored anchor
    let to: CLLocationCoordinate2D        // where the listener stands
    let turn: Double                      // radians clockwise, listener heading − anchor heading

    init(anchor: WalkAnchor, listener: CLLocationCoordinate2D, heading: Double) {
        from = anchor.coord
        to = listener
        turn = (heading - anchor.heading) * .pi / 180
    }

    private static let metresPerDegreeLat = 110_540.0
    private static func metresPerDegreeLng(at lat: Double) -> Double {
        111_320.0 * cos(lat * .pi / 180)
    }

    func apply(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        // Local east/north offset from the anchor, in metres.
        let east = (c.longitude - from.longitude) * Self.metresPerDegreeLng(at: from.latitude)
        let north = (c.latitude - from.latitude) * Self.metresPerDegreeLat
        // Turn the bearing of that offset by `turn` (clockwise from north).
        let cs = cos(turn), sn = sin(turn)
        let east2 = east * cs + north * sn
        let north2 = north * cs - east * sn
        return CLLocationCoordinate2D(
            latitude: to.latitude + north2 / Self.metresPerDegreeLat,
            longitude: to.longitude + east2 / Self.metresPerDegreeLng(at: to.latitude))
    }

    func apply(_ pair: [Double]) -> [Double] {
        guard pair.count == 2 else { return pair }
        let c = apply(CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1]))
        return [c.latitude, c.longitude]
    }
}

extension SoundMap {
    /// A copy of this walk moved and turned onto the listener. Radii are untouched — only positions
    /// move — so every area keeps its authored size and relative bearing.
    func transposed(_ t: WalkTransposition) -> SoundMap {
        var copy = self
        if let c = center { copy.center = t.apply(c) }
        copy.shapes = shapes.map { shape in
            var s = shape
            if let c = s.center { s.center = t.apply(c) }
            if let pts = s.points { s.points = pts.map(t.apply) }
            return s
        }
        // Routes travel with the walk too — a suggested path left behind where the walk was
        // authored would point the listener at nothing.
        copy.routes = routes?.map { route in
            var r = route
            r.points = r.points.map(t.apply)
            return r
        }
        return copy
    }
}

struct CoordinateOffset: Equatable {
    var dLat: Double = 0
    var dLng: Double = 0

    static let none = CoordinateOffset()

    func apply(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: c.latitude + dLat, longitude: c.longitude + dLng)
    }

    /// Offset that moves `mapCenter` on top of `userLocation`.
    static func recentering(mapCenter: CLLocationCoordinate2D, onto userLocation: CLLocationCoordinate2D) -> CoordinateOffset {
        CoordinateOffset(dLat: userLocation.latitude - mapCenter.latitude,
                         dLng: userLocation.longitude - mapCenter.longitude)
    }
}
