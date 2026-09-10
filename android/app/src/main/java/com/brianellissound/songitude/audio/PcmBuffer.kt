package com.brianellissound.songitude.audio

/**
 * A fully decoded clip, already converted to the engine's sample rate and channel count.
 *
 * Everything is normalised at decode time on purpose. The engine mixes every voice against one
 * clock, so if a clip arrived at 44.1k while the output ran at 48k, "one frame" would mean two
 * different things and syncedLoop — which is defined by sample alignment — would drift. Converting
 * once, up front, is what makes the mixer's index arithmetic exact.
 *
 * Samples are interleaved: [L0, R0, L1, R1, ...].
 */
class PcmBuffer(
    val samples: FloatArray,
    val channels: Int,
    val sampleRate: Int,
) {
    /** Length in frames (a frame is one sample per channel). */
    val frames: Int = if (channels > 0) samples.size / channels else 0

    val durationSeconds: Double get() = if (sampleRate > 0) frames.toDouble() / sampleRate else 0.0

    /**
     * Bake a seamless crossfade loop: overlap the tail with the head into one buffer of length
     * (frames − crossfade), so plain looping of the result is perceptually identical to the live
     * overlap the editor and web player do. Same algorithm as the iOS `crossfadeBuffer`.
     */
    fun bakedCrossfade(crossfadeSeconds: Double): PcmBuffer {
        val n = frames
        val cf = (crossfadeSeconds * sampleRate).toInt().coerceIn(1, maxOf(1, n / 2))
        val len = n - cf
        if (len <= 0 || cf <= 0) return this
        val out = FloatArray(len * channels)
        for (c in 0 until channels) {
            // Body plays straight through.
            for (i in cf until len) out[i * channels + c] = samples[i * channels + c]
            // Head fades in over the outgoing tail.
            for (i in 0 until cf) {
                val f = i.toFloat() / cf
                out[i * channels + c] =
                    samples[i * channels + c] * f + samples[(len + i) * channels + c] * (1 - f)
            }
        }
        return PcmBuffer(out, channels, sampleRate)
    }
}
