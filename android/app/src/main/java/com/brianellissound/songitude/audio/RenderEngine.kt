package com.brianellissound.songitude.audio

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRouting
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import com.brianellissound.songitude.model.CoordinateOffset
import com.brianellissound.songitude.model.DialogueState
import com.brianellissound.songitude.model.Experience
import com.brianellissound.songitude.model.GeoUtils
import com.brianellissound.songitude.model.LatLngD
import com.brianellissound.songitude.model.PlaybackMode
import com.brianellissound.songitude.model.ShapeType
import com.brianellissound.songitude.model.SoundShape
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * The playback / rendering engine — the Android counterpart of ios/.../AudioEngine.swift.
 *
 * iOS gives every sounding area its own AVAudioPlayerNode and leans on AVAudioTime to launch synced
 * clips on a common sample. Android has no equivalent guarantee across independent players, so this
 * runs one AudioTrack and mixes every voice itself. That is not a shortcut — it is the only way
 * `syncedLoop` can mean what the format says it means, because with a single clock "the same frame"
 * is the same instant by construction, forever, with no drift to correct.
 *
 * The location-driven state machine below is a direct port: same modes, same fades, same dialogue
 * queue, same solo ducking, same proximity residency. Change one engine, change all three.
 */
class RenderEngine(private val context: Context) {

    // MARK: - Published state

    private val _isRunning = MutableStateFlow(false)
    val isRunning: StateFlow<Boolean> = _isRunning.asStateFlow()

    private val _soundingShapeIds = MutableStateFlow<Set<String>>(emptySet())
    val soundingShapeIds: StateFlow<Set<String>> = _soundingShapeIds.asStateFlow()

    /** Playback state per dialogue shape id — drives the map's dialogue colouring. */
    private val _dialogueStates = MutableStateFlow<Map<String, DialogueState>>(emptyMap())
    val dialogueStates: StateFlow<Map<String, DialogueState>> = _dialogueStates.asStateFlow()

    /** True once the "Play Outro" affordance should be offered (30 s after start). */
    private val _canEndSession = MutableStateFlow(false)
    val canEndSession: StateFlow<Boolean> = _canEndSession.asStateFlow()

    /** Called by the lock-screen / notification transport. true = play, false = pause. */
    var remoteToggle: ((Boolean) -> Unit)? = null

    /** Fired whenever isRunning changes, so the foreground service can start/stop itself. */
    var onRunningChanged: ((Boolean) -> Unit)? = null

    // MARK: - Output format

    private val outRate = 48_000
    private val outChannels = 2
    private val blockFrames = 1024

    private val main = Handler(Looper.getMainLooper())
    private val io = CoroutineScope(Dispatchers.IO)
    private val prefs = context.getSharedPreferences("songitude", Context.MODE_PRIVATE)

    // MARK: - Graph

    private var track: AudioTrack? = null
    private var mixThread: Thread? = null
    private val mixing = AtomicBoolean(false)

    /** The single clock. Frames handed to the AudioTrack since the graph came up. Everything that
     *  needs to happen "at the same moment" is expressed against this. */
    private var masterFrame: Long = 0
    private val lock = Any()

    // MARK: - Content

    private var shapes: List<SoundShape> = emptyList()
    private var offset: CoordinateOffset = CoordinateOffset.NONE
    private var experience: Experience? = null

    private val bufferCache = HashMap<String, PcmBuffer>()
    /** Baked seamless-loop buffers, keyed by shape id since crossfade time is per shape. */
    private val crossfadeCache = HashMap<String, PcmBuffer>()
    private val loadingFiles = HashSet<String>()
    private var loadToken = 0
    private var lastCoord: LatLngD? = null

    /** Where decoded PCM is kept for the loaded walk. Cleared with the walk, so a deleted walk
     *  doesn't leave hundreds of megabytes of raw audio behind. */
    private fun pcmDir(): File = File(File(context.cacheDir, "pcm"), experience?.id ?: "none")

    // Residency thresholds (metres from a region's boundary). Hysteresis: decode within preload,
    // keep until beyond evict — so pacing back and forth over a line doesn't thrash.
    private val preloadDistance = 300.0
    private val evictDistance = 600.0

    /** Ceiling on decoded audio held at once, in native memory.
     *
     *  iOS needs no such limit — it decodes what proximity says is near and the device copes. A
     *  walk like Magic Square is 148 MB of MP3 across twelve areas, and a phone will not hold all of
     *  that decoded. Distance already decides *what* to keep; this decides *how much*, dropping the
     *  furthest clips first so what is underfoot always wins. */
    // Mapped rather than heap-resident, so this is a bound on address space and page cache rather
    // than on the runtime's 256 MB ceiling. Generous, and the kernel evicts pages under pressure
    // regardless.
    private val pcmBudgetBytes = 700L * 1024 * 1024
    private var pcmBytes = 0L

    // MARK: - Synced loops

    private var syncedStarted = false
    /** Master frame the synced loops launched on, and the frames of skipping applied since. A synced
     *  voice's position is derived from these rather than from its own playhead, so a skip lands
     *  every synced clip on the same offset and the alignment that defines the mode survives. */
    private var syncedEpochFrame: Long? = null
    private var syncedShiftFrames: Long = 0

    // MARK: - Solo

    private var soloActive = false
    private val duckMoved = HashSet<String>()

    // MARK: - Runtime

    /** One mixed voice. Fields are read on the mixer thread and written on the main thread, always
     *  under [lock]. */
    private class Voice {
        var buffer: PcmBuffer? = null
        /** Playhead in the clip's *own* frames. Fractional because a clip may run at a different
         *  rate from the output; the step per output frame is fixed, so two synced clips stay in
         *  the same relationship forever. */
        var pos: Double = 0.0
        var loop = false
        var volume = 0f
        /** Volume the current ramp is heading to — this is what drives the map highlight. */
        var target = 0f
        var rampRemaining = 0
        var rampStep = 0f
        /** Master frame before which this voice is silent, used to launch synced loops together. */
        var startAtFrame = 0L
        /** Bumped on every reschedule, so a skip can never be mistaken for the clip playing out. */
        var epoch = 0
        var onFinish: (() -> Unit)? = null
        var rampDone: (() -> Unit)? = null
        var ended = false
    }

    /** `duck` is the solo gain factor last applied (null until the first pass), so a solo switching
     *  on or off can be detected and ramped rather than re-applied on every fix. */
    private class Runtime {
        var inside = false
        var armed = true
        var duck: Float? = null
    }

    private val voices = HashMap<String, Voice>()
    private val runtimes = HashMap<String, Runtime>()
    /** Voices that have left [voices] and are fading on their own. Tracked so a teardown can cancel
     *  them rather than leaving them mixing into a graph that is being rebuilt underneath. */
    private val fadingVoices = ArrayList<Voice>()

    // Dialogue queue: one at a time, others wait in entry order and play once each.
    private val dialogueQueue = ArrayList<String>()
    private var dialoguePlaying: String? = null

    // Intro / exit (walk-level) clips + end-session flow.
    private var introVoice: Voice? = null
    private var exitVoice: Voice? = null
    /** Exit sequence running — freeze location-driven playback. */
    private var outroActive = false
    private var doneRunnable: Runnable? = null

    companion object {
        /** How far one press of a skip button moves every voice. */
        const val SKIP_INTERVAL_SECONDS = 15.0
        /** Don't replay a walk's intro within an hour — the gate exists to survive a resume, not a
         *  reinstall. */
        private const val INTRO_GATE_SECONDS = 3600.0
        private const val DONE_DELAY_MS = 30_000L
        const val INTRO_GATE_KEY_PREFIX = "songitude.intro."
        fun introGateKey(walkId: String) = INTRO_GATE_KEY_PREFIX + walkId
        /** Holds `dialoguePlaying` while the intro narration runs. It is not a shape id, so every
         *  lookup that maps the channel back to a shape simply finds nothing — which stalls the
         *  queue without the intro pretending to be a dialogue. */
        private const val INTRO_CHANNEL = "__intro__"
    }

    // MARK: - Audio focus and route changes

    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var focusRequest: AudioFocusRequest? = null
    private var wasInterrupted = false

    /** Master gain applied to the finished mix while another app is ducking us. */
    @Volatile
    private var focusDuck = 1f

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        main.post {
            when (change) {
                // A call or another app taking the route: iOS gets an interruption notification and
                // does the same thing — tear down, remember we were playing, come back after.
                // A call or Siri: iOS gets an interruption and tears down, remembering it was
                // playing. Same here.
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                    if (_isRunning.value) { wasInterrupted = true; teardownAudio() }
                }
                // A notification chirp. Android offers this as its own case; iOS simply never
                // interrupts for one, and the walk plays on. Ducking under it rather than pausing is
                // what keeps the two behaving alike — a soundwalk stopping dead because a message
                // arrived would be its own kind of broken.
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> focusDuck = 0.25f
                AudioManager.AUDIOFOCUS_GAIN -> {
                    focusDuck = 1f
                    if (wasInterrupted) {
                        wasInterrupted = false
                        if (!bringUpAudio()) setRunning(false)
                    }
                }
                AudioManager.AUDIOFOCUS_LOSS -> {
                    // Permanent loss: make isRunning honest instead of claiming to play over silence.
                    wasInterrupted = false
                    if (_isRunning.value) handleRemoteTransport(false)
                }
            }
        }
    }

    /** Headphones or Bluetooth removed. Same rule as iOS: never suddenly blast a sound walk out of
     *  the speaker in someone's pocket. */
    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY && _isRunning.value) {
                main.post { handleRemoteTransport(false) }
            }
        }
    }
    private var noisyRegistered = false

    /** Hardware route changed underneath us — Bluetooth connecting, a dock, a USB DAC. The track was
     *  built for the old device and may now be rendering nowhere. iOS rebuilds its graph on
     *  AVAudioEngineConfigurationChange for exactly this; this is the same move. */
    private val routingListener = AudioRouting.OnRoutingChangedListener {
        main.post {
            if (!_isRunning.value || wasInterrupted) return@post
            rebuildGraph()
        }
    }

    /** Tear the output down and bring it back with playback intact. */
    private fun rebuildGraph() {
        teardownAudio()
        if (!bringUpAudio()) setRunning(false)
    }

    /**
     * Make the transport honest when the app comes back to the foreground.
     *
     * If the mixer died while we were away — the track was reclaimed, the process was frozen
     * part-way through a teardown — `isRunning` would otherwise keep claiming to play over silence,
     * and the button would read "pause" and do nothing. Ported from iOS's handleForeground.
     */
    fun reconcileOnForeground() {
        main.post {
            if (!_isRunning.value || wasInterrupted) return@post
            if (track == null || !mixing.get()) handleRemoteTransport(false)
        }
    }

    // MARK: - Loading

    /** Swap in an experience. Audio is NOT preloaded — clips decode on demand as the listener nears
     *  each region, so only nearby audio is ever in memory. */
    fun load(exp: Experience) {
        stop()
        experience = exp
        shapes = exp.map.shapes
        offset = CoordinateOffset.NONE
        loadToken++
        synchronized(lock) {
            bufferCache.clear(); crossfadeCache.clear(); loadingFiles.clear()
            pcmBytes = 0
            runtimes.clear()
            shapes.forEach { runtimes[it.id] = Runtime() }
        }
        resetDialogue()
    }

    /** Move the same areas to new coordinates without disturbing playback. Shape ids don't change,
     *  so runtimes, decoded buffers and dialogue history all stay valid — only where each area sits
     *  is different. Used when a transportable walk is re-anchored; [load] would stop the audio and
     *  forget which dialogue had already played. */
    fun updateGeometry(exp: Experience) {
        experience = exp
        shapes = exp.map.shapes
    }

    fun setOffset(o: CoordinateOffset) { offset = o }

    // MARK: - Transport

    fun start() {
        if (_isRunning.value) return
        wasInterrupted = false
        setRunning(true)          // set before bring-up so the isRunning-gated helpers run
        if (bringUpAudio()) {
            maybePlayIntro()
            armDoneTimer()
        } else {
            setRunning(false)
        }
    }

    fun stop() {
        if (!_isRunning.value && voices.isEmpty()) return
        wasInterrupted = false
        cancelDoneTimer()
        outroActive = false
        teardownAudio()
        setRunning(false)
        abandonFocus()
    }

    fun toggle() { if (_isRunning.value) stop() else start() }

    private fun setRunning(v: Boolean) {
        if (_isRunning.value != v) {
            _isRunning.value = v
            onRunningChanged?.invoke(v)
        }
    }

    private fun requestFocus(): Boolean {
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()
        val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(attrs)
            .setOnAudioFocusChangeListener(focusListener, main)
            .setWillPauseWhenDucked(false)
            .build()
        focusRequest = req
        return audioManager.requestAudioFocus(req) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun abandonFocus() {
        focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
        focusRequest = null
        if (noisyRegistered) {
            try { context.unregisterReceiver(noisyReceiver) } catch (_: Throwable) {}
            noisyRegistered = false
        }
    }

    /** Bring up the track and mixer and resume region evaluation from the last known fix. */
    private fun bringUpAudio(): Boolean {
        if (!requestFocus()) return false
        if (!noisyRegistered) {
            context.registerReceiver(noisyReceiver, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
            noisyRegistered = true
        }
        val minBytes = AudioTrack.getMinBufferSize(
            outRate,
            AudioFormat.CHANNEL_OUT_STEREO,
            AudioFormat.ENCODING_PCM_FLOAT,
        )
        // Three mix blocks of headroom, or the platform minimum if that is larger. Enough that a
        // scheduling hiccup on a walking phone doesn't underrun, small enough that a pause is felt
        // immediately rather than after a long buffered tail.
        val bufBytes = max(minBytes, blockFrames * outChannels * 4 * 3)
        val t = try {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                        .setSampleRate(outRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                        .build()
                )
                .setBufferSizeInBytes(bufBytes)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
        } catch (t: Throwable) {
            return false
        }
        synchronized(lock) { masterFrame = 0 }
        track = t
        t.addOnRoutingChangedListener(routingListener, main)
        t.play()
        startMixThread()
        ensureSyncedLoops()
        lastCoord?.let { updateLocation(it) }   // resume region audio without waiting for a fix
        return true
    }

    /** Stop and drop every voice and free audio memory, leaving isRunning and the loaded experience
     *  untouched. Used by stop() and by focus-driven suspend. */
    private fun teardownAudio() {
        stopMixThread()
        synchronized(lock) {
            voices.clear()
            fadingVoices.clear()
            introVoice = null
            exitVoice = null
            runtimes.keys.toList().forEach { runtimes[it] = Runtime() }
            bufferCache.clear()
            crossfadeCache.clear()
            loadingFiles.clear()
            pcmBytes = 0
        }
        soloActive = false
        duckMoved.clear()
        _soundingShapeIds.value = emptySet()
        try {
            track?.removeOnRoutingChangedListener(routingListener)
            track?.pause(); track?.flush(); track?.release()
        } catch (_: Throwable) {}
        track = null
        loadToken++              // invalidate any in-flight decodes
        syncedStarted = false
        syncedEpochFrame = null
        syncedShiftFrames = 0
        suspendDialogue()
    }

    // MARK: - Mixer

    private fun startMixThread() {
        mixing.set(true)
        val t = Thread({
            val block = FloatArray(blockFrames * outChannels)
            val finished = ArrayList<() -> Unit>()
            while (mixing.get()) {
                java.util.Arrays.fill(block, 0f)
                finished.clear()
                synchronized(lock) {
                    val blockStart = masterFrame
                    for ((id, v) in voices) mixVoice(v, block, blockStart, blockFrames, finished, id)
                    for (v in fadingVoices.toList()) mixVoice(v, block, blockStart, blockFrames, finished, null)
                    introVoice?.let { mixVoice(it, block, blockStart, blockFrames, finished, null) }
                    exitVoice?.let { mixVoice(it, block, blockStart, blockFrames, finished, null) }
                    masterFrame += blockFrames
                }
                val duck = focusDuck
                if (duck != 1f) for (j in block.indices) block[j] *= duck
                // Callbacks run on the main thread and may mutate the graph, so never inside the lock.
                if (finished.isNotEmpty()) main.post { finished.forEach { it() } }
                val out = track ?: break
                val written = try {
                    out.write(block, 0, block.size, AudioTrack.WRITE_BLOCKING)
                } catch (_: Throwable) { break }
                if (written < 0) break
            }
        }, "songitude-mixer")
        t.priority = Thread.MAX_PRIORITY
        mixThread = t
        t.start()
    }

    private fun stopMixThread() {
        mixing.set(false)
        mixThread?.let { th -> try { th.join(500) } catch (_: InterruptedException) {} }
        mixThread = null
    }

    /**
     * Mix one voice into [block]. Ramps advance per frame, so a fade is exactly as long as it was
     * asked to be regardless of block size, and a voice that starts mid-block starts on the right
     * sample rather than being rounded to a block boundary — which is what keeps synced loops
     * genuinely aligned rather than approximately so.
     */
    private fun mixVoice(
        v: Voice, block: FloatArray, blockStart: Long, n: Int,
        finished: MutableList<() -> Unit>, id: String?,
    ) {
        val buf = v.buffer ?: return
        if (buf.frames == 0 || v.ended) return
        var i = max(0, (v.startAtFrame - blockStart).toInt())
        if (i >= n) return
        val ch = outChannels
        val frames = buf.frames
        // Clips keep their own sample rate, so each voice steps through its source by a fixed
        // amount per output frame. Fixed is the important word: it is what keeps two synced clips
        // in the same relationship however long the walk runs.
        val step = buf.sampleRate.toDouble() / outRate

        while (i < n) {
            if (v.rampRemaining > 0) {
                v.volume += v.rampStep
                v.rampRemaining--
                if (v.rampRemaining == 0) {
                    v.volume = v.target
                    v.rampDone?.let { done -> v.rampDone = null; finished.add(done) }
                }
            }
            if (v.pos >= frames) {
                if (v.loop) {
                    v.pos -= frames        // carry the fraction, so a loop never drifts
                } else {
                    v.ended = true
                    val cb = v.onFinish
                    if (cb != null) { v.onFinish = null; finished.add(cb) }
                    return
                }
            }
            val vol = v.volume
            if (vol != 0f) {
                val f0 = v.pos.toInt()
                val frac = (v.pos - f0).toFloat()
                val f1 = if (f0 + 1 < frames) f0 + 1 else if (v.loop) 0 else f0
                for (c in 0 until ch) {
                    val a = buf.sample(f0, c)
                    val b = buf.sample(f1, c)
                    block[i * ch + c] += (a + (b - a) * frac) * vol
                }
            }
            v.pos += step
            i++
        }
    }

    /** Linear volume ramp, expressed in frames so the mixer can apply it exactly. */
    private fun ramp(v: Voice, to: Float, durationSeconds: Double, onDone: (() -> Unit)? = null) {
        synchronized(lock) {
            v.target = to
            val frames = max(1, (durationSeconds * outRate).toInt())
            v.rampRemaining = frames
            v.rampStep = (to - v.volume) / frames
            v.rampDone = onDone
        }
    }

    // MARK: - Location driven state machine

    fun updateLocation(coord: LatLngD) {
        lastCoord = coord
        if (!_isRunning.value || outroActive) return   // freeze location-driven playback during the outro
        updateResidency(coord)
        startSyncedLoopsIfReady()

        val nowInside = HashSet<String>()
        for (s in shapes) if (GeoUtils.contains(s, coord, offset)) nowInside.add(s.id)

        // Solo latch first: a duck that just came on or went off has to move voices that otherwise
        // set their volume once (one-shots, dialogue) or hold a constant level (loops with no
        // falloff). Anything it already ramped is left alone below so its duck fade isn't cut short.
        duckMoved.clear()
        applySolo(nowInside)

        for (shape in shapes) {
            val rt = runtimes.getOrPut(shape.id) { Runtime() }
            val isIn = nowInside.contains(shape.id)
            val rising = isIn && !rt.inside
            val duck = duckFactor(shape)

            when (shape.mode) {
                PlaybackMode.LOOP -> {
                    if (isIn) {
                        val target = (shape.gain * loopLevel(shape, coord)).toFloat() * duck
                        if (voices[shape.id] == null) startLoop(shape, target)
                        else if (!duckMoved.contains(shape.id)) setLoopTarget(shape, target)
                    } else if (voices[shape.id] != null) {
                        stopLoop(shape)
                    }
                }
                PlaybackMode.ONESHOT -> {
                    if (rising && rt.armed) { playOnce(shape); rt.armed = false }
                    if (!isIn) rt.armed = true
                }
                PlaybackMode.DIALOGUE -> {
                    // Play once ever; if a dialogue is already sounding, queue and play when it ends.
                    if (rising && (_dialogueStates.value[shape.id] ?: DialogueState.UNPLAYED) == DialogueState.UNPLAYED) {
                        setDialogueState(shape.id, DialogueState.QUEUED)
                        dialogueQueue.add(shape.id)
                        advanceDialogue()
                    }
                }
                PlaybackMode.SYNCED_LOOP -> {
                    // Never starts or stops here — it is already running in sync; only its volume is gated.
                    if (!duckMoved.contains(shape.id)) {
                        voices[shape.id]?.let { voice ->
                            val target = if (isIn) (shape.gain * loopLevel(shape, coord)).toFloat() * duck else 0f
                            val dur = when {
                                rising -> max(0.02, shape.fadeIn)
                                rt.inside && !isIn -> max(0.02, shape.fadeOut)
                                else -> 0.12
                            }
                            ramp(voice, target, dur)
                        }
                    }
                }
            }
            rt.inside = isIn
        }
        refreshSounding()
    }

    // MARK: - Proximity residency

    private fun syncedFileSet(): Set<String> =
        shapes.filter { it.mode == PlaybackMode.SYNCED_LOOP }.mapNotNull { it.audioFile }.toSet()

    private fun updateResidency(coord: LatLngD) {
        val synced = syncedFileSet()      // synced loops must stay resident to hold sync
        val files = shapes.mapNotNull { it.audioFile }.toSet()
        for (file in files) {
            val d = if (synced.contains(file)) 0.0 else fileDistance(file, coord)
            val cached = synchronized(lock) { bufferCache[file] }
            if (cached == null) {
                if (!loadingFiles.contains(file) && d <= preloadDistance) loadFile(file)
            } else if (!synced.contains(file) && d > evictDistance && !fileInUse(file)) {
                evict(file)
            }
        }
    }

    /** Drop one decoded clip and anything baked from it. */
    private fun evict(file: String) {
        synchronized(lock) {
            bufferCache.remove(file)?.let { pcmBytes -= it.byteCount }
            shapes.filter { it.audioFile == file }.forEach { s ->
                crossfadeCache.remove(s.id)?.let { pcmBytes -= it.byteCount }
            }
        }
        // The decoded file is deliberately left on disk: walking back into the area maps it again
        // instead of decoding a second time, and the kernel has already stopped paying for the
        // pages we no longer touch.
    }

    /** Bring memory back under the ceiling by dropping the furthest clips that nothing is using.
     *  Synced loops are never dropped: they have to stay resident to hold sync. */
    private fun enforcePcmBudget() {
        if (pcmBytes <= pcmBudgetBytes) return
        val here = lastCoord ?: return
        val synced = syncedFileSet()
        val candidates = synchronized(lock) { bufferCache.keys.toList() }
            .filter { it !in synced && !fileInUse(it) }
            .sortedByDescending { fileDistance(it, here) }
        for (file in candidates) {
            if (pcmBytes <= pcmBudgetBytes) return
            evict(file)
        }
    }

    private fun loadFile(file: String) {
        val exp = experience ?: return
        loadingFiles.add(file)
        val token = loadToken
        val target = exp.audioFile(file)
        io.launch {
            val buf = AudioDecoder.decode(target, pcmDir())
            main.post {
                if (token != loadToken) return@post
                loadingFiles.remove(file)
                if (buf == null) return@post
                synchronized(lock) {
                    bufferCache.put(file, buf)?.let { pcmBytes -= it.byteCount }
                    pcmBytes += buf.byteCount
                }
                enforcePcmBudget()
                startSyncedLoopsIfReady()
                // Start a queued dialogue that was waiting on this clip to decode.
                val p = dialoguePlaying
                if (p != null && voices[p] == null) {
                    shapes.firstOrNull { it.id == p && it.audioFile == file }?.let { tryStartDialogue(it) }
                }
                // Kick a loop that was waiting on this clip, without waiting for the next fix.
                if (_isRunning.value) lastCoord?.let { updateLocation(it) }
            }
        }
    }

    // MARK: - Synced loops

    private fun ensureSyncedLoops() {
        if (!_isRunning.value) return
        for (f in syncedFileSet()) {
            val have = synchronized(lock) { bufferCache[f] != null }
            if (!have && !loadingFiles.contains(f)) loadFile(f)
        }
        startSyncedLoopsIfReady()
    }

    private fun startSyncedLoopsIfReady() {
        if (!_isRunning.value || syncedStarted) return
        val files = syncedFileSet()
        if (files.isEmpty()) { syncedStarted = true; return }
        val ready = synchronized(lock) { files.all { bufferCache[it] != null } }
        if (!ready) return      // wait for every clip

        // One common master frame → every synced player begins on the exact same sample. On iOS this
        // needs AVAudioTime and a host-clock conversion; here it is just a number, because there is
        // only one clock.
        val start = synchronized(lock) { masterFrame } + (0.15 * outRate).toLong()
        synchronized(lock) {
            for (shape in shapes) {
                if (shape.mode != PlaybackMode.SYNCED_LOOP) continue
                val file = shape.audioFile ?: continue
                val buf = bufferCache[file] ?: continue
                if (voices[shape.id] != null) continue
                val v = Voice()
                v.buffer = buf
                v.loop = true
                v.volume = 0f          // silent but running until the listener enters
                v.target = 0f
                v.startAtFrame = start
                voices[shape.id] = v
            }
            syncedEpochFrame = start
            syncedShiftFrames = 0
        }
        syncedStarted = true
        refreshSounding()
    }

    /** Nearest distance (m) from [coord] to any region using [file]; 0 if inside one. */
    private fun fileDistance(file: String, coord: LatLngD): Double {
        var best = Double.MAX_VALUE
        for (s in shapes) if (s.audioFile == file) best = min(best, regionDistance(s, coord))
        return best
    }

    private fun regionDistance(shape: SoundShape, coord: LatLngD): Double = when (shape.type) {
        ShapeType.CIRCLE -> {
            val c = shape.centerCoord; val r = shape.radius
            if (c == null || r == null) Double.MAX_VALUE
            else max(0.0, GeoUtils.distance(offset.apply(c), coord) - r)
        }
        ShapeType.POLYGON -> {
            val ring = shape.ringCoords.map { offset.apply(it) }
            if (ring.size < 3) Double.MAX_VALUE
            else if (GeoUtils.pointInPolygon(coord, ring)) 0.0
            else ring.minOfOrNull { GeoUtils.distance(it, coord) } ?: Double.MAX_VALUE
        }
    }

    /** True if a playing voice uses [file], so it must not be evicted. */
    private fun fileInUse(file: String): Boolean {
        for (id in voices.keys) {
            if (shapes.firstOrNull { it.id == id }?.audioFile == file) return true
        }
        // Keep clips for dialogue that is queued or playing, ready for when its turn comes.
        val pending = dialogueQueue + listOfNotNull(dialoguePlaying)
        for (id in pending) {
            if (shapes.firstOrNull { it.id == id }?.audioFile == file) return true
        }
        return false
    }

    // MARK: - Voice control

    /** Solo multiplier: 0 while a solo elsewhere is ducking this shape, 1 otherwise. A duck is a
     *  gain change, never a stop — the ducked voice keeps running underneath so it returns exactly
     *  where it would have been. Uniform across every mode, dialogue included. */
    private fun duckFactor(shape: SoundShape): Float = if (soloActive && !shape.solo) 0f else 1f

    /** Is this shape's solo engaging the duck right now? Containment is the test for every mode but
     *  dialogue: a dialogue only queues on entry and plays once ever, so a soloed dialogue ducks the
     *  walk while its own clip sounds — not while it waits, and not once finished. */
    private fun soloEngaged(shape: SoundShape, inside: Set<String>?): Boolean {
        if (!shape.solo) return false
        if (shape.mode == PlaybackMode.DIALOGUE) {
            return (_dialogueStates.value[shape.id] ?: DialogueState.UNPLAYED) == DialogueState.PLAYING
        }
        return inside?.contains(shape.id) ?: (runtimes[shape.id]?.inside ?: false)
    }

    /** Recompute the solo latch and move every voice whose duck factor changed. Called from the
     *  location pass and from the dialogue queue, since a soloed dialogue engages and releases the
     *  duck between fixes. Ducking uses the ducked shape's own fades, so it sounds like leaving and
     *  re-entering it. */
    private fun applySolo(inside: Set<String>? = null) {
        soloActive = shapes.any { soloEngaged(it, inside) }
        for (shape in shapes) {
            val rt = runtimes.getOrPut(shape.id) { Runtime() }
            val duck = duckFactor(shape)
            // Only act once a baseline is recorded — the first pass just notes where this shape sits.
            val changed = rt.duck != null && rt.duck != duck
            rt.duck = duck
            if (!changed) continue
            duckMoved.add(shape.id)
            val voice = voices[shape.id] ?: continue
            val isIn = inside?.contains(shape.id) ?: rt.inside
            val target = when (shape.mode) {
                PlaybackMode.LOOP, PlaybackMode.SYNCED_LOOP -> {
                    val c = lastCoord
                    if (isIn && c != null) (shape.gain * loopLevel(shape, c)).toFloat() * duck else 0f
                }
                PlaybackMode.ONESHOT, PlaybackMode.DIALOGUE -> shape.gain.toFloat() * duck
            }
            ramp(voice, target, if (duck > 0) max(0.02, shape.fadeIn) else max(0.02, shape.fadeOut))
        }
    }

    /** Proximity multiplier (0..1) for a circle loop with a falloff profile; 1 otherwise. */
    private fun loopLevel(shape: SoundShape, coord: LatLngD): Double {
        if (shape.type != ShapeType.CIRCLE) return 1.0
        if (shape.falloff == com.brianellissound.songitude.model.Falloff.NONE) return 1.0
        val c = shape.centerCoord ?: return 1.0
        val r = shape.radius ?: return 1.0
        if (r <= 0) return 1.0
        return shape.falloff.level(GeoUtils.distance(offset.apply(c), coord) / r)
    }

    private fun startLoop(shape: SoundShape, target: Float) {
        val file = shape.audioFile ?: return
        val raw = synchronized(lock) { bufferCache[file] } ?: return
        // Crossfade loops play a baked seamless buffer; simple loops play the raw clip.
        val buf = if (shape.isCrossfadeLoop) crossfadeBufferFor(shape, raw) else raw
        val v = Voice()
        v.buffer = buf
        v.loop = true
        v.volume = 0f
        synchronized(lock) {
            v.startAtFrame = masterFrame
            voices[shape.id] = v
        }
        ramp(v, target, max(0.02, shape.fadeIn))
    }

    private fun crossfadeBufferFor(shape: SoundShape, raw: PcmBuffer): PcmBuffer =
        synchronized(lock) {
            crossfadeCache.getOrPut(shape.id) {
                raw.bakedCrossfade(shape.crossfade, File(pcmDir(), "${'$'}{shape.id}.xf.pcm"))
                    .also { pcmBytes += it.byteCount }
            }
        }

    /** Track proximity gain as the listener moves within a falloff circle (no-op for plain loops). */
    private fun setLoopTarget(shape: SoundShape, target: Float) {
        if (shape.type != ShapeType.CIRCLE) return
        if (shape.falloff == com.brianellissound.songitude.model.Falloff.NONE) return
        val v = voices[shape.id] ?: return
        ramp(v, target, 0.12)
    }

    private fun stopLoop(shape: SoundShape) {
        val v = synchronized(lock) { voices.remove(shape.id) } ?: return
        fadeOutAndDrop(v, max(0.02, shape.fadeOut))
    }

    /** Fade a voice that has already left [voices] to silence and drop it. Registered in
     *  [fadingVoices] for the duration so a teardown mid-fade can cancel it. */
    private fun fadeOutAndDrop(v: Voice, duration: Double) {
        synchronized(lock) { fadingVoices.add(v) }
        ramp(v, 0f, duration) {
            synchronized(lock) { fadingVoices.remove(v); v.ended = true }
        }
    }

    private fun playOnce(shape: SoundShape) {
        val file = shape.audioFile ?: return
        val buf = synchronized(lock) { bufferCache[file] } ?: return
        val v = Voice()
        v.buffer = buf
        v.loop = false
        val level = shape.gain.toFloat() * duckFactor(shape)
        v.volume = level
        v.target = level
        v.onFinish = { finishOnce(shape, v) }
        synchronized(lock) {
            v.startAtFrame = masterFrame
            voices[shape.id] = v
        }
    }

    /** A play-once clip is over — by playing out, or by being skipped past its end. */
    private fun finishOnce(shape: SoundShape, v: Voice) {
        synchronized(lock) { if (voices[shape.id] === v) voices.remove(shape.id) }
        if (shape.mode == PlaybackMode.DIALOGUE) finishDialogue(shape.id) else refreshSounding()
    }

    // MARK: - Skip

    /**
     * Move every sounding clip [delta] seconds through its own playback.
     *
     * This is only ever a playhead move. It does not rewind the listener's position, revisit areas
     * they have walked out of, or start anything not already sounding: what you hear is exactly what
     * was playing a moment ago, further along or further back.
     *
     * The modes differ only in what the ends of a clip mean. A loop wraps both ways. A one-shot or
     * dialogue can't wrap — it is meant to be heard once through — so rewinding past its start
     * restarts it, and skipping past its end counts as having heard it out.
     */
    fun skip(delta: Double) {
        if (!_isRunning.value || outroActive || delta == 0.0) return
        val shiftOut = (delta * outRate).toLong()

        synchronized(lock) {
            syncedShiftFrames += shiftOut
            val epoch = syncedEpochFrame
            for ((id, v) in voices) {
                val shape = shapes.firstOrNull { it.id == id } ?: continue
                val buf = v.buffer ?: continue
                if (buf.frames <= 0) continue
                // The move is expressed in this clip's own frames, since each keeps its own rate.
                val moveFrames = delta * buf.sampleRate
                when (shape.mode) {
                    PlaybackMode.SYNCED_LOOP -> {
                        // Position comes from the shared launch instant rather than this voice's own
                        // playhead, so every synced clip lands on the same offset and they stay
                        // aligned with each other rather than drifting apart by the cost of this loop.
                        if (epoch != null && masterFrame > epoch) {
                            val elapsedOut = (masterFrame - epoch) + syncedShiftFrames
                            val step = buf.sampleRate.toDouble() / outRate
                            var p = (elapsedOut * step) % buf.frames
                            if (p < 0) p += buf.frames
                            v.pos = p
                        }
                    }
                    PlaybackMode.LOOP -> {
                        var p = (v.pos + moveFrames) % buf.frames
                        if (p < 0) p += buf.frames    // a rewind past the top comes round to the tail
                        v.pos = p
                    }
                    PlaybackMode.ONESHOT, PlaybackMode.DIALOGUE -> {
                        val p = v.pos + moveFrames
                        if (p >= buf.frames) {
                            // Past the end of a play-once clip is the same as having heard it through.
                            v.ended = true
                            val cb = v.onFinish
                            v.onFinish = null
                            if (cb != null) main.post(cb)
                        } else {
                            v.pos = max(0.0, p)       // before the top ⇒ from the top
                        }
                    }
                }
            }
            // The walk's intro is a clip like any other, so it moves with everything else.
            introVoice?.let { v ->
                val buf = v.buffer
                if (buf != null && buf.frames > 0) {
                    val p = v.pos + delta * buf.sampleRate
                    if (p >= buf.frames) {
                        v.ended = true
                        val cb = v.onFinish
                        v.onFinish = null
                        if (cb != null) main.post(cb)
                    } else v.pos = max(0.0, p)
                }
            }
        }
        refreshSounding()
    }

    // MARK: - Dialogue queue

    private fun setDialogueState(id: String, state: DialogueState) {
        _dialogueStates.value = _dialogueStates.value.toMutableMap().apply { put(id, state) }
    }

    /** Start the next queued dialogue if none is sounding. */
    private fun advanceDialogue() {
        if (dialoguePlaying != null || dialogueQueue.isEmpty()) return
        val id = dialogueQueue.removeAt(0)
        val shape = shapes.firstOrNull { it.id == id }
        if (shape == null) { advanceDialogue(); return }
        dialoguePlaying = id
        setDialogueState(id, DialogueState.PLAYING)
        tryStartDialogue(shape)
    }

    /** Schedule the playing dialogue's clip. If its buffer isn't resident, request it and start when
     *  it arrives (loadFile's completion calls back here). */
    private fun tryStartDialogue(shape: SoundShape) {
        if (dialoguePlaying != shape.id || voices[shape.id] != null) return
        val file = shape.audioFile
        if (file == null) { finishDialogue(shape.id); return }
        val buf = synchronized(lock) { bufferCache[file] }
        if (buf == null) {
            if (!loadingFiles.contains(file)) loadFile(file)
            return
        }
        val v = Voice()
        v.buffer = buf
        v.loop = false
        val level = shape.gain.toFloat() * duckFactor(shape)
        v.volume = level
        v.target = level
        v.onFinish = { finishOnce(shape, v) }
        synchronized(lock) {
            v.startAtFrame = masterFrame
            voices[shape.id] = v
        }
        // A soloed dialogue engages the duck only now, as its clip starts — entering its area merely
        // queued it, and the location pass that queued it is long over.
        applySolo()
        refreshSounding()
    }

    private fun finishDialogue(id: String) {
        if (dialoguePlaying == id) dialoguePlaying = null
        setDialogueState(id, DialogueState.FINISHED)
        refreshSounding()
        advanceDialogue()
        // A soloed dialogue's duck ends with its clip. Recompute after the queue has moved on, so
        // handing over to another soloed dialogue doesn't blip the duck off and straight back on.
        applySolo()
    }

    /** Fresh start (new experience): every dialogue back to unplayed, queue empty. */
    private fun resetDialogue() {
        dialogueQueue.clear()
        dialoguePlaying = null
        _dialogueStates.value = shapes.filter { it.mode == PlaybackMode.DIALOGUE }
            .associate { it.id to DialogueState.UNPLAYED }
    }

    /** System suspend / user pause: drop the queue and let anything not fully played run again. */
    private fun suspendDialogue() {
        dialogueQueue.clear()
        dialoguePlaying = null
        _dialogueStates.value = _dialogueStates.value.mapValues { (_, st) ->
            if (st == DialogueState.QUEUED || st == DialogueState.PLAYING) DialogueState.UNPLAYED else st
        }
    }

    // MARK: - Intro / exit clips + end session

    /** Decode a walk-level clip and play it once. [assign] receives the voice; [onFinish] fires when
     *  the clip ends, or immediately if it can't load — a missing intro must release the dialogue
     *  channel rather than stalling the queue forever. */
    private fun loadAndPlayClip(file: String, gain: Float, assign: (Voice?) -> Unit, onFinish: () -> Unit) {
        val cached = synchronized(lock) { bufferCache[file] }
        if (cached != null) { assign(startClip(cached, gain, onFinish)); return }
        val exp = experience
        if (exp == null) { onFinish(); return }
        val token = loadToken
        val target = exp.audioFile(file)
        io.launch {
            val buf = AudioDecoder.decode(target, pcmDir())
            main.post {
                if (token != loadToken || buf == null) { onFinish(); return@post }
                synchronized(lock) { bufferCache[file] = buf }
                assign(startClip(buf, gain, onFinish))
            }
        }
    }

    private fun startClip(buf: PcmBuffer, gain: Float, onFinish: () -> Unit): Voice {
        val v = Voice()
        v.buffer = buf
        v.loop = false
        v.volume = gain
        v.target = gain
        v.onFinish = onFinish
        synchronized(lock) { v.startAtFrame = masterFrame }
        return v
    }

    /** Play the intro once, gated so it doesn't replay when resuming the same walk within an hour. */
    private fun maybePlayIntro() {
        val exp = experience ?: return
        val file = exp.map.intro
        if (file.isNullOrEmpty()) return
        val key = introGateKey(exp.id)
        val now = System.currentTimeMillis() / 1000.0
        if (now - prefs.getFloat(key, 0f).toDouble() < INTRO_GATE_SECONDS) return
        prefs.edit().putFloat(key, now.toFloat()).apply()

        // The intro takes the dialogue channel, so a dialogue the listener is already standing in
        // queues behind it rather than talking over it. Claimed before the clip loads: a fix can land
        // while it decodes, and that fix would otherwise start a dialogue.
        if (dialoguePlaying == null) dialoguePlaying = INTRO_CHANNEL
        loadAndPlayClip(
            file,
            (exp.map.introGain ?: 1.0).toFloat(),
            assign = { v -> introVoice = v },
            onFinish = {
                introVoice = null
                releaseIntroChannel()
            },
        )
    }

    /** Hand the dialogue channel back and start whatever queued while the intro played. */
    private fun releaseIntroChannel() {
        if (dialoguePlaying != INTRO_CHANNEL) return   // already reset by a stop
        dialoguePlaying = null
        advanceDialogue()
    }

    /** Cancel the pending "Play Outro" offer. Used while the walk's intro card is up, so its 30 s
     *  only counts once the listener is actually looking at the map. */
    fun cancelDoneTimer() {
        doneRunnable?.let { main.removeCallbacks(it) }
        doneRunnable = null
        _canEndSession.value = false
    }

    fun armDoneTimer() {
        cancelDoneTimer()
        val r = Runnable { if (_isRunning.value) _canEndSession.value = true }
        doneRunnable = r
        main.postDelayed(r, DONE_DELAY_MS)
    }

    /** End the session: fade any playing dialogue (1 s), play the exit clip while loops continue,
     *  then fade everything out (5 s) and stop. */
    fun endSession() {
        if (!_isRunning.value || outroActive) return
        outroActive = true
        cancelDoneTimer()
        introVoice?.let { synchronized(lock) { it.ended = true } }
        introVoice = null
        fadeDialogueVoices(1.0)
        dialogueQueue.clear()
        dialoguePlaying = null
        main.postDelayed({
            if (!outroActive) return@postDelayed
            val file = experience?.map?.exit
            if (!file.isNullOrEmpty()) {
                loadAndPlayClip(
                    file,
                    (experience?.map?.exitGain ?: 1.0).toFloat(),
                    assign = { v -> exitVoice = v },
                    onFinish = { exitVoice = null; finishOutro() },
                )
            } else finishOutro()
        }, 1000)
    }

    private fun finishOutro() {
        if (!outroActive) return
        fadeAllVoices(5.0)
        main.postDelayed({
            if (!outroActive) return@postDelayed
            outroActive = false
            handleRemoteTransport(false)
        }, 5000)
    }

    private fun fadeDialogueVoices(duration: Double) {
        val ids = voices.keys.filter { id -> shapes.firstOrNull { it.id == id }?.mode == PlaybackMode.DIALOGUE }
        for (id in ids) {
            val v = synchronized(lock) { voices.remove(id) } ?: continue
            fadeOutAndDrop(v, duration)
        }
        refreshSounding()
    }

    private fun fadeAllVoices(duration: Double) {
        val entries = synchronized(lock) { val c = voices.toMap(); voices.clear(); c }
        for ((_, v) in entries) fadeOutAndDrop(v, duration)
        _soundingShapeIds.value = emptySet()
    }

    private fun refreshSounding() {
        // Only count voices heading somewhere audible, so silent synced loops don't light up the map.
        val ids = synchronized(lock) {
            voices.filter { it.value.target > 0.02f }.keys.toSet()
        }
        if (ids != _soundingShapeIds.value) _soundingShapeIds.value = ids
    }

    /** Apply a transport change from outside the app — the notification, a headphone button, an
     *  unplugged route. */
    fun handleRemoteTransport(play: Boolean?) {
        main.post {
            val wantsPlay = play ?: !_isRunning.value
            val toggle = remoteToggle
            if (toggle != null) toggle(wantsPlay)
            else if (wantsPlay) start() else stop()
        }
    }

    fun release() {
        stop()
        abandonFocus()
    }

    /** Clears a walk's intro gate, so a re-download hears the intro again. */
    fun clearIntroGate(walkId: String) {
        prefs.edit().remove(introGateKey(walkId)).apply()
    }
}
