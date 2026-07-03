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
