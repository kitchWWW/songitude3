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
    private var loadToken = 0
    private var lastCoord: CLLocationCoordinate2D?
    private var loadingFiles: Set<String> = []
    private var syncedStarted = false           // synced loops launched (sample-aligned) this session
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
    }
    private struct Runtime { var inside = false; var armed = true }

    private var voices: [String: Voice] = [:]
    private var runtimes: [String: Runtime] = [:]

    // Dialogue queue: one dialogue plays at a time; others wait in entry order and play once each.
    private var dialogueQueue: [String] = []
    private var dialoguePlaying: String?

    // Intro / exit (walk-level) clips + end-session flow.
    private var introVoice: Voice?
    private var exitVoice: Voice?
    private var outroActive = false            // exit sequence running — freeze location-driven playback
    private var doneTimer: Timer?
    private static let introGate: TimeInterval = 3600   // don't replay a walk's intro within 1 hour
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
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
            if let toggle = self.remoteToggle { toggle(false) } else { self.stop() }
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

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("[RenderEngine] session error: \(error)")
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
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
        do { try engine.start() } catch { print("[RenderEngine] start error: \(error)"); return false }
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
        if let v = introVoice { detach(v); introVoice = nil }
        if let v = exitVoice { detach(v); exitVoice = nil }
        for id in runtimes.keys { runtimes[id] = Runtime() }
        soundingShapeIDs = []
        engine.stop()
        loadToken &+= 1              // invalidate any in-flight decodes
        bufferCache.removeAll()      // free all audio memory while paused
        crossfadeCache.removeAll()
        loadingFiles.removeAll()
        syncedStarted = false
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

        for shape in shapes {
            var rt = runtimes[shape.id] ?? Runtime()
            let isIn = nowInside.contains(shape.id)
            let rising = isIn && !rt.inside

            switch shape.mode {
            case .loop:
                if isIn {
                    let target = Float(shape.gain * loopLevel(shape, coord: coord))
                    if voices[shape.id] == nil { startLoop(shape, target: target) }
                    else { setLoopTarget(shape, target: target) }
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
                if let voice = voices[shape.id] {
                    let target = isIn ? Float(shape.gain * loopLevel(shape, coord: coord)) : 0
                    let dur: TimeInterval = rising ? max(0.02, shape.fadeIn)
                        : (rt.inside && !isIn ? max(0.02, shape.fadeOut) : 0.12)
                    ramp(voice, to: target, duration: dur)
                }
            }
            rt.inside = isIn
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
            attach(voice, format: buf.format)
            voice.player.scheduleBuffer(buf, at: nil, options: [.loops], completionHandler: nil)
            voice.player.volume = 0                    // silent but running until the listener enters
            voices[shape.id] = voice
            voice.player.play(at: start)
        }
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
        ramp(voice, to: 0, duration: max(0.02, shape.fadeOut)) { [weak self] in
            self?.detach(voice)
        }
    }

    private func playOnce(_ shape: SoundShape) {
        guard let file = shape.audioFile, let buf = bufferCache[file] else { return }
        let voice = Voice(); voice.isLoop = false
        attach(voice, format: buf.format)
        voice.player.volume = Float(shape.gain)
        voice.target = Float(shape.gain)
        voice.player.scheduleBuffer(buf, at: nil, options: []) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.voices[shape.id] === voice {
                    self.voices.removeValue(forKey: shape.id)
                    self.detach(voice)
                    self.refreshSounding()
                }
            }
        }
        voice.player.play()
        voices[shape.id] = voice
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
        attach(voice, format: buf.format)
        voice.player.volume = Float(shape.gain)
        voice.target = Float(shape.gain)
        voice.player.scheduleBuffer(buf, at: nil, options: []) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.voices[shape.id] === voice {
                    self.voices.removeValue(forKey: shape.id)
                    self.detach(voice)
                    self.finishDialogue(shape.id)
                }
            }
        }
        voice.player.play()
        voices[shape.id] = voice
        refreshSounding()
    }

    private func finishDialogue(_ id: String) {
        if dialoguePlaying == id { dialoguePlaying = nil }
        setDialogueState(id, .finished)
        refreshSounding()
        advanceDialogue()
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
        attach(voice, format: buf.format)
        voice.player.volume = gain
        voice.player.scheduleBuffer(buf, at: nil, options: []) { DispatchQueue.main.async { onFinish() } }
        voice.player.play()
        return voice
    }

    /// Play the intro clip once, gated so it doesn't replay when resuming the same walk within an hour.
    private func maybePlayIntro() {
        guard let exp = experience, let file = exp.map.intro, !file.isEmpty else { return }
        let key = "songitude.intro." + exp.id
        let now = Date().timeIntervalSince1970
        if now - UserDefaults.standard.double(forKey: key) < Self.introGate { return }
        UserDefaults.standard.set(now, forKey: key)
        loadAndPlayClip(file, gain: Float(exp.map.introGain ?? 1.0),
                        assign: { [weak self] v in self?.introVoice = v },
                        onFinish: { [weak self] in
                            if let v = self?.introVoice { self?.detach(v) }
                            self?.introVoice = nil
                        })
    }

    private func armDoneTimer() {
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
            if let toggle = self.remoteToggle { toggle(false) } else { self.stop() }   // end the whole session
        }
    }

    private func fadeDialogueVoices(duration: TimeInterval) {
        for id in Array(voices.keys) where shapes.first(where: { $0.id == id })?.mode == .dialogue {
            if let voice = voices.removeValue(forKey: id) {
                ramp(voice, to: 0, duration: duration) { [weak self] in self?.detach(voice) }
            }
        }
        refreshSounding()
    }

    private func fadeAllVoices(duration: TimeInterval) {
        let entries = voices; voices.removeAll()
        for (_, voice) in entries {
            ramp(voice, to: 0, duration: duration) { [weak self] in self?.detach(voice) }
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

    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.remoteToggle?(true); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.remoteToggle?(false); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.remoteToggle?(!self.isRunning); return .success
        }
        // Not a seekable medium — disable scrubbing transport.
        c.changePlaybackPositionCommand.isEnabled = false
        c.nextTrackCommand.isEnabled = false
        c.previousTrackCommand.isEnabled = false
    }
}
