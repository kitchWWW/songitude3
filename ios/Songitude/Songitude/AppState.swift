import Foundation
import CoreLocation
import Combine
import SwiftUI   // Transaction, for re-sorting the catalog without animating rows

/// How the app renders light/dark. Defaults to following the phone.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
    /// nil = inherit the device setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// App-wide coordinator: owns the bundled library, the remote catalog, the location manager and
/// the render engine, and wires location fixes into playback.
final class AppState: ObservableObject {

    @Published var experiences: [Experience] = []       // bundled demos (offline fallback)
    @Published var current: Experience?                 // active walk (bundled or downloaded remote)
    @Published var offset: CoordinateOffset = .none
    @Published var hasOnboarded: Bool
    @Published var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: appearanceKey) }
    }
    @Published var showPermissionDeniedAlert = false
    @Published var showIntroCard = false
    /// Which walks are on disk. Observable state rather than a filesystem probe inside `body`, so
    /// SwiftUI actually re-renders the row whose download just appeared or was removed.
    @Published private(set) var downloadedIds: Set<String> = []
    /// Bumped by `resetEverything` so the root view can replay the launch sequence. The splash's
    /// own "already seen" flag is read once at view-init, so clearing it isn't enough on its own.
    @Published private(set) var resetToken = 0

    // Remote-walk download state (for the browser UI).
    @Published var downloadingWalkId: String?
    @Published var downloadProgress: Double = 0
    @Published var catalogError: String?

    let location = LocationManager()
    let engine = RenderEngine()
    let catalog = RemoteCatalog()
    let artists = ArtistStore()

    private var pendingWalkId: String?                  // deep link to open after onboarding/catalog load
    private var cancellables = Set<AnyCancellable>()
    private let onboardKey = "hasOnboarded.v1"
    private let appearanceKey = "appearance.v1"
    /// How long an intro card stays "already seen" for a walk. Deliberately loose: moving around
    /// the app shouldn't re-show it, but coming back later should.
    private let introWindow: TimeInterval = 600

    // GPS slewing: feed the engine a virtual position that eases toward each new fix in small steps,
    // so a jumpy GPS reading can't teleport across (and skip) a zone.
    private var virtualCoord: CLLocationCoordinate2D?
    private var slewTimer: Timer?

    var selectedExperience: Experience? { current }
    var currentIsBundled: Bool { current.map { c in experiences.contains { $0.id == c.id } } ?? false }

    init() {
        hasOnboarded = UserDefaults.standard.bool(forKey: onboardKey)
        appearance = AppAppearance(rawValue: UserDefaults.standard.string(forKey: appearanceKey) ?? "")
            ?? .system
        experiences = ExperienceLibrary.loadAll()
        // No walk is chosen for the listener: the app opens on the walks selector instead of
        // dropping them into an arbitrary bundled demo.
        current = nil

        location.onLocation = { [weak self] coord in self?.ingestFix(coord) }
        engine.remoteToggle = { [weak self] play in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if play {
                    self.location.start(); self.engine.start(); self.primeEngineWithCurrentLocation()
                } else {
                    self.engine.stop(); self.location.stop(); self.stopSlew()
                }
            }
        }
        engine.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        location.$authorization.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        // Views read app.catalog.* through this object, so its changes have to be forwarded like
        // every other child's — without this the walks list never redraws when the manifest lands.
        catalog.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        // When the catalog arrives, honor any pending deep link.
        catalog.$walks.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.processPendingWalk() }.store(in: &cancellables)
        artists.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        // Keep the catalog sorted nearest-first as fixes arrive (fixes only flow while playing,
        // so the list is correctly ordered the next time the browser is opened).
        location.$location.compactMap { $0 }.receive(on: RunLoop.main)
            .sink { [weak self] coord in
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { self?.catalog.resort(near: coord) }
            }.store(in: &cancellables)

        if let c = current { engine.load(c) }
        refreshDownloadedIds()
        refreshCatalog()
    }

    func isDownloaded(_ id: String) -> Bool { downloadedIds.contains(id) }

    /// Re-read which walks are cached. Cheap (one directory listing) and only called at launch,
    /// after a download, and after a delete.
    func refreshDownloadedIds() {
        downloadedIds = WalkDownloader.downloadedIds()
    }

    func refreshCatalog() { catalog.refresh(near: location.lastKnownLocation) }

    /// Pull-to-refresh in the walks list: returns only once the fetch has finished.
    @MainActor func refreshCatalogAsync() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            catalog.refresh(near: location.lastKnownLocation) { cont.resume() }
        }
    }

    // MARK: - Active experience

    func setCurrent(_ exp: Experience) {
        current = exp
        offset = .none
        engine.load(exp)            // stops current playback
        engine.setOffset(.none)
        location.stop(); stopSlew() // switching pauses playback → release GPS + reset slewing
        maybeShowIntroCard()
    }

    // MARK: - Intro card

    private func introKey(_ id: String) -> String { "introCard.seen.\(id)" }

    /// Show the card unless this walk's card was already shown inside the window.
    func maybeShowIntroCard() {
        guard let id = current?.id else { return }
        let last = UserDefaults.standard.double(forKey: introKey(id))
        if last > 0, Date().timeIntervalSince1970 - last < introWindow { return }
        showIntroCard = true
        engine.cancelDoneTimer()
    }

    /// Tapping the walk's name in the top bar always brings the card back.
    func presentIntroCard() {
        guard current != nil else { return }
        showIntroCard = true
        engine.cancelDoneTimer()      // the "All done?" delay shouldn't run behind the card
    }

    func dismissIntroCard() {
        if let id = current?.id {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: introKey(id))
        }
        showIntroCard = false
        // Start (or restart) the countdown now that the map is visible.
        if engine.isRunning { engine.armDoneTimer() }
    }

    /// The catalog entry for the active walk, when it came from the server — carries the artistId
    /// that a bundle's map.json doesn't have.
    var currentRemoteWalk: RemoteWalk? {
        guard let id = current?.id else { return nil }
        return catalog.walks.first { $0.id == id }
    }

    func selectBundled(_ index: Int) {
        guard experiences.indices.contains(index) else { return }
        setCurrent(experiences[index])
    }

    // MARK: - Remote walks

    func openRemote(_ walk: RemoteWalk) {
        // Only reuse the cache when it matches the published revision; otherwise fall through to
        // the downloader, which rewrites map.json and fetches anything missing.
        if WalkDownloader.isUpToDate(walk), let exp = WalkDownloader.cachedExperience(walk.id) {
            setCurrent(exp)
            presentIntroCard()
            return
        }
        let previous = current
        downloadingWalkId = walk.id; downloadProgress = 0; catalogError = nil
        WalkDownloader.download(
            walk,
            mapReady: { [weak self] map in
                // map.json is a few KB: recenter and retitle now rather than after the audio.
                self?.showWalkShell(Experience(id: walk.id,
                                               directory: WalkDownloader.cacheDir(for: walk.id),
                                               map: map))
            },
            progress: { [weak self] p in self?.downloadProgress = p }
        ) { [weak self] result in
            guard let self = self else { return }
            self.downloadingWalkId = nil
            switch result {
            case .success(let exp):
                self.refreshDownloadedIds()
                self.setCurrent(exp)                    // now the audio exists → load the engine
            case .failure(let e):
                self.catalogError = "Download failed: \(e.localizedDescription)"
                if let previous = previous { self.setCurrent(previous) }  // undo the preview
                else { self.current = nil }
            }
        }
    }

    /// Put a walk on screen before its audio exists: map, title and re-centering only. The engine
    /// is deliberately not loaded — there is nothing yet for it to play.
    private func showWalkShell(_ exp: Experience) {
        current = exp
        offset = .none
        engine.setOffset(.none)
        location.stop(); stopSlew()
        // Title, artist and About all come from map.json / the catalog, so the card can be read
        // while the audio is still arriving.
        presentIntroCard()
    }

    /// Delete a downloaded walk's local files (server copy untouched; re-download to listen again).
    /// Uninstalling the walk that is currently loaded also unloads it — otherwise the engine would
    /// keep pointing at deleted audio and the row would still read as the active walk.
    func deleteDownloaded(_ id: String) {
        WalkDownloader.deleteCache(id)
        let wasCurrent = current?.id == id

        // Only the list-facing state changes here, with animations off.
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            if wasCurrent { current = nil; showIntroCard = false }
            refreshDownloadedIds()
        }

        // The engine's teardown republishes through its own objectWillChange, which AppState
        // forwards on the next run-loop turn — i.e. outside the transaction above, where it would
        // animate the row mid-swipe. Defer it so the list has already settled.
        if wasCurrent {
            DispatchQueue.main.async { [self] in
                engine.stop(); location.stop(); stopSlew()   // releases the players holding that audio
            }
        }
    }

    // MARK: - Deep link (open a specific walk as the default)

    func handleDeepLink(_ url: URL) {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = comps.queryItems?.first(where: { $0.name == "walk" })?.value, !id.isEmpty else { return }
        if !hasOnboarded { pendingWalkId = id; return }   // process once onboarding completes
        openWalk(id: id)
    }

    func openWalk(id: String) {
        if let exp = WalkDownloader.cachedExperience(id) { pendingWalkId = nil; setCurrent(exp); return }
        if let w = catalog.walks.first(where: { $0.id == id }) { pendingWalkId = nil; openRemote(w) }
        else { pendingWalkId = id; refreshCatalog() }     // honored when the catalog loads
    }

    private func processPendingWalk() {
        guard hasOnboarded, let id = pendingWalkId else { return }
        if let w = catalog.walks.first(where: { $0.id == id }) { pendingWalkId = nil; openRemote(w) }
    }

    // MARK: - Onboarding & permissions

    /// Wipe every trace of local state — preferences, onboarding, downloaded walks — and land back
    /// on the first-run screen, so a test run starts from zero.
    ///
    /// iOS does not let an app revoke its own location grant: that lives in the Settings app. After
    /// a reset the onboarding screen reappears, but if you previously allowed location the system
    /// prompt won't show again and the button falls straight through to "authorized".
    func resetEverything() {
        engine.stop(); location.stop(); stopSlew()
        WalkDownloader.deleteAllCaches()
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        offset = .none
        engine.setOffset(.none)
        experiences = ExperienceLibrary.loadAll()
        current = nil
        showPermissionDeniedAlert = false
        appearance = .system
        hasOnboarded = false            // drops the UI back to OnboardingView
        resetToken += 1                 // …and replays the splash on top of it
        refreshCatalog()
    }

    func completeOnboarding() {
        hasOnboarded = true
        UserDefaults.standard.set(true, forKey: onboardKey)
        processPendingWalk()
    }

    func enableLocation() { location.requestPermission() }

    func checkPermissionOutcome() {
        if location.authorization == .denied || location.authorization == .restricted {
            showPermissionDeniedAlert = true
        }
    }

    // MARK: - Playback

    func togglePlayback() {
        if !location.isAuthorized { showPermissionDeniedAlert = true; return }
        if engine.isRunning {
            engine.stop(); location.stop(); stopSlew()
        } else {
            location.start(); engine.start(); primeEngineWithCurrentLocation()
        }
    }

    private func primeEngineWithCurrentLocation() {
        if let here = location.location ?? location.lastKnownLocation {
            virtualCoord = here      // slew starts from here on the next fix
            engine.updateLocation(here)
        }
    }

    // MARK: - GPS slewing

    /// Ease the virtual position toward each new fix in ~0.2 s steps of ≤5 m, so a GPS jump can't
    /// skip over a zone. Steps are capped so a genuine fast move still catches up within a few seconds.
    private func ingestFix(_ coord: CLLocationCoordinate2D) {
        guard let from = virtualCoord else {           // first fix — adopt it directly
            virtualCoord = coord
            engine.updateLocation(coord)
            return
        }
        slewTimer?.invalidate()
        let steps = max(1, min(25, Int(ceil(GeoUtils.distance(from, coord) / 5.0))))
        var step = 0
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            step += 1
            let f = Double(step) / Double(steps)
            let c = CLLocationCoordinate2D(latitude: from.latitude + (coord.latitude - from.latitude) * f,
                                           longitude: from.longitude + (coord.longitude - from.longitude) * f)
            self.virtualCoord = c
            self.engine.updateLocation(c)
            if step >= steps { t.invalidate(); self.slewTimer = nil }
        }
        slewTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopSlew() { slewTimer?.invalidate(); slewTimer = nil; virtualCoord = nil }

    // MARK: - Debug: re-center map over me

    func recenterOnMe() {
        guard let exp = current, let here = location.location ?? location.lastKnownLocation else { return }
        let newOffset = CoordinateOffset.recentering(mapCenter: exp.map.centerCoord, onto: here)
        offset = newOffset
        engine.setOffset(newOffset)
        primeEngineWithCurrentLocation()
    }

    func clearRecenter() {
        offset = .none
        engine.setOffset(.none)
        primeEngineWithCurrentLocation()
    }
}
