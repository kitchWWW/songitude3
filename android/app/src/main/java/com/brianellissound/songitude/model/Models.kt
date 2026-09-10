package com.brianellissound.songitude.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File

/**
 * The bundle format, ported from ios/Songitude/Songitude/Models.swift. Semantics must stay
 * identical across the editor, the web player, iOS and here — see shared/FORMAT.md.
 *
 * Every field is optional with the historical default, because bundles published by older editors
 * must keep playing untouched. That is a hard requirement of the format, not a nicety.
 */

/** Decoder for map.json. `coerceInputValues` makes an unrecognised enum fall back to its default
 *  rather than throwing, which is what keeps a future mode from bricking an old reader. */
val SongitudeJson: Json = Json {
    ignoreUnknownKeys = true
    coerceInputValues = true
    isLenient = true
    explicitNulls = false
}

/** How a sound area behaves when the listener is inside it. */
@Serializable
enum class PlaybackMode {
    /** Loops while inside; fades in and out. Circle loops honour [Falloff]. */
    @SerialName("loop") LOOP,
    /** Plays once to completion on entry; re-arms after exit. No fades. */
    @SerialName("oneshot") ONESHOT,
    /** Plays once ever; one at a time; entering while another plays queues it (FIFO). */
    @SerialName("dialogue") DIALOGUE,
    /** Launches sample-aligned with every other synced clip and runs forever; location only gates
     *  volume. Must stay resident in memory to hold sync. */
    @SerialName("syncedLoop") SYNCED_LOOP,
}

/** Playback state of a dialogue area, which is what colours it on the map. */
enum class DialogueState {
    UNPLAYED, QUEUED, PLAYING, FINISHED;

    /** Fill opacity that gives each state its look (finished is faded and see-through). */
    val fillOpacity: Float
        get() = when (this) {
            UNPLAYED -> 0.25f
            QUEUED -> 0.42f
            PLAYING -> 0.60f
            FINISHED -> 0.08f
        }
}

/** Per-walk palette for the four dialogue states, authored in the editor. A partial object is
 *  tolerated: each key falls back on its own. */
@Serializable
data class DialogueColors(
    val unplayed: String = "#8a63d2",
    val queued: String = "#f5a623",
    val playing: String = "#2ecc71",
    val finished: String = "#ffffff",
) {
    fun hexFor(state: DialogueState): String = when (state) {
        DialogueState.UNPLAYED -> unplayed
        DialogueState.QUEUED -> queued
        DialogueState.PLAYING -> playing
        DialogueState.FINISHED -> finished
    }
}

/**
 * Where a transportable walk starts and which way it faces. When a bundle carries one, the player
 * rigidly moves and rotates the whole walk so this pin lands on the listener, pointing the way they
 * are pointing. Absent means the walk stays where it was authored.
 */
@Serializable
data class WalkAnchor(
    val lat: Double = 0.0,
    val lng: Double = 0.0,
    /** Degrees clockwise from true north. */
    val heading: Double = 0.0,
) {
    val coord: LatLngD get() = LatLngD(lat, lng)
}

@Serializable
enum class ShapeType {
    @SerialName("circle") CIRCLE,
    @SerialName("polygon") POLYGON,
}

/** Proximity gain profile for circle loops: gain scales with distance from the centre. */
@Serializable
enum class Falloff {
    @SerialName("none") NONE,
    @SerialName("linear") LINEAR,
    @SerialName("exponential") EXPONENTIAL,
    @SerialName("edge") EDGE;

    /** [r] is distance/radius in 0..1. Returns a 0..1 multiplier. */
    fun level(r: Double): Double {
        val x = r.coerceIn(0.0, 1.0)
        return when (this) {
            NONE -> 1.0
            LINEAR -> 1 - x
            EXPONENTIAL -> (1 - x) * (1 - x)
            EDGE -> if (x <= 0.5) 1.0 else maxOf(0.0, 2 * (1 - x))
        }
    }
}

/** A plain lat/lng pair. Kept separate from Maps' LatLng so the model layer stays free of the
 *  Google Maps dependency and can be unit-tested without it. */
data class LatLngD(val lat: Double, val lng: Double)

/** One drawn area on the map with an associated sound. */
@Serializable
data class SoundShape(
    val id: String = "",
    val name: String = "Area",
    val type: ShapeType = ShapeType.CIRCLE,
    val color: String = "#5b8cff",
    // circle
    val center: List<Double>? = null,
    val radius: Double? = null,
    // polygon
    val points: List<List<Double>>? = null,

    val audioFile: String? = null,
    val mode: PlaybackMode = PlaybackMode.LOOP,
    val gain: Double = 1.0,
    val fadeIn: Double = 2.0,
    val fadeOut: Double = 3.0,
    /** Loop mode only: "simple" | "crossfade". Absent means "simple". */
    val loopMode: String = "simple",
    /** Seconds of overlap for a crossfade loop. */
    val crossfade: Double = 1.0,
    val falloff: Falloff = Falloff.NONE,
    /** Standing inside a soloed area ducks every non-soloed area the listener is also inside. */
    val solo: Boolean = false,
    /** Sounds normally but is never drawn for a listener. */
    val hidden: Boolean = false,
) {
    val centerCoord: LatLngD?
        get() = center?.takeIf { it.size == 2 }?.let { LatLngD(it[0], it[1]) }

    val ringCoords: List<LatLngD>
        get() = (points ?: emptyList()).mapNotNull { if (it.size == 2) LatLngD(it[0], it[1]) else null }

    val isCrossfadeLoop: Boolean get() = mode == PlaybackMode.LOOP && loopMode == "crossfade"
}

/**
 * A drawn suggestion of where to walk. Purely visual: no audio, no containment test, no bearing on
 * playback. Older bundles have none, and nothing is drawn, which is exactly right.
 */
@Serializable
data class SuggestedRoute(
    val id: String = "",
    val name: String = "Route",
    val points: List<List<Double>> = emptyList(),
    val color: String = "#111111",
    /** Stroke width in points. */
    val width: Double = 6.0,
) {
    /** A route needs two points to be a line; anything less simply isn't drawn. */
    val isDrawable: Boolean get() = points.size >= 2
    val coords: List<LatLngD>
        get() = points.mapNotNull { if (it.size == 2) LatLngD(it[0], it[1]) else null }
}

/**
 * A free-standing map marking: a caption on a plate, or a small image, pinned to one point. Purely
 * visual, exactly like a [SuggestedRoute]. Labels replaced the routes' old startLabel/endLabel
 * captions, which were removed outright rather than kept for compatibility.
 */
@Serializable
data class MapLabel(
    val id: String = "",
    val name: String = "Label",
    val point: List<Double> = emptyList(),
    val text: String = "",
    val textColor: String = "#000000",
    /** "#rrggbb", or "none" for bare text with no plate. */
    val bgColor: String = "#ffffff",
    /** Filename under images/ — drawn instead of the text. */
    val image: String? = null,
    /** Text label: font size in points. Image label: width in points. Absent follows the kind. */
    @SerialName("size") val rawSize: Double? = null,
) {
    /** The default follows the kind, matching every other reader: 48pt wide for artwork, 14pt type
     *  for a caption. */
    val size: Double get() = rawSize ?: if (image != null) 48.0 else 14.0

    val coord: LatLngD? get() = point.takeIf { it.size == 2 }?.let { LatLngD(it[0], it[1]) }

    /** Nothing to draw when there is neither artwork nor text. */
    val isDrawable: Boolean get() = coord != null && (image != null || text.isNotEmpty())
    val hasPlate: Boolean get() = !bgColor.equals("none", ignoreCase = true)

    /** `size` is a width for an image label, so it means nothing as a font size — text standing in
     *  for a missing image is drawn at the ordinary default instead. */
    val textSize: Double get() = if (image == null) size else 14.0
}

/** The full map definition (map.json). */
@Serializable
data class SoundMap(
    val version: Int = 1,
    val name: String = "",
    val creator: String? = null,
    val about: String? = null,
    /** Intro-card backdrop. Absent means the app's own background. */
    val introColor: String? = null,
    val albumArt: String? = null,
    /** audio/ filename played once at the start of a walk. */
    val intro: String? = null,
    val introGain: Double? = null,
    /** audio/ filename played when the listener ends the session. */
    val exit: String? = null,
    val exitGain: Double? = null,
    val center: List<Double>? = null,
    val zoom: Double? = null,
    val dialogueColors: DialogueColors? = null,
    /** Present means the walk is transportable; absent means fixed in space. */
    val startAnchor: WalkAnchor? = null,
    /** "classic" | "fuzzy". Absent means "classic", the outlined look every older bundle had. */
    val displayStyle: String? = null,
    /** Which published walk this bundle is. Absent means not published or unknown. */
    val walkId: String? = null,
    val shapes: List<SoundShape> = emptyList(),
    val routes: List<SuggestedRoute>? = null,
    val labels: List<MapLabel>? = null,
) {
    val drawableRoutes: List<SuggestedRoute> get() = (routes ?: emptyList()).filter { it.isDrawable }
    val drawableLabels: List<MapLabel> get() = (labels ?: emptyList()).filter { it.isDrawable }

    val centerCoord: LatLngD
        get() = center?.takeIf { it.size == 2 }?.let { LatLngD(it[0], it[1]) }
            ?: LatLngD(40.7128, -74.006)

    val dialoguePalette: DialogueColors get() = dialogueColors ?: DialogueColors()
    val isFuzzy: Boolean get() = displayStyle == "fuzzy"
}

/** A loadable bundle on disk: a folder holding map.json, audio/, and optional album art. */
data class Experience(
    /** Folder name. */
    val id: String,
    val directory: File,
    val map: SoundMap,
) {
    val displayName: String get() = map.name.ifEmpty { id }
    fun audioFile(file: String): File = File(File(directory, "audio"), file)
    /** Label artwork lives under images/, alongside audio/ in the same unpacked bundle folder. */
    fun imageFile(file: String): File = File(File(directory, "images"), file)
    val albumArtFile: File? get() = map.albumArt?.let { File(directory, it) }
}

/** "#rrggbb" to an ARGB int, falling back to the format's own default blue on anything unparseable. */
fun parseHexColor(hex: String): Int {
    val s = hex.trim().removePrefix("#")
    return if (s.length == 6) {
        s.toLongOrNull(16)?.let { (0xFF000000L or it).toInt() } ?: 0xFF5B8CFF.toInt()
    } else 0xFF5B8CFF.toInt()
}
