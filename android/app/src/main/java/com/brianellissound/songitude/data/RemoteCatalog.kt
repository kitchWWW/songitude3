package com.brianellissound.songitude.data

import android.content.Context
import com.brianellissound.songitude.audio.RenderEngine
import com.brianellissound.songitude.model.Experience
import com.brianellissound.songitude.model.GeoUtils
import com.brianellissound.songitude.model.LatLngD
import com.brianellissound.songitude.model.SongitudeJson
import com.brianellissound.songitude.model.SoundMap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.serialization.Serializable
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/** One published walk as listed in walks/manifest.json. */
@Serializable
data class RemoteWalk(
    val id: String = "",
    val name: String = "",
    val creator: String? = null,
    val about: String? = null,
    val center: List<Double>? = null,
    val zoom: Double? = null,
    val shapeCount: Int? = null,
    val sizeBytes: Long? = null,
    /** Absent on walks published before artist pages existed. */
    val artistId: String? = null,
    val artUrl: String? = null,
    /** Revision stamp; a cached copy older than this is stale. */
    val updatedAt: String? = null,
    /** Carries a startAnchor, so it can be listened to from anywhere. */
    val portable: Boolean? = null,
    val base: String = "",
    val mapUrl: String = "",
) {
    val centerCoord: LatLngD?
        get() = center?.takeIf { it.size == 2 }?.let { LatLngD(it[0], it[1]) }
    val creatorText: String get() = creator?.takeIf { it.isNotEmpty() } ?: ""
}

@Serializable
data class WalkManifest(val version: Int = 1, val walks: List<RemoteWalk> = emptyList())

/** An artist's public page, written by the editor and served from artists/<id>.json. */
@Serializable
data class ArtistProfile(
    val id: String = "",
    val name: String? = null,
    /** Markdown source. */
    val bio: String? = null,
    val bgColor: String? = null,
) {
    val displayName: String get() = name?.takeIf { it.isNotEmpty() } ?: "Unknown artist"
}

object CatalogEndpoints {
    const val ROOT = "https://songitude-walks.s3.amazonaws.com"
    const val MANIFEST = "$ROOT/walks/manifest.json"
    fun artist(id: String) = "$ROOT/artists/$id.json"
}

/** Fetches the public catalog. Sorting is nearest-first using the last-known location; it never
 *  requests a new fix. */
object CatalogService {

    suspend fun fetchManifest(): Result<List<RemoteWalk>> = withContext(Dispatchers.IO) {
        try {
            val body = httpGet(CatalogEndpoints.MANIFEST, noCache = true).decodeToString()
            Result.success(SongitudeJson.decodeFromString<WalkManifest>(body).walks)
        } catch (t: Throwable) {
            Result.failure(t)
        }
    }

    suspend fun fetchArtist(id: String): ArtistProfile? = withContext(Dispatchers.IO) {
        try {
            SongitudeJson.decodeFromString<ArtistProfile>(
                httpGet(CatalogEndpoints.artist(id), noCache = true).decodeToString()
            )
        } catch (t: Throwable) {
            null
        }
    }

    /** Nearest-first when we know where we are, alphabetical when we don't. */
    fun sorted(walks: List<RemoteWalk>, near: LatLngD?): List<RemoteWalk> {
        if (near == null) return walks.sortedBy { it.name.lowercase() }
        return walks.sortedBy { w ->
            w.centerCoord?.let { GeoUtils.distance(near, it) } ?: Double.MAX_VALUE
        }
    }

    /**
     * One GET. [noCache] is for the manifest and artist profiles, which are republished in place and
     * whose stale copies are wrong in ways that matter; a walk's own files are immutable once
     * published, so they are happily cached.
     *
     * Deliberately does NOT call `disconnect()`. That tears down the socket and defeats keep-alive,
     * and a walk can be eighty-odd clips — an extra TCP and TLS handshake each was the difference
     * between this and the iOS downloader on the same wifi. Closing the stream returns the
     * connection to the pool for the next file instead.
     */
    fun httpGet(urlString: String, noCache: Boolean = false): ByteArray {
        val conn = (URL(urlString).openConnection() as HttpURLConnection).apply {
            connectTimeout = 20_000
            readTimeout = 60_000
            setRequestProperty("Accept-Encoding", "gzip")
            if (noCache) setRequestProperty("Cache-Control", "no-cache")
        }
        val code = conn.responseCode
        if (code != 200) {
            conn.errorStream?.use { it.readBytes() }   // drain, so the connection can be reused
            throw IllegalStateException("HTTP $code for $urlString")
        }
        val raw = conn.inputStream.use { it.readBytes() }
        return if (conn.contentEncoding.equals("gzip", ignoreCase = true)) {
            java.util.zip.GZIPInputStream(raw.inputStream()).use { it.readBytes() }
        } else raw
    }
}

/**
 * Downloads a published walk's files into the cache and returns a local [Experience], identical in
 * shape to a bundled one so the audio engine needs no changes.
 */
class WalkDownloader(private val context: Context) {

    private fun walksRoot(): File = File(context.cacheDir, "walks")
    fun cacheDir(id: String): File = File(walksRoot(), id)

    /** A ".complete" marker is written only after every file has downloaded. */
    fun isDownloaded(id: String): Boolean = File(cacheDir(id), ".complete").exists()

    private fun versionFile(id: String) = File(cacheDir(id), ".version")
    private fun cachedVersion(id: String): String? =
        versionFile(id).takeIf { it.exists() }?.readText()

    /** A cached walk is only safe to open as-is when it matches the catalog's current revision.
     *  Republishing keeps the walk's id, so without this an edited title, description or intro
     *  colour would never reach a device that had already downloaded it. */
    fun isUpToDate(walk: RemoteWalk): Boolean =
        isDownloaded(walk.id) && cachedVersion(walk.id) == (walk.updatedAt ?: "")

    /** Deleting a walk also forgets that its intro was heard: re-downloading is a fresh start, and
     *  the one-hour gate exists to survive a resume, not a reinstall. */
    fun deleteCache(id: String, engine: RenderEngine?) {
        cacheDir(id).deleteRecursively()
        engine?.clearIntroGate(id)
        context.getSharedPreferences("songitude", Context.MODE_PRIVATE)
            .edit().remove(RenderEngine.introGateKey(id)).apply()
    }

    fun downloadedIds(): Set<String> =
        (walksRoot().listFiles() ?: emptyArray()).map { it.name }.filter { isDownloaded(it) }.toSet()

    /** Drop every downloaded walk (Settings → Advanced → Reset app) and every intro gate with them. */
    fun deleteAllCaches() {
        walksRoot().deleteRecursively()
        val prefs = context.getSharedPreferences("songitude", Context.MODE_PRIVATE)
        val edit = prefs.edit()
        prefs.all.keys.filter { it.startsWith(RenderEngine.INTRO_GATE_KEY_PREFIX) }.forEach { edit.remove(it) }
        edit.apply()
    }

    /** Loads an already-downloaded walk from cache (null if not fully present). */
    fun cachedExperience(id: String): Experience? {
        val dir = cacheDir(id)
        if (!isDownloaded(id)) return null
        val mapFile = File(dir, "map.json")
        if (!mapFile.exists()) return null
        return try {
            Experience(id, dir, SongitudeJson.decodeFromString<SoundMap>(mapFile.readText()))
        } catch (t: Throwable) {
            null
        }
    }

    /**
     * Download map.json plus every referenced audio file, album art and label image.
     * [mapReady] fires as soon as map.json parses — long before the audio arrives — so the UI can
     * show the right walk immediately instead of sitting on the previous one.
     */
    suspend fun download(
        walk: RemoteWalk,
        mapReady: (SoundMap) -> Unit = {},
        progress: (Double) -> Unit = {},
    ): Result<Experience> = withContext(Dispatchers.IO) {
        try {
            val dir = cacheDir(walk.id)
            File(dir, "audio").mkdirs()
            val mapBytes = CatalogService.httpGet(walk.mapUrl, noCache = true)
            File(dir, "map.json").writeBytes(mapBytes)
            val map = SongitudeJson.decodeFromString<SoundMap>(mapBytes.decodeToString())
            withContext(Dispatchers.Main) { mapReady(map) }

            val rels = LinkedHashSet<String>()
            map.shapes.mapNotNull { it.audioFile }.forEach { rels.add("audio/$it") }
            map.albumArt?.takeIf { it.isNotEmpty() }?.let { rels.add(it) }
            map.intro?.takeIf { it.isNotEmpty() }?.let { rels.add("audio/$it") }
            map.exit?.takeIf { it.isNotEmpty() }?.let { rels.add("audio/$it") }
            // Label artwork, or an image label quietly falls back to its text on the device.
            (map.labels ?: emptyList()).mapNotNull { it.image }.filter { it.isNotEmpty() }
                .forEach { rels.add("images/$it") }

            // Fetch a few at a time. A walk can be eighty-odd clips, and downloading them one
            // after another leaves the connection idle for a whole round-trip between each. Four is
            // enough to keep the link busy without swamping a phone's radio or S3.
            val list = rels.toList()
            val gate = Semaphore(4)
            val finished = AtomicInteger(0)
            coroutineScope {
                list.map { rel ->
                    async {
                        gate.withPermit {
                            val dest = File(dir, rel)
                            if (!dest.exists()) {
                                dest.parentFile?.mkdirs()
                                val enc = rel.split("/").joinToString("/") {
                                    URLEncoder.encode(it, "UTF-8").replace("+", "%20")
                                }
                                val bytes = CatalogService.httpGet("${walk.base}/$enc")
                                // Write beside the target and move into place, so an interrupted
                                // download can never leave a truncated clip that later looks cached.
                                val tmp = File(dest.parentFile, dest.name + ".part")
                                tmp.writeBytes(bytes)
                                if (!tmp.renameTo(dest)) { dest.writeBytes(bytes); tmp.delete() }
                            }
                            val done = finished.incrementAndGet().toDouble() / maxOf(1, list.size)
                            withContext(Dispatchers.Main) { progress(done) }
                        }
                    }
                }.awaitAll()
            }
            File(dir, ".complete").writeBytes(ByteArray(0))
            versionFile(walk.id).writeText(walk.updatedAt ?: "")
            Result.success(Experience(walk.id, dir, map))
        } catch (t: Throwable) {
            Result.failure(t)
        }
    }
}

/**
 * Bundles baked into the APK at build time, unpacked from assets on first launch.
 *
 * The iOS build phase unzips each zip in Experiences into the app bundle; on Android the equivalent is
 * assets/bundled/<name>/. Nothing ships in either right now — the catalog is the source of walks —
 * but the path is kept so a walk can be baked in without touching the engine.
 */
object ExperienceLibrary {

    fun loadAll(context: Context): List<Experience> {
        val assets = context.assets
        val names = try { assets.list("bundled") ?: emptyArray() } catch (_: Throwable) { emptyArray() }
        if (names.isEmpty()) return emptyList()

        val root = File(context.filesDir, "bundled")
        val out = ArrayList<Experience>()
        for (name in names.sorted()) {
            val dir = File(root, name)
            try {
                if (!File(dir, "map.json").exists()) copyAssetDir(context, "bundled/$name", dir)
                val mapFile = File(dir, "map.json")
                if (!mapFile.exists()) continue
                out.add(Experience(name, dir, SongitudeJson.decodeFromString<SoundMap>(mapFile.readText())))
            } catch (_: Throwable) {
                // A malformed bundled walk should never stop the app from listing the rest.
            }
        }
        return out
    }

    private fun copyAssetDir(context: Context, assetPath: String, dest: File) {
        val assets = context.assets
        val entries = assets.list(assetPath) ?: return
        if (entries.isEmpty()) {
            dest.parentFile?.mkdirs()
            assets.open(assetPath).use { input -> dest.outputStream().use { input.copyTo(it) } }
            return
        }
        dest.mkdirs()
        for (e in entries) copyAssetDir(context, "$assetPath/$e", File(dest, e))
    }
}
