package com.brianellissound.songitude.audio

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Decodes a bundle's audio file to interleaved float PCM at the engine's rate and channel count.
 *
 * MediaCodec covers every container the editor lets an author publish (mp3, m4a/aac, wav, ogg,
 * flac). Output arrives as 16-bit PCM on most devices and float on some newer ones, so both are
 * handled; the result is always float, resampled and channel-mapped, because the mixer assumes
 * every buffer speaks in the same frames.
 */
object AudioDecoder {

    private const val TAG = "SongitudeDecoder"
    private const val TIMEOUT_US = 10_000L

    /** Decode [file], returning null if it is missing or undecodable — the caller treats that the
     *  same as silence rather than crashing a walk mid-stride. */
    fun decode(file: File, outRate: Int, outChannels: Int): PcmBuffer? {
        if (!file.exists() || file.length() == 0L) {
            Log.w(TAG, "missing audio: ${file.name}")
            return null
        }
        var extractor: MediaExtractor? = null
        var codec: MediaCodec? = null
        try {
            extractor = MediaExtractor().apply { setDataSource(file.absolutePath) }
            var trackIndex = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                    trackIndex = i; format = f; break
                }
            }
            if (trackIndex < 0 || format == null) {
                Log.w(TAG, "no audio track in ${file.name}"); return null
            }
            extractor.selectTrack(trackIndex)

            val srcRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val srcChannels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            val mime = format.getString(MediaFormat.KEY_MIME)!!

            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            val pcm = ArrayList<FloatArray>()
            var total = 0
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
                            val out = codec.getOutputBuffer(outIndex)!!
                            out.position(info.offset)
                            out.limit(info.offset + info.size)
                            val chunk = toFloats(out, codec.outputFormat)
                            pcm.add(chunk); total += chunk.size
                        }
                        codec.releaseOutputBuffer(outIndex, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) sawOutputEos = true
                    }
                    outIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> if (sawInputEos) {
                        // Some decoders go quiet at the end without ever flagging EOS.
                        if (pcm.isNotEmpty()) sawOutputEos = true
                    }
                }
            }

            if (total == 0) { Log.w(TAG, "decoded nothing from ${file.name}"); return null }
            val flat = FloatArray(total)
            var at = 0
            for (c in pcm) { c.copyInto(flat, at); at += c.size }

            return resampleAndMap(flat, srcChannels, srcRate, outChannels, outRate)
        } catch (t: Throwable) {
            Log.w(TAG, "decode failed for ${file.name}: $t")
            return null
        } finally {
            try { codec?.stop(); codec?.release() } catch (_: Throwable) {}
            try { extractor?.release() } catch (_: Throwable) {}
        }
    }

    /** Output buffers are 16-bit PCM on most devices and float on some; normalise to float. */
    private fun toFloats(buf: ByteBuffer, fmt: MediaFormat): FloatArray {
        val encoding = if (fmt.containsKey(MediaFormat.KEY_PCM_ENCODING))
            fmt.getInteger(MediaFormat.KEY_PCM_ENCODING) else android.media.AudioFormat.ENCODING_PCM_16BIT
        buf.order(ByteOrder.nativeOrder())
        return when (encoding) {
            android.media.AudioFormat.ENCODING_PCM_FLOAT -> {
                val fb = buf.asFloatBuffer()
                FloatArray(fb.remaining()).also { fb.get(it) }
            }
            else -> {
                val sb = buf.asShortBuffer()
                FloatArray(sb.remaining()) { sb.get(it) / 32768f }
            }
        }
    }

    /**
     * Linear resample and channel-map in one pass. Linear interpolation is enough here: clips are
     * music and speech played back at their authored rate, never pitch-shifted, and the only
     * conversion is the small ratio between a file's rate and the device's output rate.
     */
    private fun resampleAndMap(
        src: FloatArray, srcChannels: Int, srcRate: Int,
        outChannels: Int, outRate: Int,
    ): PcmBuffer {
        if (srcChannels <= 0) return PcmBuffer(FloatArray(0), outChannels, outRate)
        val srcFrames = src.size / srcChannels
        if (srcFrames == 0) return PcmBuffer(FloatArray(0), outChannels, outRate)

        val ratio = outRate.toDouble() / srcRate
        val outFrames = maxOf(1, (srcFrames * ratio).toInt())
        val out = FloatArray(outFrames * outChannels)

        for (i in 0 until outFrames) {
            val srcPos = i / ratio
            val i0 = srcPos.toInt().coerceIn(0, srcFrames - 1)
            val i1 = (i0 + 1).coerceAtMost(srcFrames - 1)
            val frac = (srcPos - i0).toFloat()
            for (c in 0 until outChannels) {
                // Mono spreads to every output channel; extra source channels beyond the output
                // are dropped rather than folded, matching how the iOS engine hands buffers straight
                // to the mixer.
                val sc = if (srcChannels == 1) 0 else c.coerceAtMost(srcChannels - 1)
                val a = src[i0 * srcChannels + sc]
                val b = src[i1 * srcChannels + sc]
                out[i * outChannels + c] = a + (b - a) * frac
            }
        }
        return PcmBuffer(out, outChannels, outRate)
    }
}
