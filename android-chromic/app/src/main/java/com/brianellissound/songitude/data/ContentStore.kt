package com.brianellissound.songitude.data

import android.content.Context
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import java.io.File

/**
 * Everything the catalog screens show, available before the network answers.
 *
 * Chromic publish rarely, so the app ships a snapshot of the manifest, the artist profile and the
 * artwork (`assets/seed/`, written by `ios-chromic/tools/refresh_seed.py` on every build of either
 * app). Reads go **disk cache, then seed**: the disk copy is whatever the last successful fetch
 * stored, so a returning launch shows the newest content it has seen and a fresh install shows the
 * release's snapshot. Either way the first frame is complete. Fetches still happen — `refresh`
 * runs in the background and stores the result — but nothing waits for them and nothing shows a
 * spinner over content it has.
 *
 * Chromic-only: Songitude's catalog changes too often, across too many artists, to bake in.
 */
class ContentStore(private val context: Context) {
    private val dir = File(context.cacheDir, "content").apply { mkdirs() }

    /** Source URL → file name inside `assets/seed/`. */
    private val seedIndex: Map<String, String> by lazy {
        try {
            Json.decodeFromString<Map<String, String>>(
                context.assets.open("seed/index.json").bufferedReader().readText()
            )
        } catch (t: Throwable) {
            Log.w(TAG, "no seed index: $t"); emptyMap()
        }
    }

    /** The newest copy we have of [url]: the last fetched one on disk, else the seed's, else null. */
    fun cached(url: String): ByteArray? {
        val f = fileFor(url)
        if (f.exists()) return try { f.readBytes() } catch (_: Throwable) { null }
        val name = seedIndex[url] ?: return null
        return try { context.assets.open("seed/$name").use { it.readBytes() } } catch (_: Throwable) { null }
    }

    /** A file for [url] that an image loader can open directly: the disk copy, or the seed copied
     *  out to disk once (assets aren't files). Null when we have neither. */
    fun cachedFile(url: String): File? {
        val f = fileFor(url)
        if (f.exists()) return f
        val bytes = cached(url) ?: return null
        return try { store(bytes, url); f } catch (_: Throwable) { null }
    }

    /** Keep a freshly fetched copy for the next launch. Written beside and renamed, so a crash
     *  mid-write can't leave a half file where the seed used to answer. */
    fun store(bytes: ByteArray, url: String) {
        val f = fileFor(url); val tmp = File(f.path + ".tmp")
        tmp.writeBytes(bytes)
        if (!tmp.renameTo(f)) { f.writeBytes(bytes); tmp.delete() }
    }

    /** Fetch [url] and store it; the bytes, or null on any failure. Never throws. */
    suspend fun refresh(url: String): ByteArray? = withContext(Dispatchers.IO) {
        try {
            CatalogService.httpGet(url, noCache = true).also { store(it, url) }
        } catch (t: Throwable) {
            Log.i(TAG, "refresh skipped for $url: ${t.message}"); null
        }
    }

    /** One file per URL, named by a stable hash of it (URLs have characters that aren't file-safe,
     *  and S3 keys can be long). Keeps the extension so image loaders sniff the type. */
    private fun fileFor(url: String): File {
        var h = -0x340d631b7bdddcdbL   // FNV-1a
        for (b in url.toByteArray()) { h = (h xor (b.toLong() and 0xff)) * 0x100000001b3L }
        val ext = url.substringAfterLast('.', "bin").substringBefore('?').take(5).ifEmpty { "bin" }
        return File(dir, java.lang.Long.toHexString(h) + "." + ext)
    }

    private companion object { const val TAG = "ChromicContent" }
}
