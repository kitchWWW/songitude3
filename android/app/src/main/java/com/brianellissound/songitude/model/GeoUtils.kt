package com.brianellissound.songitude.model

import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Geometry shared by the audio engine (containment) and the map overlay.
 * Ported from ios/Songitude/Songitude/GeoUtils.swift — the containment test in particular must
 * agree with the editor's `pointInPolygon`, or a walk sounds different here than it was composed.
 */
object GeoUtils {

    private const val EARTH_RADIUS_M = 6_371_008.8

    /** Great-circle distance in metres, matching CLLocation.distance(from:) closely enough that a
     *  radius test lands on the same side of the boundary. */
    fun distance(a: LatLngD, b: LatLngD): Double {
        val lat1 = Math.toRadians(a.lat)
        val lat2 = Math.toRadians(b.lat)
        val dLat = lat2 - lat1
        val dLng = Math.toRadians(b.lng - a.lng)
        val h = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * EARTH_RADIUS_M * atan2(sqrt(h), sqrt(1 - h))
    }

    /** Even-odd ray casting on lat/lng. Matches the editor's `pointInPolygon` exactly, including
     *  the 1e-15 guard that keeps a horizontal edge from dividing by zero. */
    fun pointInPolygon(p: LatLngD, ring: List<LatLngD>): Boolean {
        if (ring.size < 3) return false
        var inside = false
        var j = ring.size - 1
        for (i in ring.indices) {
            val yi = ring[i].lat; val xi = ring[i].lng
            val yj = ring[j].lat; val xj = ring[j].lng
            val intersect = (yi > p.lat) != (yj > p.lat) &&
                    p.lng < (xj - xi) * (p.lat - yi) / (yj - yi + 1e-15) + xi
            if (intersect) inside = !inside
            j = i
        }
        return inside
    }

    /** Is [coord] inside [shape], after applying a display/test [offset] to the shape's geometry? */
    fun contains(shape: SoundShape, coord: LatLngD, offset: CoordinateOffset): Boolean =
        when (shape.type) {
            ShapeType.CIRCLE -> {
                val c = shape.centerCoord
                val r = shape.radius
                if (c == null || r == null) false else distance(offset.apply(c), coord) <= r
            }
            ShapeType.POLYGON -> pointInPolygon(coord, shape.ringCoords.map { offset.apply(it) })
        }

    /** How far into a circle the listener is, 0 at the centre and 1 at the edge. Used for falloff. */
    fun normalizedRadius(shape: SoundShape, coord: LatLngD, offset: CoordinateOffset): Double {
        val c = shape.centerCoord ?: return 1.0
        val r = shape.radius ?: return 1.0
        if (r <= 0) return 1.0
        return (distance(offset.apply(c), coord) / r).coerceIn(0.0, 1.0)
    }
}

/**
 * A rigid move-and-turn of a whole walk: the authored anchor is carried onto the listener and spun
 * so the direction the anchor faced now points where the listener is facing. Distances and angles
 * between shapes are preserved, so the walk plays exactly as composed — just somewhere else.
 */
class WalkTransposition(anchor: WalkAnchor, listener: LatLngD, heading: Double) {
    private val from: LatLngD = anchor.coord
    private val to: LatLngD = listener
    /** Radians clockwise: listener heading minus anchor heading. */
    private val turn: Double = (heading - anchor.heading) * Math.PI / 180

    companion object {
        private const val METRES_PER_DEGREE_LAT = 110_540.0
        private fun metresPerDegreeLng(lat: Double) = 111_320.0 * cos(lat * Math.PI / 180)
    }

    fun apply(c: LatLngD): LatLngD {
        // Local east/north offset from the anchor, in metres.
        val east = (c.lng - from.lng) * metresPerDegreeLng(from.lat)
        val north = (c.lat - from.lat) * METRES_PER_DEGREE_LAT
        // Turn the bearing of that offset by `turn` (clockwise from north).
        val cs = cos(turn); val sn = sin(turn)
        val east2 = east * cs + north * sn
        val north2 = north * cs - east * sn
        return LatLngD(
            lat = to.lat + north2 / METRES_PER_DEGREE_LAT,
            lng = to.lng + east2 / metresPerDegreeLng(to.lat),
        )
    }

    fun apply(pair: List<Double>): List<Double> {
        if (pair.size != 2) return pair
        val c = apply(LatLngD(pair[0], pair[1]))
        return listOf(c.lat, c.lng)
    }
}

/**
 * A copy of this walk moved and turned onto the listener. Radii are untouched — only positions
 * move — so every area keeps its authored size and relative bearing.
 *
 * Labels are deliberately left where they were authored, matching iOS. See the note in the Android
 * port README: this looks like an iOS bug, but parity wins until the iOS side changes.
 */
fun SoundMap.transposed(t: WalkTransposition): SoundMap = copy(
    center = center?.let { t.apply(it) },
    shapes = shapes.map { s ->
        s.copy(
            center = s.center?.let { t.apply(it) },
            points = s.points?.map { t.apply(it) },
        )
    },
    // Routes travel with the walk too — a suggested path left behind where the walk was authored
    // would point the listener at nothing.
    routes = routes?.map { r -> r.copy(points = r.points.map { t.apply(it) }) },
)

/**
 * A lat/lng shift used by "re-center map over me", so a walk authored for one city can be tested
 * wherever the user physically is.
 */
data class CoordinateOffset(val dLat: Double = 0.0, val dLng: Double = 0.0) {
    fun apply(c: LatLngD): LatLngD = LatLngD(c.lat + dLat, c.lng + dLng)

    val isZero: Boolean get() = abs(dLat) < 1e-12 && abs(dLng) < 1e-12

    companion object {
        val NONE = CoordinateOffset()

        /** Offset that moves [mapCenter] on top of [userLocation]. */
        fun recentering(mapCenter: LatLngD, onto: LatLngD) =
            CoordinateOffset(onto.lat - mapCenter.lat, onto.lng - mapCenter.lng)
    }
}
