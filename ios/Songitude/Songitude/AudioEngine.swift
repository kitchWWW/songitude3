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

    /// Called by the lock-screen / control-center transport. `true` = play, `false` = pause.
    var remoteToggle: ((Bool) -> Void)?

    private let engine = AVAudioEngine()
    private var bufferCache: [String: AVAudioPCMBuffer] = [:]

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

    // MARK: - Session

    init() { configureRemoteCommands() }

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
        loadingFiles.removeAll()
        runtimes = Dictionary(uniqueKeysWithValues: shapes.map { ($0.id, Runtime()) })
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

    // MARK: - Transport (the big play/pause button)

    func start() {
        guard !isRunning else { return }
        configureSession()
        // Realize the main mixer -> output connection while the engine is stopped, so the first
        // voice that attaches later doesn't mutate the graph mid-render.
        engine.mainMixerNode.outputVolume = 1.0
        engine.prepare()
        do { try engine.start() } catch { print("[RenderEngine] start error: \(error)"); return }
        isRunning = true
        ensureSyncedLoops()          // begin loading + (once ready) launch synced loops in lock-step
        updateNowPlayingPlayback(rate: 1)
    }

    func stop() {
        guard isRunning || !voices.isEmpty else { return }
        for (id, _) in voices { hardStopVoice(id) }
        voices.removeAll()
        for id in runtimes.keys { runtimes[id] = Runtime() }
        soundingShapeIDs = []
        engine.stop()
        isRunning = false
        loadToken &+= 1              // invalidate any in-flight decodes
        bufferCache.removeAll()      // free all audio memory while paused
        loadingFiles.removeAll()
        syncedStarted = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        updateNowPlayingPlayback(rate: 0)
    }

    func toggle() { isRunning ? stop() : start() }

    // MARK: - Location driven state machine

    func updateLocation(_ coord: CLLocationCoordinate2D) {
        lastCoord = coord
        guard isRunning else { return }
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
            case .oneshot, .dialogue:
                if rising && rt.armed {
                    if shape.mode == .dialogue { duckOtherDialogues(except: shape.id) }
                    playOnce(shape)
                    rt.armed = false
                }
                if !isIn { rt.armed = true }
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
        guard let file = shape.audioFile, let buf = bufferCache[file] else { return }
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

    private func duckOtherDialogues(except keepID: String) {
        for shape in shapes where shape.mode == .dialogue && shape.id != keepID {
            guard let voice = voices[shape.id] else { continue }
            voices.removeValue(forKey: shape.id)
            ramp(voice, to: 0, duration: 0.6) { [weak self] in self?.detach(voice) }
        }
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
