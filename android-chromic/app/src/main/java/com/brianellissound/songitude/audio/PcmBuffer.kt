package com.brianellissound.songitude.audio

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteOrder
import java.nio.MappedByteBuffer
import java.nio.ShortBuffer
import java.nio.channels.FileChannel

/**
 * A decoded clip, held as 16-bit PCM in a **memory-mapped file** rather than in the heap.
 *
 * This is the third design, and the first that survives a real walk. Decoding to float arrays died
 * on `dalvik.vm.heapgrowthlimit` (256 MB on a mid-range phone) — an eighteen-minute clip inflates to
 * ~400 MB that way. Switching to `ByteBuffer.allocateDirect` did not help either, because on Android
 * a direct buffer is backed by a `byte[]` on that same Java heap; the allocation simply failed at a
 * different line.
 *
 * A mapping is genuinely outside the heap: the kernel pages it in on demand and evicts it under
 * pressure, so a clip costs address space and disk rather than heap. It also means re-opening a walk
 * skips decoding entirely, since the PCM is already on disk.
 *
 * iOS needs none of this — it has no per-app heap ceiling, so AudioEngine.swift can hold
 * AVAudioPCMBuffers of the same clips directly.
 */
class PcmBuffer(
    private val mapped: MappedByteBuffer,
    val channels: Int,
    val sampleRate: Int,
    val frames: Int,
    /** The backing file, so eviction can reclaim the disk as well as the mapping. */
    val backingFile: File? = null,
) {
    private val shorts: ShortBuffer = mapped.asShortBuffer()

    /** Bytes this clip occupies. Mapped, so it is disk and address space rather than heap. */
    val byteCount: Long get() = frames.toLong() * channels * 2

    val durationSeconds: Double get() = if (sampleRate > 0) frames.toDouble() / sampleRate else 0.0

    /** One sample, as -1..1. [ch] beyond the clip's own channel count folds back, so a mono clip
     *  feeds every output channel. */
    fun sample(frame: Int, ch: Int): Float {
        val c = if (channels == 1) 0 else ch.coerceAtMost(channels - 1)
        return shorts.get(frame * channels + c) / 32768f
    }

    /**
     * Bake a seamless crossfade loop: overlap the tail with the head into one clip of length
     * (frames − crossfade), so plain looping is perceptually identical to the live overlap the
     * editor and web player do. Written to its own mapped file for the same reason as the original.
     */
    fun bakedCrossfade(crossfadeSeconds: Double, dest: File): PcmBuffer {
        val cf = (crossfadeSeconds * sampleRate).toInt().coerceIn(1, maxOf(1, frames / 2))
        val len = frames - cf
        if (len <= 0) return this
        return try {
            dest.parentFile?.mkdirs()
            RandomAccessFile(dest, "rw").use { raf ->
                raf.setLength(len.toLong() * channels * 2)
                val out = raf.channel.map(FileChannel.MapMode.READ_WRITE, 0, raf.length())
                out.order(ByteOrder.LITTLE_ENDIAN)
                val dst = out.asShortBuffer()
                for (i in 0 until len) {
                    for (c in 0 until channels) {
                        val v = if (i >= cf) {
                            shorts.get(i * channels + c).toFloat()
                        } else {
                            val f = i.toFloat() / cf
                            shorts.get(i * channels + c) * f + shorts.get((len + i) * channels + c) * (1 - f)
                        }
                        dst.put(i * channels + c, v.coerceIn(-32768f, 32767f).toInt().toShort())
                    }
                }
                out.force()
                PcmBuffer(out, channels, sampleRate, len, dest)
            }
        } catch (t: Throwable) {
            this      // a crossfade we cannot bake just loops plainly
        }
    }

    companion object {
        /** Map an already-decoded PCM file. */
        fun open(file: File, channels: Int, sampleRate: Int): PcmBuffer? = try {
            RandomAccessFile(file, "r").use { raf ->
                val frames = (raf.length() / (channels * 2L)).toInt()
                if (frames <= 0) null
                else {
                    val map = raf.channel.map(FileChannel.MapMode.READ_ONLY, 0, raf.length())
                    map.order(ByteOrder.LITTLE_ENDIAN)
                    PcmBuffer(map, channels, sampleRate, frames, file)
                }
            }
        } catch (t: Throwable) {
            null
        }
    }
}
