package com.brianellissound.songitude.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import com.brianellissound.songitude.model.CoordinateOffset
import com.brianellissound.songitude.model.DialogueColors
import com.brianellissound.songitude.model.DialogueState
import com.brianellissound.songitude.model.LatLngD
import com.brianellissound.songitude.model.MapLabel
import com.brianellissound.songitude.model.PlaybackMode
import com.brianellissound.songitude.model.ShapeType
import com.brianellissound.songitude.model.SoundShape
import com.brianellissound.songitude.model.SuggestedRoute
import com.brianellissound.songitude.model.parseHexColor
import com.google.android.gms.maps.model.LatLng
import com.google.maps.android.compose.Circle
import com.google.maps.android.compose.Polygon
import com.google.maps.android.compose.Polyline

/**
 * Draws a walk's areas, routes and labels over the basemap.
 *
 * The styling rules are lifted from ios/.../MapOverlayView.swift so a walk looks the same on both
 * platforms: a dialogue area is coloured by its playback state, everything else by its own colour
 * with a brighter fill and thicker stroke while it is sounding.
 */

/** Stroke colour, fill alpha and stroke width for a shape in its current state. */
private fun styleFor(
    shape: SoundShape,
    sounding: Boolean,
    dialogueStates: Map<String, DialogueState>,
    dialogueColors: DialogueColors,
): Triple<Int, Float, Float> {
    if (shape.mode == PlaybackMode.DIALOGUE) {
        val st = dialogueStates[shape.id] ?: DialogueState.UNPLAYED
        return Triple(
            parseHexColor(dialogueColors.hexFor(st)),
            st.fillOpacity,
            if (st == DialogueState.PLAYING) 3f else 2f,
        )
    }
    return Triple(
        parseHexColor(shape.color),
        if (sounding) 0.55f else 0.25f,
        if (sounding) 3f else 2f,
    )
}

private fun Int.withAlpha(a: Float): Color =
    Color(this).copy(alpha = a.coerceIn(0f, 1f))

private fun LatLngD.toMaps() = LatLng(lat, lng)

/**
 * The "fuzzy" display style: no outline, and an edge that fades out across a band of this fraction
 * of the shape's own size. MapKit gets this from a radial gradient; the Maps SDK has no gradient
 * fill, so it is approximated with concentric bands — visually the same soft edge, at the cost of a
 * few more overlays.
 */
private object FuzzyStyle {
    const val SPREAD = 0.08
    const val STEPS = 8
}

@Composable
fun SoundShapeOverlays(
    shapes: List<SoundShape>,
    offset: CoordinateOffset,
    soundingIds: Set<String>,
    dialogueStates: Map<String, DialogueState>,
    dialogueColors: DialogueColors,
    fuzzy: Boolean,
) {
    for (shape in shapes) {
        // A hidden area sounds normally but is never drawn for a listener.
        if (shape.hidden) continue
        val (colorInt, alpha, width) = styleFor(shape, soundingIds.contains(shape.id), dialogueStates, dialogueColors)

        when (shape.type) {
            ShapeType.CIRCLE -> {
                val c = shape.centerCoord ?: continue
                val r = shape.radius ?: continue
                val center = offset.apply(c).toMaps()
                if (fuzzy) {
                    // Solid core, then bands stepping down to transparent at the rim.
                    val inner = r * (1 - FuzzyStyle.SPREAD * FuzzyStyle.STEPS / 2.0)
                    Circle(
                        center = center,
                        radius = maxOf(0.0, inner),
                        fillColor = colorInt.withAlpha(alpha),
                        strokeWidth = 0f,
                        strokeColor = Color.Transparent,
                    )
                    for (i in 1..FuzzyStyle.STEPS) {
                        val f = i.toDouble() / FuzzyStyle.STEPS
                        Circle(
                            center = center,
                            radius = inner + (r - inner) * f,
                            fillColor = colorInt.withAlpha(alpha / FuzzyStyle.STEPS),
                            strokeWidth = 0f,
                            strokeColor = Color.Transparent,
                        )
                    }
                } else {
                    Circle(
                        center = center,
                        radius = r,
                        fillColor = colorInt.withAlpha(alpha),
                        strokeColor = Color(colorInt),
                        strokeWidth = width * 2,   // Maps strokes in px; iOS in points
                    )
                }
            }
            ShapeType.POLYGON -> {
                val ring = shape.ringCoords.map { offset.apply(it).toMaps() }
                if (ring.size < 3) continue
                if (fuzzy) {
                    // Bands scaled toward the centroid stand in for the feather.
                    val cx = ring.sumOf { it.latitude } / ring.size
                    val cy = ring.sumOf { it.longitude } / ring.size
                    for (i in 0..FuzzyStyle.STEPS) {
                        val scale = 1.0 - FuzzyStyle.SPREAD * (i.toDouble() / FuzzyStyle.STEPS)
                        val band = ring.map {
                            LatLng(cx + (it.latitude - cx) * scale, cy + (it.longitude - cy) * scale)
                        }
                        Polygon(
                            points = band,
                            fillColor = colorInt.withAlpha(alpha / (FuzzyStyle.STEPS + 1)),
                            strokeWidth = 0f,
                            strokeColor = Color.Transparent,
                        )
                    }
                } else {
                    Polygon(
                        points = ring,
                        fillColor = colorInt.withAlpha(alpha),
                        strokeColor = Color(colorInt),
                        strokeWidth = width * 2,
                    )
                }
            }
        }
    }
}

/** Suggested routes: a plain stroke, no fill, round cap and join so bends stay smooth. */
@Composable
fun RouteOverlays(routes: List<SuggestedRoute>, offset: CoordinateOffset) {
    for (route in routes) {
        val pts = route.coords.map { offset.apply(it).toMaps() }
        if (pts.size < 2) continue
        Polyline(
            points = pts,
            color = parseHexColor(route.color).withAlpha(0.9f),
            width = (route.width * 2).toFloat(),
            jointType = com.google.android.gms.maps.model.JointType.ROUND,
            startCap = com.google.android.gms.maps.model.RoundCap(),
            endCap = com.google.android.gms.maps.model.RoundCap(),
        )
    }
}

/** A label is purely visual — a caption on a plate, or a small image, pinned to one point. */
data class DrawableLabel(val label: MapLabel, val position: LatLng)

fun labelPositions(labels: List<MapLabel>, offset: CoordinateOffset): List<DrawableLabel> =
    labels.mapNotNull { l -> l.coord?.let { DrawableLabel(l, offset.apply(it).toMaps()) } }
