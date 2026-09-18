package com.brianellissound.songitude.audio

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Decodes a bundle's audio file to 16-bit PCM **on disk**, at the file's own sample rate and channel
 * count, then hands back a memory-mapped view of it.
 *
 * Nothing large is ever held in the heap: each MediaCodec output buffer is written straight out and
 * released. That is the whole point — see the note in [PcmBuffer] for the two designs this replaces
 * and why both died on Android's 256 MB heap ceiling.
 *
 * The PCM file is kept, so re-opening a walk maps what is already there instead of decoding again.
 */
object AudioDecoder {

    private const val TAG = "SongitudeDecoder"
    private const val TIMEOUT_US = 10_000L

    /** Where a walk's decoded PCM lives: `<cache>/pcm/<walkId>/`. One place, shared by the engine
     *  (which maps from it), the downloader (which fills it ahead of play) and cache deletion. */
    fun pcmDir(context: Context, walkId: String): File = File(File(context.cacheDir, "pcm"), walkId)

    // MARK: - Scheduling
    //
    // Two kinds of caller: the engine, which needs a clip because the listener is standing in (or
    // walking into) its area, and the warm-up after a download, which is filling the cache for
    // later. The first must never queue behind the second. So background decodes run at most two
    // at a time — Magic Square's twelve at once was more codec instances than a mid-range chip has
    // and twelve writers on one flash chip — while urgent ones always start immediately, and an
    // urgent request for a clip already waiting in the background queue promotes it. Either way a
    // clip is decoded once: a second request for the same file joins the first.

    private class Slot(@Volatile var urgent: Boolean) {
        val permit = CompletableDeferred<Unit>()
        var counted = false          // holds one of the background places
    }
    private class Entry(val slot: Slot, val deferred: Deferred<PcmBuffer?>)

    private const val BACKGROUND_PARALLELISM = 2
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val mu = Any()
    private val inFlight = HashMap<String, Entry>()
    private val waiting = ArrayDeque<Slot>()
    private var running = 0

    /** [decode], scheduled. Use this from any coroutine; see the note above on [urgent]. */
    suspend fun decodeGated(src: File, pcmDir: File, urgent: Boolean = true): PcmBuffer? {
        if (isDecoded(src, pcmDir)) return decode(src, pcmDir)      // only maps; no slot needed
        val key = File(pcmDir, src.name + ".pcm").path
        val entry = synchronized(mu) {
            inFlight[key]?.also { if (urgent) promoteLocked(it.slot) } ?: run {
                val slot = Slot(urgent)
                val d = scope.async {
                    acquire(slot)
                    try { decode(src, pcmDir) } finally { release(slot); synchronized(mu) { inFlight.remove(key) } }
                }
                Entry(slot, d).also { inFlight[key] = it }
            }
        }
        return entry.deferred.await()
    }

    private suspend fun acquire(slot: Slot) {
        synchronized(mu) {
            when {
                slot.urgent -> slot.permit.complete(Unit)
                running < BACKGROUND_PARALLELISM -> { running++; slot.counted = true; slot.permit.complete(Unit) }
                else -> waiting.addLast(slot)
            }
        }
        slot.permit.await()
    }

    private fun promoteLocked(slot: Slot) {
        if (slot.permit.isCompleted) return
        waiting.remove(slot)
        slot.urgent = true
        slot.permit.complete(Unit)
    }

    private fun release(slot: Slot) {
        synchronized(mu) {
            if (slot.counted) running--
            while (running < BACKGROUND_PARALLELISM && waiting.isNotEmpty()) {
                val next = waiting.removeFirst()
                running++; next.counted = true; next.permit.complete(Unit)
            }
        }
    }

    /** True if [src] has already been decoded into [pcmDir], so [decode] would only map it. */
    fun isDecoded(src: File, pcmDir: File): Boolean =
        File(pcmDir, src.name + ".pcm").exists() && File(pcmDir, src.name + ".meta").exists()

    /** Decode [src] into [pcmDir], or map an already-decoded copy. Null if the clip is missing or
     *  undecodable — the caller treats that the same as silence rather than taking the walk down. */
    fun decode(src: File, pcmDir: File): PcmBuffer? {
        if (!src.exists() || src.length() == 0L) {
            Log.w(TAG, "missing audio: ${src.name}")
            return null
        }
        val pcm = File(pcmDir, src.name + ".pcm")
        val meta = File(pcmDir, src.name + ".meta")

        // Already decoded on a previous run? Map it and skip the work.
        if (pcm.exists() && meta.exists()) {
            runCatching {
                val (ch, rate) = meta.readText().trim().split(",").map { it.toInt() }
                PcmBuffer.open(pcm, ch, rate)
            }.getOrNull()?.let { return it }
        }

        val partial = File(pcmDir, src.name + ".pcm.part")

        // A WAV is already PCM. Routing it through MediaCodec's raw "decoder" copied a 107 MB
        // file at just over a megabyte a second, one codec buffer per round-trip; reading the RIFF
        // header and streaming the data chunk out is a plain copy.
        decodeWav(src, pcm, meta, partial)?.let { return it }

        var extractor: MediaExtractor? = null
        var codec: MediaCodec? = null
        try {
            extractor = MediaExtractor().apply { setDataSource(src.absolutePath) }
            var trackIndex = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                    trackIndex = i; format = f; break
                }
            }
            if (trackIndex < 0 || format == null) {
                Log.w(TAG, "no audio track in ${src.name}"); return null
            }
            extractor.selectTrack(trackIndex)

            val srcRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val srcChannels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT).coerceAtLeast(1)
            val mime = format.getString(MediaFormat.KEY_MIME)!!

            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            pcmDir.mkdirs()
            var written = 0L
            // One small reusable scratch array. Bounded by a codec buffer, never by clip length.
            var scratch = ByteArray(16 * 1024)

            BufferedOutputStream(FileOutputStream(partial), 1 shl 16).use { out ->
                val info = MediaCodec.BufferInfo()
                var sawInputEos = false
                var sawOutputEos = false

                // One MP3 frame is 4.6 KB of PCM, so a five-minute clip is twelve thousand
                // buffers. The first version of this loop moved exactly one input and one output
                // per iteration and waited up to 10 ms on each — the decoder idled between
                // handoffs and a walk took eighty seconds to prepare on a mid-range phone. Now
                // every buffer either side can offer is moved with no wait, and the loop only
                // sleeps when both sides are genuinely empty.
                while (!sawOutputEos) {
                    var moved = false
                    while (!sawInputEos) {
                        val inIndex = codec.dequeueInputBuffer(0)
                        if (inIndex < 0) break
                        moved = true
                        val buf = codec.getInputBuffer(inIndex)!!
                        val size = extractor.readSampleData(buf, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            sawInputEos = true
                        } else {
                            codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                    while (!sawOutputEos) {
                        val outIndex = codec.dequeueOutputBuffer(info, if (moved) 0 else TIMEOUT_US)
                        if (outIndex < 0) {
                            // Nothing ready. If input has ended and the codec has gone quiet after
                            // producing something, treat that as the end — some decoders never
                            // flag EOS on the output side.
                            if (outIndex == MediaCodec.INFO_TRY_AGAIN_LATER && !moved &&
                                sawInputEos && written > 0) sawOutputEos = true
                            break
                        }
                        moved = true
                        if (info.size > 0) {
                            val ob = codec.getOutputBuffer(outIndex)!!
                            ob.position(info.offset)
                            ob.limit(info.offset + info.size)
                            val needed = requiredBytes(ob, codec.outputFormat)
                            if (scratch.size < needed) scratch = ByteArray(needed)
                            val n = toPcm16(ob, codec.outputFormat, scratch)
                            out.write(scratch, 0, n)
                            written += n
                        }
                        codec.releaseOutputBuffer(outIndex, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) sawOutputEos = true
                    }
                }
            }

            if (written == 0L) { Log.w(TAG, "decoded nothing from ${src.name}"); partial.delete(); return null }
            if (!partial.renameTo(pcm)) { partial.copyTo(pcm, overwrite = true); partial.delete() }
            meta.writeText("$srcChannels,$srcRate")
            Log.i(TAG, "decoded ${src.name}: ${written / 1024 / 1024} MB pcm, ${srcChannels}ch @ ${srcRate}Hz")
            return PcmBuffer.open(pcm, srcChannels, srcRate)
        } catch (t: Throwable) {
            Log.w(TAG, "decode failed for ${src.name}: $t")
            partial.delete()
            return null
        } finally {
            try { codec?.stop(); codec?.release() } catch (_: Throwable) {}
            try { extractor?.release() } catch (_: Throwable) {}
        }
    }

    /**
     * Copy a WAV's samples straight to [pcm] as 16-bit little-endian, or null if [src] is not a
     * WAV this understands (then MediaCodec has a go). Handles PCM at 16/24/32 bits and 32-bit
     * float, including WAVE_FORMAT_EXTENSIBLE, which is how most DAWs write anything above 16 bits.
     */
    private fun decodeWav(src: File, pcm: File, meta: File, partial: File): PcmBuffer? {
        val raf = try { java.io.RandomAccessFile(src, "r") } catch (t: Throwable) { return null }
        raf.use { f ->
            val head = ByteArray(12)
            if (f.read(head) < 12) return null
            if (String(head, 0, 4) != "RIFF" || String(head, 8, 4) != "WAVE") return null

            var channels = 0; var rate = 0; var bits = 0; var format = 0
            var dataAt = -1L; var dataLen = 0L
            val ch = ByteArray(8)
            while (f.filePointer + 8 <= f.length()) {
                if (f.read(ch) < 8) break
                val id = String(ch, 0, 4)
                val len = ByteBuffer.wrap(ch, 4, 4).order(ByteOrder.LITTLE_ENDIAN).int.toLong() and 0xFFFFFFFFL
                val bodyAt = f.filePointer
                when (id) {
                    "fmt " -> {
                        val fmt = ByteArray(len.toInt().coerceAtMost(64))
                        f.read(fmt)
                        val b = ByteBuffer.wrap(fmt).order(ByteOrder.LITTLE_ENDIAN)
                        format = b.getShort(0).toInt() and 0xFFFF
                        channels = b.getShort(2).toInt() and 0xFFFF
                        rate = b.getInt(4)
                        bits = b.getShort(14).toInt() and 0xFFFF
                        // Extensible: the real format tag is the first two bytes of the sub-format GUID.
                        if (format == 0xFFFE && fmt.size >= 26) format = b.getShort(24).toInt() and 0xFFFF
                    }
                    "data" -> { dataAt = bodyAt; dataLen = len }
                }
                if (dataAt >= 0 && rate > 0) break
                f.seek(bodyAt + len + (len and 1))            // chunks are word-aligned
            }
            if (dataAt < 0 || channels < 1 || rate < 1) return null
            val isFloat = format == 3
            if (!(format == 1 && bits in intArrayOf(16, 24, 32)) && !(isFloat && bits == 32)) {
                Log.w(TAG, "wav ${src.name}: format $format/$bits-bit, leaving it to MediaCodec")
                return null
            }
            val avail = f.length() - dataAt
            val bytesPerSample = bits / 8
            val frameBytes = bytesPerSample * channels
            val total = minOf(dataLen, avail) / frameBytes * frameBytes   // whole frames only

            pcm.parentFile?.mkdirs()
            f.seek(dataAt)
            val inBuf = ByteArray((1 shl 16) / frameBytes * frameBytes)
            val outBuf = ByteArray(inBuf.size / bytesPerSample * 2)
            var left = total
            try {
                BufferedOutputStream(FileOutputStream(partial), 1 shl 16).use { out ->
                    while (left > 0) {
                        val n = f.read(inBuf, 0, minOf(inBuf.size.toLong(), left).toInt())
                        if (n <= 0) break
                        val whole = n / frameBytes * frameBytes
                        val m = when {
                            bits == 16 -> { System.arraycopy(inBuf, 0, outBuf, 0, whole); whole }
                            isFloat -> floatToPcm16(inBuf, whole, outBuf)
                            else -> intToPcm16(inBuf, whole, bytesPerSample, outBuf)
                        }
                        out.write(outBuf, 0, m)
                        left -= whole
                        if (whole < n) f.seek(f.filePointer - (n - whole))
                    }
                }
            } catch (t: Throwable) {
                Log.w(TAG, "wav copy failed for ${src.name}: $t"); partial.delete(); return null
            }
            if (!partial.renameTo(pcm)) { partial.copyTo(pcm, overwrite = true); partial.delete() }
            meta.writeText("$channels,$rate")
            Log.i(TAG, "copied ${src.name}: ${(total * 2 / bytesPerSample) / 1024 / 1024} MB pcm, ${channels}ch @ ${rate}Hz, $bits-bit${if (isFloat) " float" else ""}")
            return PcmBuffer.open(pcm, channels, rate)
        }
    }

    /** 24- or 32-bit little-endian integer samples → 16-bit: keep the top two bytes. */
    private fun intToPcm16(src: ByteArray, n: Int, bytesPerSample: Int, dest: ByteArray): Int {
        var i = bytesPerSample - 2; var o = 0
        while (i + 1 < n) { dest[o++] = src[i]; dest[o++] = src[i + 1]; i += bytesPerSample }
        return o
    }

    private fun floatToPcm16(src: ByteArray, n: Int, dest: ByteArray): Int {
        val fb = ByteBuffer.wrap(src, 0, n).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
        var o = 0
        while (fb.hasRemaining()) {
            val v = (fb.get() * 32767f).coerceIn(-32768f, 32767f).toInt()
            dest[o++] = (v and 0xFF).toByte(); dest[o++] = ((v shr 8) and 0xFF).toByte()
        }
        return o
    }

    private fun requiredBytes(buf: ByteBuffer, fmt: MediaFormat): Int {
        val float = fmt.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
            fmt.getInteger(MediaFormat.KEY_PCM_ENCODING) == android.media.AudioFormat.ENCODING_PCM_FLOAT
        return if (float) buf.remaining() / 2 else buf.remaining()
    }

    /** Normalise a codec output buffer to little-endian 16-bit PCM in [dest]; returns bytes written. */
    private fun toPcm16(buf: ByteBuffer, fmt: MediaFormat, dest: ByteArray): Int {
        buf.order(ByteOrder.nativeOrder())
        val float = fmt.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
            fmt.getInteger(MediaFormat.KEY_PCM_ENCODING) == android.media.AudioFormat.ENCODING_PCM_FLOAT
        var at = 0
        if (float) {
            val fb = buf.asFloatBuffer()
            while (fb.hasRemaining()) {
                val v = (fb.get() * 32767f).coerceIn(-32768f, 32767f).toInt()
                dest[at++] = (v and 0xFF).toByte()
                dest[at++] = ((v shr 8) and 0xFF).toByte()
            }
        } else {
            val sb = buf.asShortBuffer()
            while (sb.hasRemaining()) {
                val v = sb.get().toInt()
                dest[at++] = (v and 0xFF).toByte()
                dest[at++] = ((v shr 8) and 0xFF).toByte()
            }
        }
        return at
    }
}
