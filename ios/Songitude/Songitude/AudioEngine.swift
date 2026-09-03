import Foundation
import AVFoundation
import MediaPlayer
import CoreLocation
import UIKit

/// The playback / rendering engine. One AVAudioPlayerNode per sounding area, layered through
/// the main mixer. Location updates drive the same loop/oneshot/dialogue state machine as the
/// web editor's preview. Runs in the background (locked, in-pocket) via the audio session +
/// the "audio" background mode; stops only when the app is fully quit or the user pauses.
final class RenderEngine: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var soundingShapeIDs: Set<String> = []
    /// Playback state per dialogue shape id — drives the map's dialogue coloring.
    @Published private(set) var dialogueStates: [String: DialogueState] = [:]
    /// True once the "All done?" (end session) affordance should be offered (30 s after start).
    @Published private(set) var canEndSession = false

    /// Called by the lock-screen / control-center transport. `true` = play, `false` = pause.
    /// Always invoked on the main thread, via `handleRemoteTransport`.
    var remoteToggle: ((Bool) -> Void)?

    private let engine = AVAudioEngine()
    private var bufferCache: [String: AVAudioPCMBuffer] = [:]
    private var crossfadeCache: [String: AVAudioPCMBuffer] = [:]   // baked seamless-loop buffers, keyed by shape id

    private var shapes: [SoundShape] = []
    private var offset: CoordinateOffset = .none
    private var experience: Experience?

    // Audio is decoded off the main thread. loadToken invalidates in-flight decodes when the
    // experience is swapped; lastCoord lets us start loops the moment their clip finishes loading.
    private let loadQueue = DispatchQueue(label: "songitude.audio.load", qos: .userInitiated)
    // Activating / deactivating the audio session is a synchronous IPC to the media server that can
    // block for a long time — `setActive(false, .notifyOthersOnDeactivation)` in particular waits on
    // whatever other app is about to take the route. Serialised here so the order of activate /
    // deactivate is still exactly the order the transport asked for, but off the main thread when it
    // is a release: a lock-screen pause must never be able to wedge the UI.
    private static let sessionQueue = DispatchQueue(label: "songitude.audio.session")
    private var loadToken = 0
    private var lastCoord: CLLocationCoordinate2D?
    private var loadingFiles: Set<String> = []
    private var syncedStarted = false           // synced loops launched (sample-aligned) this session
    /// Host time the synced loops launched at, and the seconds of skipping applied since. A synced
    /// voice's position is derived from these rather than from its own playhead, so a skip lands
    /// every synced clip on the same offset and the sample alignment that defines the mode survives.
    private var syncedEpochHost: UInt64?
    private var syncedShift: TimeInterval = 0
    /// At least one soloed area is engaged (see `soloEngaged`). While that holds, only soloed areas
    /// are audible — every other area they are inside ducks to silence and comes back on the way out.
    private var soloActive = false
    /// Shape ids whose duck factor moved during the current location pass, so the pass doesn't ramp
    /// them a second time and cut a duck fade short.
    private var duckMoved = Set<String>()
    private var wasInterrupted = false           // suspended by the system (call/Siri); resume when it ends
    // Residency thresholds (metres from a region's boundary). Hysteresis: decode when within
    // preload, keep until beyond evict — so pacing back and forth over a line doesn't thrash.
    private static let preloadDistance: CLLocationDistance = 300
    private static let evictDistance: CLLocationDistance = 600

    // per-shape runtime
    private final class Voice {
        let player = AVAudioPlayerNode()
        var timer: Timer?
        var isLoop = false
        var target: Float = 0        // volume the current ramp is heading to (drives the map highlight)
        /// The clip this voice is playing, kept so a skip can reschedule it from a new offset.
        var buffer: AVAudioPCMBuffer?
        /// Frame the current schedule started from. A player node's `sampleTime` restarts at 0 every
        /// time it is stopped and rescheduled, so the offsets have to accumulate here instead.
        var baseFrame: AVAudioFramePosition = 0
        /// Bumped on every reschedule. Completion handlers capture it and bail if it moved, so a
        /// skip can never be mistaken for the clip having played itself out.
        var epoch = 0
        /// What to run when a walk-level clip (intro / exit) ends; re-used when a skip reschedules it.
        var onFinish: (() -> Void)?
    }
    /// `duck` is the solo gain factor last applied to this shape (nil until the first pass), so a
    /// solo switching on or off can be detected and ramped rather than re-applied every fix.
    private struct Runtime { var inside = false; var armed = true; var duck: Float? = nil }

    private var voices: [String: Voice] = [:]
    private var runtimes: [String: Runtime] = [:]
    /// Voices that have already left `voices` and are fading out on their own timer. Tracked so a
    /// teardown can cancel them — a fade that outlives a pause would otherwise detach its node long
    /// after the graph was torn down (and possibly rebuilt) underneath it.
    private var fadingVoices: [Voice] = []

    // Dialogue queue: one dialogue plays at a time; others wait in entry order and play once each.
    private var dialogueQueue: [String] = []
    private var dialoguePlaying: String?

    // Intro / exit (walk-level) clips + end-session flow.
    private var introVoice: Voice?
    private var exitVoice: Voice?
    private var outroActive = false            // exit sequence running — freeze location-driven playback
    private var doneTimer: Timer?
    private static let introGate: TimeInterval = 3600   // don't replay a walk's intro within 1 hour
    /// Holds `dialoguePlaying` while the intro narration runs. It is not a shape id, so every
    /// lookup that maps the channel back to a shape simply finds nothing — which is what keeps the
    /// queue stalled without the intro pretending to be a dialogue.
    private static let introChannel = "__intro__"
    /// Key for a walk's intro gate. Shared so deleting the walk can clear it: a re-download is a
    /// fresh start and has to hear the intro again.
    static let introGateKeyPrefix = "songitude.intro."
    static func introGateKey(_ walkID: String) -> String { introGateKeyPrefix + walkID }
    private static let doneDelay: TimeInterval = 30     // offer "All done?" this long after start

    // MARK: - Session

    init() {
        configureRemoteCommands()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleInterruption(_:)),
                       name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleRouteChange(_:)),
                       name: AVAudioSession.routeChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleConfigChange(_:)),
                       name: .AVAudioEngineConfigurationChange, object: engine)
        nc.addObserver(self, selector: #selector(handleForeground),
                       name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - System audio events (interruptions, route + config changes)

    /// Phone call / Siri / another app grabs the route. On `.began` the engine is already stopped,
    /// so we tear down but remember we were playing; on `.ended` with `.shouldResume` we bring it back.
    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch type {
            case .began:
                guard self.isRunning else { return }
                self.wasInterrupted = true
                self.teardownAudio()
                self.updateNowPlayingPlayback(rate: 0)
            case .ended:
                guard self.wasInterrupted else { return }
                self.wasInterrupted = false
                let opts = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                    .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                if opts.contains(.shouldResume) {
                    if !self.bringUpAudio() { self.isRunning = false; self.updateNowPlayingPlayback(rate: 0) }
                } else {
                    // System says stay paused — make isRunning honest instead of lying "playing".
                    self.isRunning = false
                    self.releaseSession()
                    self.updateNowPlayingPlayback(rate: 0)
                }
            @unknown default: break
            }
        }
    }

    /// Headphones / Bluetooth removed → pause the whole app, per the iOS HIG (don't suddenly
    /// blast a sound walk out of the speaker in someone's pocket).
    @objc private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
              reason == .oldDeviceUnavailable else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.handleRemoteTransport(false)
        }
    }

    /// Coming back to the foreground, make the transport honest. If playback was torn down while we
    /// were away — a lock-screen pause, an interruption the system told us not to resume, or the app
    /// being suspended with the engine already stopped — settle into a clean paused state so the
    /// button reads "play" and actually starts again, instead of claiming to be playing over silence.
    /// A pending auto-resume (a call still in progress) is left alone; that has its own recovery.
    @objc private func handleForeground() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRunning, !self.wasInterrupted, !self.engine.isRunning else { return }
            self.handleRemoteTransport(false)
        }
    }

    /// Hardware format changed underneath us (e.g. a Bluetooth device connected). The engine may
    /// have stopped and node connections gone stale — rebuild the graph so voices keep rendering.
    @objc private func handleConfigChange(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRunning, !self.engine.isRunning else { return }
            self.teardownAudio()
            if !self.bringUpAudio() { self.isRunning = false; self.updateNowPlayingPlayback(rate: 0) }
        }
    }

    /// Claim the session. Runs on `sessionQueue` so it can never overtake a release that was queued
    /// first — the serial queue is what keeps "pause then immediately play" in the right order — but
    /// stays synchronous, because the engine must not start before the session is live.
    private func configureSession() {
        Self.sessionQueue.sync {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .default, options: [])
                try session.setActive(true)
            } catch {
                print("[RenderEngine] session error: \(error)")
            }
        }
    }

    /// Hand the session back. Deliberately fire-and-forget: deactivation can block on the media
    /// server for a long time, and the caller is usually a pause arriving from the lock screen with
    /// the app about to be suspended — blocking the main thread there is what left the app frozen.
    private func releaseSession() {
        Self.sessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: - Loading

    /// Swap in an experience. Audio is NOT preloaded — clips are decoded on demand as the
    /// listener nears each region (see updateResidency), so only nearby audio is ever in memory.
    func load(_ experience: Experience) {
        stop()
        self.experience = experience
        self.shapes = experience.map.shapes
        self.offset = .none
        loadToken &+= 1
        bufferCache.removeAll()
        crossfadeCache.removeAll()
        loadingFiles.removeAll()
        runtimes = Dictionary(uniqueKeysWithValues: shapes.map { ($0.id, Runtime()) })
        resetDialogue()
        updateNowPlayingStatic()
    }

    /// Move the same areas to new coordinates without disturbing playback. Shape ids don't change,
    /// so runtimes, decoded buffers and dialogue history all stay valid — only where each area sits
    /// is different. Used when a transportable walk is re-anchored: `load` would stop the audio and
    /// forget which dialogue had already played.
    func updateGeometry(_ experience: Experience) {
        self.experience = experience
        self.shapes = experience.map.shapes
    }

    func setOffset(_ offset: CoordinateOffset) { self.offset = offset }

    private static func loadBuffer(_ url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url) else {
            print("[RenderEngine] missing audio: \(url.lastPathComponent)")
            return nil
        }
        let fmt = file.processingFormat
        guard file.length > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        do { try file.read(into: buf) } catch { return nil }
        return buf
    }

    /// Bake a seamless crossfade loop: overlap the tail with the head into one `.loops`-able buffer
    /// of length (frames − crossfade). Perceptually identical to the web/editor live-overlap crossfade.
    private static func crossfadeBuffer(_ src: AVAudioPCMBuffer, crossfade: Double) -> AVAudioPCMBuffer? {
        let n = Int(src.frameLength)
        let cf = min(max(Int(crossfade * src.format.sampleRate), 1), n / 2)   // clamp to ≤ half the clip
        let len = n - cf
        guard len > 0, cf > 0,
              let out = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: AVAudioFrameCount(len)),
              let sIn = src.floatChannelData, let sOut = out.floatChannelData else { return nil }
        out.frameLength = AVAudioFrameCount(len)
        for c in 0..<Int(src.format.channelCount) {
            let inp = sIn[c], outp = sOut[c]
            for i in cf..<len { outp[i] = inp[i] }                      // body plays straight
            for i in 0..<cf {                                            // crossfade: head fades in, tail fades out
                let f = Float(i) / Float(cf)
                outp[i] = inp[i] * f + inp[len + i] * (1 - f)
            }
        }
        return out
    }

    /// A copy of `src` from `frame` to its end. Starting an already-decoded buffer partway through
    /// needs one: `scheduleSegment` reads from a file, and there is no buffer equivalent. It is
    /// transient — the player releases it once played, and a loop returns to the full clip after.
    private static func tailBuffer(_ src: AVAudioPCMBuffer, from frame: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        let start = Int(max(0, min(frame, AVAudioFramePosition(src.frameLength))))
        let len = Int(src.frameLength) - start
        guard len > 0,
              let out = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: AVAudioFrameCount(len)),
              let sIn = src.floatChannelData, let sOut = out.floatChannelData else { return nil }
        out.frameLength = AVAudioFrameCount(len)
        for c in 0..<Int(src.format.channelCount) { sOut[c].update(from: sIn[c] + start, count: len) }
        return out
    }

    /// The buffer a loop should schedule: the raw clip, or a cached baked crossfade buffer for a
    /// crossfade loop (keyed by shape id since the crossfade time is per shape).
    private func crossfadeBufferFor(_ shape: SoundShape, _ raw: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        if let cached = crossfadeCache[shape.id] { return cached }
        let baked = Self.crossfadeBuffer(raw, crossfade: shape.crossfade) ?? raw
        crossfadeCache[shape.id] = baked
        return baked
    }

    // MARK: - Transport (the big play/pause button)

    func start() {
        guard !isRunning else { return }
        wasInterrupted = false
        isRunning = true             // set before bring-up so the isRunning-gated helpers run
        if bringUpAudio() {
            maybePlayIntro()         // fresh session (not an interruption resume) → intro + "All done?" timer
            armDoneTimer()
        } else {
            isRunning = false
        }
    }

    func stop() {
        guard isRunning || !voices.isEmpty else { return }
        wasInterrupted = false       // a manual stop cancels any pending auto-resume
        doneTimer?.invalidate(); doneTimer = nil
        canEndSession = false
        outroActive = false
        teardownAudio()
        isRunning = false
        releaseSession()
        updateNowPlayingPlayback(rate: 0)
    }

    /// Activate the session + engine and resume region evaluation from the last known fix.
    /// Shared by start() and by interruption / config-change recovery. Assumes isRunning is set.
    @discardableResult
    private func bringUpAudio() -> Bool {
        configureSession()
        // Realize the main mixer -> output connection while the engine is stopped, so the first
        // voice that attaches later doesn't mutate the graph mid-render.
        engine.mainMixerNode.outputVolume = 1.0
        engine.prepare()
        do { try engine.start() } catch {
            // The graph can be left stale by a suspend/resume cycle (typically a lock-screen pause
            // followed by the app being suspended). Reset it and try once more before giving up,
            // so hitting play after that doesn't just silently do nothing.
            print("[RenderEngine] start error: \(error) — resetting and retrying")
            engine.reset()
            engine.prepare()
            do { try engine.start() } catch {
                print("[RenderEngine] start failed after reset: \(error)")
                return false
            }
        }
        ensureSyncedLoops()          // begin loading + (once ready) launch synced loops in lock-step
        if let c = lastCoord { updateLocation(c) }   // resume region audio without waiting for a fix
        updateNowPlayingPlayback(rate: 1)
        return true
    }

    /// Stop and detach every voice and free audio memory, leaving isRunning / the loaded
    /// experience untouched. Used by stop() and by system-driven suspend/rebuild.
    private func teardownAudio() {
        for (id, _) in voices { hardStopVoice(id) }
        voices.removeAll()
        // Fades already in flight own their nodes, so they have to be cancelled here too — otherwise
        // their timer fires after the graph is gone and detaches into whatever replaced it.
        for voice in fadingVoices { detach(voice) }
        fadingVoices.removeAll()
        if let v = introVoice { detach(v); introVoice = nil }
        if let v = exitVoice { detach(v); exitVoice = nil }
        for id in runtimes.keys { runtimes[id] = Runtime() }
        soloActive = false
        duckMoved.removeAll()
        soundingShapeIDs = []
        engine.stop()
        loadToken &+= 1              // invalidate any in-flight decodes
        bufferCache.removeAll()      // free all audio memory while paused
        crossfadeCache.removeAll()
        loadingFiles.removeAll()
        syncedStarted = false
        syncedEpochHost = nil
        syncedShift = 0
        suspendDialogue()
    }

    func toggle() { isRunning ? stop() : start() }

    // MARK: - Location driven state machine

    func updateLocation(_ coord: CLLocationCoordinate2D) {
        lastCoord = coord
        guard isRunning, !outroActive else { return }   // freeze location-driven playback during the outro
        updateResidency(coord)      // decode nearby clips, evict distant ones
        startSyncedLoopsIfReady()
        var nowInside = Set<String>()
        for shape in shapes where GeoUtils.contains(shape, coord: coord, offset: offset) {
            nowInside.insert(shape.id)
        }
        // Solo latch first: a duck that just came on or went off has to move voices that otherwise
        // set their volume once (one-shots, dialogue) or hold a constant level (loops with no
        // falloff). Anything it already ramped is left alone below so its duck fade isn't cut short.
        duckMoved.removeAll()
        applySolo(inside: nowInside)

        for shape in shapes {
            var rt = runtimes[shape.id] ?? Runtime()
            let isIn = nowInside.contains(shape.id)
            let rising = isIn && !rt.inside
            let duck = duckFactor(shape)

            switch shape.mode {
            case .loop:
                if isIn {
                    let target = Float(shape.gain * loopLevel(shape, coord: coord)) * duck
                    if voices[shape.id] == nil { startLoop(shape, target: target) }
                    else if !duckMoved.contains(shape.id) { setLoopTarget(shape, target: target) }
                } else if voices[shape.id] != nil {
                    stopLoop(shape)
                }
            case .oneshot:
                if rising && rt.armed { playOnce(shape); rt.armed = false }
                if !isIn { rt.armed = true }
            case .dialogue:
                // Play once ever; if a dialogue is already sounding, queue and play when it ends.
                if rising && (dialogueStates[shape.id] ?? .unplayed) == .unplayed {
                    setDialogueState(shape.id, .queued)
                    dialogueQueue.append(shape.id)
                    advanceDialogue()
                }
            case .syncedLoop:
                // Never starts/stops here — it's already running in sync; we only gate its volume.
                if !duckMoved.contains(shape.id), let voice = voices[shape.id] {
                    let target = isIn ? Float(shape.gain * loopLevel(shape, coord: coord)) * duck : 0
                    let dur: TimeInterval = rising ? max(0.02, shape.fadeIn)
                        : (rt.inside && !isIn ? max(0.02, shape.fadeOut) : 0.12)
                    ramp(voice, to: target, duration: dur)
                }
            }
            rt.inside = isIn
            // A dialogue starting mid-pass re-runs applySolo, which writes this shape's duck
            // straight into `runtimes` — keep that rather than the copy taken before the switch.
            rt.duck = runtimes[shape.id]?.duck ?? rt.duck
            runtimes[shape.id] = rt
        }
        refreshSounding()
    }

    // MARK: - Proximity residency (decode nearby audio, free distant audio)

    private func syncedFileSet() -> Set<String> {
        Set(shapes.filter { $0.mode == .syncedLoop }.compactMap { $0.audioFile })
    }

    private func updateResidency(_ coord: CLLocationCoordinate2D) {
        let synced = syncedFileSet()                     // synced loops must stay resident to hold sync
        let files = Set(shapes.compactMap { $0.audioFile })
        for file in files {
            let d = synced.contains(file) ? 0 : fileDistance(file, coord: coord)
            if bufferCache[file] == nil {
                if !loadingFiles.contains(file) && d <= Self.preloadDistance { loadFile(file) }
            } else if !synced.contains(file) && d > Self.evictDistance && !fileInUse(file) {
                bufferCache.removeValue(forKey: file)   // release memory for far-away audio
                for s in shapes where s.audioFile == file { crossfadeCache.removeValue(forKey: s.id) }
            }
        }
    }

    private func loadFile(_ file: String) {
        guard let exp = experience else { return }
        loadingFiles.insert(file)
        let url = exp.audioURL(for: file)
        let token = loadToken
        loadQueue.async { [weak self] in
            let buf = Self.loadBuffer(url)          // decode off the main thread
            DispatchQueue.main.async {
                guard let self = self, token == self.loadToken else { return }
                self.loadingFiles.remove(file)
                guard let buf = buf else { return }
                self.bufferCache[file] = buf
                self.startSyncedLoopsIfReady()          // maybe the last synced clip just arrived
                // Start a queued dialogue that was waiting on this clip to decode.
                if let p = self.dialoguePlaying, self.voices[p] == nil,
                   let sh = self.shapes.first(where: { $0.id == p }), sh.audioFile == file {
                    self.tryStartDialogue(sh)
                }
                // Kick a loop that was waiting on this clip, without waiting for the next GPS fix.
                if self.isRunning, let c = self.lastCoord { self.updateLocation(c) }
            }
        }
    }

    // MARK: - Synced loops (sample-aligned, always running, volume gated by location)

    /// Start loading synced clips and, once every one is resident, launch them together.
    private func ensureSyncedLoops() {
        guard isRunning else { return }
        for f in syncedFileSet() where bufferCache[f] == nil && !loadingFiles.contains(f) { loadFile(f) }
        startSyncedLoopsIfReady()
    }

    private func startSyncedLoopsIfReady() {
        guard isRunning, !syncedStarted else { return }
        let files = syncedFileSet()
        guard !files.isEmpty else { syncedStarted = true; return }
        guard files.allSatisfy({ bufferCache[$0] != nil }) else { return }   // wait for every clip
        // One common host time → all synced players begin on the exact same sample.
        let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.15))
        for shape in shapes where shape.mode == .syncedLoop {
            guard let file = shape.audioFile, let buf = bufferCache[file], voices[shape.id] == nil else { continue }
            let voice = Voice(); voice.isLoop = true
            voice.buffer = buf
            attach(voice, format: buf.format)
            voice.player.scheduleBuffer(buf, at: nil, options: [.loops], completionHandler: nil)
            voice.player.volume = 0                    // silent but running until the listener enters
            voices[shape.id] = voice
            voice.player.play(at: start)
        }
        syncedEpochHost = start.hostTime
        syncedShift = 0
        syncedStarted = true
        refreshSounding()
    }

    /// Nearest distance (m) from `coord` to any region that uses `file`; 0 if inside one.
    private func fileDistance(_ file: String, coord: CLLocationCoordinate2D) -> CLLocationDistance {
        var best = CLLocationDistance.greatestFiniteMagnitude
        for shape in shapes where shape.audioFile == file {
            best = min(best, regionDistance(shape, coord: coord))
        }
        return best
    }

    private func regionDistance(_ shape: SoundShape, coord: CLLocationCoordinate2D) -> CLLocationDistance {
        switch shape.type {
        case .circle:
            guard let c = shape.centerCoord, let r = shape.radius else { return .greatestFiniteMagnitude }
            return max(0, GeoUtils.distance(offset.apply(c), coord) - r)
        case .polygon:
            let ring = shape.ringCoords.map { offset.apply($0) }
            guard ring.count >= 3 else { return .greatestFiniteMagnitude }
            if GeoUtils.pointInPolygon(coord, ring: ring) { return 0 }
            return ring.map { GeoUtils.distance($0, coord) }.min() ?? .greatestFiniteMagnitude
        }
    }

    /// True if a currently-playing voice uses `file` (so we must not evict it).
    private func fileInUse(_ file: String) -> Bool {
        for id in voices.keys where shapes.first(where: { $0.id == id })?.audioFile == file { return true }
        // Keep clips for dialogue that's queued or playing so they're ready when their turn comes.
        let pending = dialogueQueue + (dialoguePlaying.map { [$0] } ?? [])
        for id in pending where shapes.first(where: { $0.id == id })?.audioFile == file { return true }
        return false
    }

    // MARK: - Voice control

    /// Solo multiplier: 0 while a solo elsewhere is ducking this shape, 1 otherwise. A duck is a
    /// gain change, never a stop — the ducked voice keeps running underneath so it returns exactly
    /// where it would have been. Deliberately uniform across every mode, dialogue included: a
    /// ducked dialogue keeps advancing silently rather than being cut or replayed.
    private func duckFactor(_ shape: SoundShape) -> Float {
        (soloActive && !shape.solo) ? 0 : 1
    }

    /// Is this shape's solo engaging the duck right now? Containment is the test for every mode but
    /// dialogue: a dialogue only *queues* on entry and plays once ever, so a soloed dialogue must
    /// duck the walk while its own clip sounds — not while it waits its turn, and not once it has
    /// finished. `inside` is the fresh containment set during a location pass; without it we use the
    /// last one seen, which is what a dialogue starting between location fixes needs.
    private func soloEngaged(_ shape: SoundShape, inside: Set<String>?) -> Bool {
        guard shape.solo else { return false }
        if shape.mode == .dialogue { return (dialogueStates[shape.id] ?? .unplayed) == .playing }
        return inside?.contains(shape.id) ?? (runtimes[shape.id]?.inside ?? false)
    }

    /// Recompute the solo latch and move every voice whose duck factor changed. Called from the
    /// location pass and from the dialogue queue (start/finish), since a soloed dialogue engages and
    /// releases the duck between location fixes. Ducking in and out uses the ducked shape's own
    /// fades, so it sounds like leaving and re-entering it.
    private func applySolo(inside: Set<String>? = nil) {
        soloActive = shapes.contains { soloEngaged($0, inside: inside) }
        for shape in shapes {
            var rt = runtimes[shape.id] ?? Runtime()
            let duck = duckFactor(shape)
            // Only act once a baseline is recorded — the first pass just notes where this shape sits.
            let changed = rt.duck != nil && rt.duck != duck
            rt.duck = duck
            runtimes[shape.id] = rt
            guard changed else { continue }
            duckMoved.insert(shape.id)
            guard let voice = voices[shape.id] else { continue }
            let isIn = inside?.contains(shape.id) ?? rt.inside
            let target: Float
            switch shape.mode {
            case .loop, .syncedLoop:
                if isIn, let c = lastCoord { target = Float(shape.gain * loopLevel(shape, coord: c)) * duck }
                else { target = 0 }
            case .oneshot, .dialogue:
                target = Float(shape.gain) * duck
            }
            ramp(voice, to: target, duration: duck > 0 ? max(0.02, shape.fadeIn) : max(0.02, shape.fadeOut))
        }
    }

    /// Proximity multiplier (0..1) for a circle loop with a falloff profile; 1 otherwise.
    private func loopLevel(_ shape: SoundShape, coord: CLLocationCoordinate2D) -> Double {
        guard shape.type == .circle, shape.falloff != .none,
              let c = shape.centerCoord, let r = shape.radius, r > 0 else { return 1 }
        let d = GeoUtils.distance(offset.apply(c), coord)
        return shape.falloff.level(d / r)
    }

    private func startLoop(_ shape: SoundShape, target: Float) {
        guard let file = shape.audioFile, let raw = bufferCache[file] else { return }
        // Crossfade loops schedule a baked seamless buffer; simple loops schedule the raw clip.
        let buf = shape.isCrossfadeLoop ? crossfadeBufferFor(shape, raw) : raw
        let voice = Voice(); voice.isLoop = true
        voice.buffer = buf
        attach(voice, format: buf.format)
        voice.player.scheduleBuffer(buf, at: nil, options: [.loops], completionHandler: nil)
        voice.player.volume = 0
        voice.player.play()
        voices[shape.id] = voice
        ramp(voice, to: target, duration: max(0.02, shape.fadeIn))
    }

    /// Track proximity gain as the listener moves within a falloff circle (no-op for plain loops).
    private func setLoopTarget(_ shape: SoundShape, target: Float) {
        guard shape.type == .circle, shape.falloff != .none, let voice = voices[shape.id] else { return }
        ramp(voice, to: target, duration: 0.12)
    }

    private func stopLoop(_ shape: SoundShape) {
        guard let voice = voices[shape.id] else { return }
        voices.removeValue(forKey: shape.id)
        fadeOutAndDetach(voice, duration: max(0.02, shape.fadeOut))
    }

    /// Fade a voice that has already left `voices` down to silence and detach it. Registered in
    /// `fadingVoices` for the duration so a teardown mid-fade can cancel it.
    private func fadeOutAndDetach(_ voice: Voice, duration: TimeInterval) {
        fadingVoices.append(voice)
        ramp(voice, to: 0, duration: duration) { [weak self] in
            guard let self = self else { return }
            self.fadingVoices.removeAll { $0 === voice }
            self.detach(voice)
        }
    }

    private func playOnce(_ shape: SoundShape) {
        guard let file = shape.audioFile, let buf = bufferCache[file] else { return }
        let voice = Voice(); voice.isLoop = false
        voice.buffer = buf
        attach(voice, format: buf.format)
        let level = Float(shape.gain) * duckFactor(shape)
        voice.player.volume = level
        voice.target = level
        voices[shape.id] = voice
        scheduleOnce(voice, buf: buf, from: 0, shape: shape)
        voice.player.play()
    }

    // MARK: - Skip (the ±15 s buttons)

    /// How far one press of a skip button moves every voice.
    static let skipInterval: TimeInterval = 15

    /// Move every sounding clip `delta` seconds through its own playback — forward on a positive
    /// delta, back on a negative one.
    ///
    /// This is only ever a playhead move. It does not rewind the listener's position, revisit areas
    /// they have walked out of, or start anything that isn't already sounding: what you hear is
    /// exactly what was playing a moment ago, further along or further back.
    ///
    /// The modes differ only in what the ends of a clip mean. A loop wraps in both directions. A
    /// one-shot or a dialogue can't wrap — it is meant to be heard once through — so rewinding past
    /// its start restarts it from the top, and skipping past its end counts as having heard it out.
    func skip(by delta: TimeInterval) {
        // The outro is a timed sequence (fade → clip → fade → stop); moving its audio underneath
        // those timers would only desynchronise them from what is actually playing.
        guard isRunning, !outroActive, delta != 0 else { return }

        // Every synced loop is rescheduled against one common host time a beat in the future, so
        // they resume in lock-step instead of drifting apart by however long this loop takes.
        let syncedStart = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.15))
        syncedShift += delta

        for (id, voice) in voices {
            guard let shape = shapes.first(where: { $0.id == id }) else { continue }
            switch shape.mode {
            case .syncedLoop:          skipSynced(voice, to: syncedStart)
            case .loop:                skipLoop(voice, by: delta)
            case .oneshot, .dialogue:  skipOnce(voice, shape: shape, by: delta)
            }
        }
        // The walk's intro is a clip like any other, so it moves with everything else.
        if let voice = introVoice { skipClip(voice, by: delta) }
        refreshSounding()
    }

    /// Frames of its clip this voice has played, across every reschedule.
    private func playhead(_ voice: Voice) -> AVAudioFramePosition {
        guard let nodeTime = voice.player.lastRenderTime,
              let played = voice.player.playerTime(forNodeTime: nodeTime) else { return voice.baseFrame }
        return voice.baseFrame + max(0, played.sampleTime)
    }

    /// The frame `delta` seconds from where `voice` is now. `wrap` folds it back into the clip, for
    /// the modes that loop; without it the frame can land outside the clip and the caller decides
    /// what that means.
    private func skipTarget(_ voice: Voice, by delta: TimeInterval,
                            wrap: Bool) -> (frame: AVAudioFramePosition, buffer: AVAudioPCMBuffer)? {
        guard let buf = voice.buffer else { return nil }
        let length = AVAudioFramePosition(buf.frameLength)
        guard length > 0 else { return nil }
        var frame = playhead(voice) + AVAudioFramePosition(delta * buf.format.sampleRate)
        if wrap {
            frame %= length
            if frame < 0 { frame += length }        // a rewind past the top comes round to the tail
        }
        return (frame, buf)
    }

    /// Reschedule a looping voice from `frame`: the rest of the clip once, then the whole clip on
    /// repeat — which is the shape the original schedule had. Volume, and any ramp in flight, are
    /// untouched: only the playhead moves.
    private func rescheduleLoop(_ voice: Voice, buf: AVAudioPCMBuffer, from frame: AVAudioFramePosition) {
        voice.epoch &+= 1
        voice.player.stop()          // resets the node's sampleTime, which is why baseFrame exists
        voice.baseFrame = frame
        // The rest of this pass through the clip, then the whole clip on repeat from there on.
        if frame > 0, let tail = Self.tailBuffer(buf, from: frame) {
            voice.player.scheduleBuffer(tail, at: nil, options: [], completionHandler: nil)
        }
        voice.player.scheduleBuffer(buf, at: nil, options: [.loops], completionHandler: nil)
    }

    private func skipLoop(_ voice: Voice, by delta: TimeInterval) {
        guard let t = skipTarget(voice, by: delta, wrap: true) else { return }
        rescheduleLoop(voice, buf: t.buffer, from: t.frame)
        voice.player.play()
    }

    /// A synced loop takes its new position from the shared launch instant rather than its own
    /// playhead, so every synced clip lands on the same offset and they stay aligned with each other.
    private func skipSynced(_ voice: Voice, to when: AVAudioTime) {
        guard let buf = voice.buffer, let launched = syncedEpochHost, when.hostTime > launched else { return }
        let rate = buf.format.sampleRate
        let duration = Double(buf.frameLength) / rate
        guard duration > 0 else { return }
        let elapsed = AVAudioTime.seconds(forHostTime: when.hostTime - launched) + syncedShift
        var position = elapsed.truncatingRemainder(dividingBy: duration)
        if position < 0 { position += duration }
        rescheduleLoop(voice, buf: buf, from: AVAudioFramePosition(position * rate))
        voice.player.play(at: when)
    }

    private func skipOnce(_ voice: Voice, shape: SoundShape, by delta: TimeInterval) {
        guard let t = skipTarget(voice, by: delta, wrap: false) else { return }
        voice.epoch &+= 1
        voice.player.stop()
        // Past the end of a play-once clip is the same as having heard it through.
        guard t.frame < AVAudioFramePosition(t.buffer.frameLength) else { finishOnce(shape, voice); return }
        scheduleOnce(voice, buf: t.buffer, from: max(0, t.frame), shape: shape)   // before the top ⇒ from the top
        voice.player.play()
    }

    private func skipClip(_ voice: Voice, by delta: TimeInterval) {
        guard let t = skipTarget(voice, by: delta, wrap: false) else { return }
        voice.epoch &+= 1
        voice.player.stop()
        guard t.frame < AVAudioFramePosition(t.buffer.frameLength) else { voice.onFinish?(); return }
        scheduleClip(voice, from: max(0, t.frame))
        voice.player.play()
    }

    /// Schedule a play-once clip (one-shot or dialogue) from `from`. The completion handler is
    /// guarded on the voice's epoch so a skip that reschedules it doesn't read as the clip ending.
    private func scheduleOnce(_ voice: Voice, buf: AVAudioPCMBuffer,
                              from: AVAudioFramePosition, shape: SoundShape) {
        let epoch = voice.epoch
        voice.baseFrame = from
        guard let part = (from == 0 ? buf : Self.tailBuffer(buf, from: from)) else { finishOnce(shape, voice); return }
        voice.player.scheduleBuffer(part, at: nil, options: []) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, voice.epoch == epoch, self.voices[shape.id] === voice else { return }
                self.finishOnce(shape, voice)
            }
        }
    }

    /// A play-once clip is over — by playing out, or by being skipped past its end.
    private func finishOnce(_ shape: SoundShape, _ voice: Voice) {
        if voices[shape.id] === voice { voices.removeValue(forKey: shape.id) }
        detach(voice)
        if shape.mode == .dialogue { finishDialogue(shape.id) } else { refreshSounding() }
    }

    // MARK: - Dialogue queue (one at a time, play once, FIFO)

    private func setDialogueState(_ id: String, _ state: DialogueState) { dialogueStates[id] = state }

    /// Start the next queued dialogue if none is currently sounding.
    private func advanceDialogue() {
        guard dialoguePlaying == nil, !dialogueQueue.isEmpty else { return }
        let id = dialogueQueue.removeFirst()
        guard let shape = shapes.first(where: { $0.id == id }) else { advanceDialogue(); return }
        dialoguePlaying = id
        setDialogueState(id, .playing)
        tryStartDialogue(shape)
    }

    /// Schedule the playing dialogue's clip. If its buffer isn't resident yet, request it and start
    /// when it arrives (loadFile's completion calls back here).
    private func tryStartDialogue(_ shape: SoundShape) {
        guard dialoguePlaying == shape.id, voices[shape.id] == nil else { return }
        guard let file = shape.audioFile else { finishDialogue(shape.id); return }
        guard let buf = bufferCache[file] else {
            if !loadingFiles.contains(file) { loadFile(file) }
            return
        }
        let voice = Voice(); voice.isLoop = false
        voice.buffer = buf
        attach(voice, format: buf.format)
        let level = Float(shape.gain) * duckFactor(shape)
        voice.player.volume = level
        voice.target = level
        voices[shape.id] = voice
        scheduleOnce(voice, buf: buf, from: 0, shape: shape)
        voice.player.play()
        // A soloed dialogue engages the duck only now, as its clip starts — entering its area merely
        // queued it, and the location pass that queued it is long over.
        applySolo()
        refreshSounding()
    }

    private func finishDialogue(_ id: String) {
        if dialoguePlaying == id { dialoguePlaying = nil }
        setDialogueState(id, .finished)
        refreshSounding()
        advanceDialogue()
        // A soloed dialogue's duck ends with its clip. Recompute after the queue has moved on, so
        // handing over to another soloed dialogue doesn't blip the duck off and straight back on.
        applySolo()
    }

    /// Fresh start (new experience): every dialogue back to unplayed, queue empty.
    private func resetDialogue() {
        dialogueQueue.removeAll()
        dialoguePlaying = nil
        dialogueStates = Dictionary(uniqueKeysWithValues:
            shapes.filter { $0.mode == .dialogue }.map { ($0.id, DialogueState.unplayed) })
    }

    /// System suspend / user pause: drop the queue and let anything not fully played run again later.
    private func suspendDialogue() {
        dialogueQueue.removeAll()
        dialoguePlaying = nil
        for (id, st) in dialogueStates where st == .queued || st == .playing { dialogueStates[id] = .unplayed }
    }

    // MARK: - Intro / exit (walk-level) clips + end session

    /// Decode a walk-level clip (off the main thread if needed) and play it once at full volume.
    /// `assign` receives the voice; `onFinish` fires when the clip ends (or immediately if it can't load).
    private func loadAndPlayClip(_ file: String, gain: Float, assign: @escaping (Voice?) -> Void, onFinish: @escaping () -> Void) {
        if let buf = bufferCache[file] { assign(startClip(buf, gain: gain, onFinish: onFinish)); return }
        guard let exp = experience else { onFinish(); return }
        let url = exp.audioURL(for: file)
        let token = loadToken
        loadQueue.async { [weak self] in
            let buf = Self.loadBuffer(url)
            DispatchQueue.main.async {
                guard let self = self, token == self.loadToken, let buf = buf else { onFinish(); return }
                self.bufferCache[file] = buf
                assign(self.startClip(buf, gain: gain, onFinish: onFinish))
            }
        }
    }

    private func startClip(_ buf: AVAudioPCMBuffer, gain: Float, onFinish: @escaping () -> Void) -> Voice {
        let voice = Voice()
        voice.buffer = buf
        voice.onFinish = onFinish
        attach(voice, format: buf.format)
        voice.player.volume = gain
        scheduleClip(voice, from: 0)
        voice.player.play()
        return voice
    }

    /// Schedule a walk-level clip from `from`, guarded on the voice's epoch so a skip that
    /// reschedules it doesn't fire the finish handler belonging to the schedule it replaced.
    private func scheduleClip(_ voice: Voice, from: AVAudioFramePosition) {
        guard let buf = voice.buffer else { return }
        let epoch = voice.epoch
        voice.baseFrame = from
        guard let part = (from == 0 ? buf : Self.tailBuffer(buf, from: from)) else { voice.onFinish?(); return }
        voice.player.scheduleBuffer(part, at: nil, options: []) {
            DispatchQueue.main.async { if voice.epoch == epoch { voice.onFinish?() } }
        }
    }

    /// Play the intro clip once, gated so it doesn't replay when resuming the same walk within an hour.
    private func maybePlayIntro() {
        guard let exp = experience, let file = exp.map.intro, !file.isEmpty else { return }
        let key = Self.introGateKey(exp.id)
        let now = Date().timeIntervalSince1970
        if now - UserDefaults.standard.double(forKey: key) < Self.introGate { return }
        UserDefaults.standard.set(now, forKey: key)
        // The intro takes the dialogue channel, so a dialogue the listener is already standing in
        // queues behind it rather than talking over it. Claimed before the clip loads: a GPS fix
        // can land while it decodes, and that fix would otherwise start a dialogue. The intro fires
        // at session start with the channel free; the guard just means a dialogue somehow already
        // speaking keeps the channel it holds.
        if dialoguePlaying == nil { dialoguePlaying = Self.introChannel }
        loadAndPlayClip(file, gain: Float(exp.map.introGain ?? 1.0),
                        assign: { [weak self] v in self?.introVoice = v },
                        onFinish: { [weak self] in
                            if let v = self?.introVoice { self?.detach(v) }
                            self?.introVoice = nil
                            self?.releaseIntroChannel()
                        })
    }

    /// Hand the dialogue channel back and start whatever queued up while the intro played.
    /// `loadAndPlayClip` calls its finish handler even when the clip can't load, so a missing or
    /// undecodable intro releases the channel instead of stalling the queue forever.
    private func releaseIntroChannel() {
        guard dialoguePlaying == Self.introChannel else { return }   // already reset by a stop
        dialoguePlaying = nil
        advanceDialogue()
    }

    /// Cancel the pending "All done?" offer. Used while a modal (the walk's intro card) is up, so
    /// its 30 s only starts counting once the listener is actually looking at the map.
    func cancelDoneTimer() {
        doneTimer?.invalidate(); doneTimer = nil
        canEndSession = false
    }

    func armDoneTimer() {
        doneTimer?.invalidate()
        canEndSession = false
        doneTimer = Timer.scheduledTimer(withTimeInterval: Self.doneDelay, repeats: false) { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            self.canEndSession = true
        }
    }

    /// End the session: fade any playing dialogue (1 s), play the exit clip while loops continue,
    /// then fade everything out (5 s) and stop.
    func endSession() {
        guard isRunning, !outroActive else { return }
        outroActive = true
        canEndSession = false
        doneTimer?.invalidate(); doneTimer = nil
        if let v = introVoice { detach(v); introVoice = nil }   // stop intro narration if still going
        fadeDialogueVoices(duration: 1.0)
        dialogueQueue.removeAll(); dialoguePlaying = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.outroActive else { return }
            if let file = self.experience?.map.exit, !file.isEmpty {
                self.loadAndPlayClip(file, gain: Float(self.experience?.map.exitGain ?? 1.0),
                                     assign: { [weak self] v in self?.exitVoice = v },
                                     onFinish: { [weak self] in
                                         if let v = self?.exitVoice { self?.detach(v) }
                                         self?.exitVoice = nil
                                         self?.finishOutro()
                                     })
            } else {
                self.finishOutro()
            }
        }
    }

    private func finishOutro() {
        guard outroActive else { return }
        fadeAllVoices(duration: 5.0)     // everything else fades out
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self, self.outroActive else { return }
            self.outroActive = false
            self.handleRemoteTransport(false)     // end the whole session
        }
    }

    private func fadeDialogueVoices(duration: TimeInterval) {
        for id in Array(voices.keys) where shapes.first(where: { $0.id == id })?.mode == .dialogue {
            if let voice = voices.removeValue(forKey: id) {
                fadeOutAndDetach(voice, duration: duration)
            }
        }
        refreshSounding()
    }

    private func fadeAllVoices(duration: TimeInterval) {
        let entries = voices; voices.removeAll()
        for (_, voice) in entries {
            fadeOutAndDetach(voice, duration: duration)
        }
        soundingShapeIDs = []
    }

    private func attach(_ voice: Voice, format: AVAudioFormat) {
        engine.attach(voice.player)
        engine.connect(voice.player, to: engine.mainMixerNode, format: format)
    }

    private func detach(_ voice: Voice) {
        voice.timer?.invalidate(); voice.timer = nil
        voice.player.stop()
        engine.detach(voice.player)
    }

    private func hardStopVoice(_ id: String) {
        guard let voice = voices[id] else { return }
        detach(voice)
    }

    /// Linear volume ramp on the audio queue via a stepping timer.
    private func ramp(_ voice: Voice, to target: Float, duration: TimeInterval, completion: (() -> Void)? = nil) {
        voice.timer?.invalidate()
        voice.target = target
        let start = voice.player.volume
        let steps = max(1, Int(duration / 0.03))
        var step = 0
        voice.timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { t in
            step += 1
            let f = Float(step) / Float(steps)
            voice.player.volume = start + (target - start) * min(f, 1)
            if step >= steps {
                t.invalidate(); voice.timer = nil
                voice.player.volume = target
                completion?()
            }
        }
        if let timer = voice.timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func refreshSounding() {
        // Only count voices that are (heading) audible, so silent synced loops don't light up the map.
        let ids = Set(voices.compactMap { $0.value.target > 0.02 ? $0.key : nil })
        if ids != soundingShapeIDs { soundingShapeIDs = ids }
    }

    // MARK: - Now Playing (lock screen)

    private func updateNowPlayingStatic() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = experience?.displayName ?? "Songitude"
        info[MPMediaItemPropertyArtist] = "Songitude · live"
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        if let url = experience?.albumArtURL, let img = UIImage(contentsOfFile: url.path) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingPlayback(rate: Double) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = rate > 0 ? .playing : .paused
    }

    /// Apply a transport change that came from outside the app — the lock screen, Control Centre, a
    /// headphone button, an unplugged route. `play == nil` means "toggle", resolved on the main
    /// thread so it reads the state that is actually current rather than whatever the command thread
    /// happened to see.
    ///
    /// The background task assertion is the important part. Pausing stops the engine and drops the
    /// location updates, which removes both of the reasons iOS was keeping the app alive — so the
    /// system is free to suspend it *during* the teardown that pause kicked off. Being suspended
    /// part-way through tearing down the graph and handing back the audio session is what left the
    /// app wedged and ignoring touches the next time it came forward. Holding the assertion until
    /// the teardown has drained lets it finish first, and the app then suspends cleanly paused.
    private func handleRemoteTransport(_ play: Bool?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let wantsPlay = play ?? !self.isRunning

            var task: UIBackgroundTaskIdentifier = .invalid
            let finish = {
                guard task != .invalid else { return }
                UIApplication.shared.endBackgroundTask(task)
                task = .invalid
            }
            if UIApplication.shared.applicationState != .active {
                task = UIApplication.shared.beginBackgroundTask(withName: "songitude.transport") { finish() }
            }

            if let toggle = self.remoteToggle { toggle(wantsPlay) }
            else if wantsPlay { self.start() } else { self.stop() }

            // Fades, detaches and the session release are all queued work; give them room to land
            // before handing the time back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish() }
        }
    }

    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.handleRemoteTransport(true); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.handleRemoteTransport(false); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.handleRemoteTransport(nil); return .success
        }
        // Not a seekable medium — disable scrubbing transport.
        c.changePlaybackPositionCommand.isEnabled = false
        c.nextTrackCommand.isEnabled = false
        c.previousTrackCommand.isEnabled = false
    }
}
