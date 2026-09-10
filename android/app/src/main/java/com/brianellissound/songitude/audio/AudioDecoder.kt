package com.brianellissound.songitude.audio

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
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

        var extractor: MediaExtractor? = null
        var codec: MediaCodec? = null
        val partial = File(pcmDir, src.name + ".pcm.part")
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

                while (!sawOutputEos) {
                    if (!sawInputEos) {
                        val inIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                        if (inIndex >= 0) {
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
                    }
                    val outIndex = codec.dequeueOutputBuffer(info, TIMEOUT_US)
                    when {
                        outIndex >= 0 -> {
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
                        outIndex == MediaCodec.INFO_TRY_AGAIN_LATER ->
                            if (sawInputEos && written > 0) sawOutputEos = true
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
