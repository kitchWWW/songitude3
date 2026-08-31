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

    /// Walks baked into the app at build time. Normally empty — everything ships from the catalog
    /// now — but `Experiences/*.zip` still works for trying a bundle without publishing it.
    @Published var experiences: [Experience] = []
    @Published var current: Experience?                 // active walk (bundled or downloaded remote)
    @Published var offset: CoordinateOffset = .none
    @Published var hasOnboarded: Bool
    @Published var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: appearanceKey) }
    }
    @Published var showPermissionDeniedAlert = false
    @Published var showIntroCard = false
    /// Follows the intro card when the listener is nowhere near a geo-locked walk. Advisory only —
    /// they can dismiss it and look around regardless.
    @Published var showFarAwayCard = false
    /// How many times the card has been opened for the walk that's loaded. The recenter control
    /// only appears from the second viewing, so a first read is just the walk's own words.
    @Published private(set) var introShowings = 0
    /// Bumped every time a transportable walk is placed, so the map knows to redraw its overlays
    /// even though the walk's id hasn't changed.
    @Published private(set) var placementVersion = 0
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
    /// The walk the listener most recently asked for. A download that finishes after they have
    /// moved on must not steer the UI — its files just land in the cache for next time.
    private var activeWalkRequest: String?
    /// The walk exactly as authored, before any transposition — re-anchoring has to start from
    /// this, or each recenter would compound on the last one's transform.
    private var authoredCurrent: Experience?
    private var pendingRecenter = false
    /// A portable walk placed before the compass reported gets one free re-place when it does.
    private var pendingHeadingPlacement = false
    private var cancellables = Set<AnyCancellable>()
    private let onboardKey = "hasOnboarded.v1"
    private let appearanceKey = "appearance.v1"
    /// How long an intro card stays "already seen" for a walk. Deliberately loose: moving around
    /// the app shouldn't re-show it, but coming back later should.
    private let introWindow: TimeInterval = 600
    /// Far enough that none of a fixed walk can be reached on foot — 50 miles.
    private let farAwayDistance: CLLocationDistance = 80_467
    /// Set while a fix is outstanding purely to decide whether the far-away card is warranted.
    private var pendingFarAwayCheck = false

    // GPS slewing: feed the engine a virtual position that eases toward each new fix in small steps,
    // so a jumpy GPS reading can't teleport across (and skip) a zone.
    private var virtualCoord: CLLocationCoordinate2D?
    private var slewTimer: Timer?

    var selectedExperience: Experience? { current }
    /// True while a specific walk is already on its way in — a deep link waiting on the catalog, or
    /// one being opened right now. The map shouldn't pop the walks list over the top of it.
    var isOpeningWalk: Bool { pendingWalkId != nil || activeWalkRequest != nil }

    init() {
        hasOnboarded = UserDefaults.standard.bool(forKey: onboardKey)
        appearance = AppAppearance(rawValue: UserDefaults.standard.string(forKey: appearanceKey) ?? "")
            ?? .system
        experiences = ExperienceLibrary.loadAll()
        // No walk is chosen for the listener: the app opens on the walks selector instead of
        // dropping them into an arbitrary bundled demo.
        current = nil

        location.onLocation = { [weak self] coord in self?.ingestFix(coord) }
        // Always invoked on the main thread by the engine, and inside a background task assertion
        // when it came from the lock screen — so do the work here and now rather than hopping to a
        // later turn, where the app may already have been suspended part-way through the teardown.
        engine.remoteToggle = { [weak self] play in
            guard let self = self else { return }
            if play {
                self.location.start(); self.engine.start(); self.primeEngineWithCurrentLocation()
            } else {
                self.engine.stop(); self.location.stop(); self.stopSlew()
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
        location.$heading.compactMap { $0 }.receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self, self.pendingHeadingPlacement,
                      let authored = self.authoredCurrent, authored.map.startAnchor != nil,
                      self.location.lastKnownLocation != nil else { return }
                self.pendingHeadingPlacement = false
                self.applyPlacement(authored)
            }.store(in: &cancellables)
        // Keep the catalog sorted nearest-first as fixes arrive (fixes only flow while playing,
        // so the list is correctly ordered the next time the browser is opened).
        location.$location.compactMap { $0 }.receive(on: RunLoop.main)
            .sink { [weak self] coord in
                guard let self = self else { return }
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { self.catalog.resort(near: coord) }
                // A recenter asked for a fresh fix; this is it.
                if self.pendingRecenter, let authored = self.authoredCurrent,
                   authored.map.startAnchor != nil {
                    self.pendingRecenter = false
                    self.applyPlacement(authored)
                }
                // The far-away check was waiting on a position to compare against. It clears its
                // own flag once it can actually answer.
                if self.pendingFarAwayCheck { self.maybeShowFarAwayCard() }
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
        // A finished download re-enters this for a walk that is *already* on screen — the shell was
        // put up as soon as map.json landed. That is not the listener choosing a different walk, and
        // it must not retract a card they are in the middle of reading: clearing state here
        // unconditionally is what made the far-away warning flash up and vanish mid-load.
        let switchingWalk = current?.id != exp.id
        if switchingWalk {
            introShowings = 0        // a different walk starts its own count
            showFarAwayCard = false
        }
        current = anchoredIfPortable(exp)
        offset = .none
        engine.load(exp)            // stops current playback
        engine.setOffset(.none)
        location.stop(); stopSlew() // switching pauses playback → release GPS + reset slewing
        maybeShowIntroCard()
        // Decide the far-away card only when nothing is already up. If the shell already showed it,
        // it stays; if it was dismissed, its own gate keeps it down; if the check was skipped
        // earlier for want of a fix, this is a fresh chance to make the call.
        if !showIntroCard && !showFarAwayCard { maybeShowFarAwayCard() }
    }

    /// A transportable walk (one that carries a `startAnchor`) is moved and turned onto the
    /// listener the moment it opens, so the whole composition plays out from wherever they stand,
    /// facing wherever they face. A walk with no anchor is returned untouched and stays fixed in
    /// space. With no fix yet we leave it as authored rather than guess a position.
    private func anchoredIfPortable(_ exp: Experience) -> Experience {
        authoredCurrent = exp
        guard let anchor = exp.map.startAnchor else { return exp }

        // Always chase a fresh fix and heading for a portable walk: the cached one can be stale (or
        // absent entirely on a cold launch), and placing the walk in the wrong city means nothing is
        // ever in range and the walk plays silently. `pending…` re-places the moment they arrive.
        pendingRecenter = true
        if location.heading == nil { pendingHeadingPlacement = true }
        location.requestOneShotFix()

        guard let here = location.lastKnownLocation else { return exp }
        let t = WalkTransposition(anchor: anchor, listener: here, heading: location.heading ?? anchor.heading)
        return Experience(id: exp.id, directory: exp.directory, map: exp.map.transposed(t))
    }

    /// Whether the loaded walk ships an exit clip. Without one there is no outro to offer.
    var currentHasOutro: Bool {
        guard let exit = current?.map.exit else { return false }
        return !exit.isEmpty
    }

    /// True when the loaded walk travels with the listener, so the UI can offer to re-place it.
    var currentIsPortable: Bool { authoredCurrent?.map.startAnchor != nil }

    /// Drop the walk around wherever the listener is standing now. Re-transposes from the authored
    /// original and asks for a fresh fix; when that arrives it settles onto the better position.
    func recenterPortableWalk() {
        guard let authored = authoredCurrent, authored.map.startAnchor != nil else { return }
        pendingRecenter = true
        location.requestOneShotFix()
        applyPlacement(authored)      // immediate, from the best position we already have
    }

    /// Re-place the walk around the listener. Deliberately not `setCurrent`: that reloads the
    /// engine, which stops playback and resets dialogue history. Here only the coordinates change,
    /// so the audio keeps running and simply re-evaluates against the new positions.
    private func applyPlacement(_ authored: Experience) {
        let placed = anchoredIfPortable(authored)
        pendingRecenter = false
        current = placed
        placementVersion &+= 1
        engine.updateGeometry(placed)
        primeEngineWithCurrentLocation()   // re-trigger against the new geometry immediately
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
        if !showIntroCard { introShowings += 1 }
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
        maybeShowFarAwayCard()
    }

    // MARK: - "You look pretty far away" card

    private func farAwayKey(_ id: String) -> String { "farAwayCard.seen.\(id)" }

    /// How far the listener is from the loaded walk, in miles — nil without a walk or a fix.
    var currentWalkDistanceMiles: Double? {
        guard let exp = current, let here = location.location ?? location.lastKnownLocation else { return nil }
        return GeoUtils.distance(here, exp.map.centerCoord) / 1609.344
    }

    /// Once the walk's own card is out of the way, tell a listener who is nowhere near it that they
    /// won't hear anything from here. Deliberately advisory: it never blocks opening the walk.
    ///
    /// A transportable walk is exempt — it re-anchors onto wherever the listener is standing, so its
    /// distance from where it was authored says nothing about whether they can hear it.
    ///
    /// `pendingFarAwayCheck` is cleared exactly when a decision is reached, so an answer can't be
    /// lost to whatever else is in flight — a fix arriving while the walk's own card is still up
    /// holds the question rather than consuming it.
    func maybeShowFarAwayCard() {
        guard let exp = current, !currentIsPortable else { pendingFarAwayCheck = false; return }
        guard !showIntroCard else { return }        // hold; dismissing that card asks again
        let last = UserDefaults.standard.double(forKey: farAwayKey(exp.id))
        if last > 0, Date().timeIntervalSince1970 - last < introWindow {
            pendingFarAwayCheck = false
            return
        }
        guard let here = location.location ?? location.lastKnownLocation else {
            // No position yet: ask for one and decide when it lands, rather than warning on a guess.
            pendingFarAwayCheck = true
            location.requestOneShotFix()
            return
        }
        pendingFarAwayCheck = false
        guard GeoUtils.distance(here, exp.map.centerCoord) > farAwayDistance else { return }
        showFarAwayCard = true
        engine.cancelDoneTimer()      // the "All done?" delay shouldn't run behind the card
    }

    func dismissFarAwayCard() {
        pendingFarAwayCheck = false
        if let id = current?.id {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: farAwayKey(id))
        }
        showFarAwayCard = false
        if engine.isRunning { engine.armDoneTimer() }
    }

    /// The catalog entry for the active walk, when it came from the server — carries the artistId
    /// that a bundle's map.json doesn't have.
    var currentRemoteWalk: RemoteWalk? {
        guard let id = current?.id else { return nil }
        return catalog.walks.first { $0.id == id }
    }

    // MARK: - Remote walks

    func openRemote(_ walk: RemoteWalk) {
        activeWalkRequest = walk.id
        // Silence the walk they're leaving straight away. Without this the previous walk kept
        // playing through the download of the new one, since nothing stops the engine until the
        // new bundle finishes and setCurrent reloads it.
        if current?.id != walk.id { engine.stop(); location.stop(); stopSlew() }

        // Only reuse the cache when it matches the published revision; otherwise fall through to
        // the downloader, which rewrites map.json and fetches anything missing.
        if WalkDownloader.isUpToDate(walk), let exp = WalkDownloader.cachedExperience(walk.id) {
            downloadingWalkId = nil       // an earlier download keeps running, quietly, in the background
            setCurrent(exp)
            presentIntroCard()
            return
        }
        let previous = current
        downloadingWalkId = walk.id; downloadProgress = 0; catalogError = nil
        WalkDownloader.download(
            walk,
            mapReady: { [weak self] map in
                guard let self, self.activeWalkRequest == walk.id else { return }
                // map.json is a few KB: recenter and retitle now rather than after the audio.
                self.showWalkShell(Experience(id: walk.id,
                                              directory: WalkDownloader.cacheDir(for: walk.id),
                                              map: map))
            },
            progress: { [weak self] p in
                guard let self, self.activeWalkRequest == walk.id else { return }
                self.downloadProgress = p
            }
        ) { [weak self] result in
            guard let self = self else { return }
            self.refreshDownloadedIds()          // the files landed either way
            // Superseded: the listener has opened something else since. Leave their view alone.
            guard self.activeWalkRequest == walk.id else { return }
            self.downloadingWalkId = nil
            switch result {
            case .success(let exp):
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
        if current?.id != exp.id { introShowings = 0; showFarAwayCard = false }
        current = anchoredIfPortable(exp)
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
        if activeWalkRequest == id { activeWalkRequest = nil }

        // Only the list-facing state changes here, with animations off.
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            if wasCurrent { current = nil; showIntroCard = false; showFarAwayCard = false }
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
        showIntroCard = false
        showFarAwayCard = false
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
