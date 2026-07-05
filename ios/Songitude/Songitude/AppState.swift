import Foundation
import CoreLocation
import Combine

/// App-wide coordinator: owns the bundled library, the remote catalog, the location manager and
/// the render engine, and wires location fixes into playback.
final class AppState: ObservableObject {

    @Published var experiences: [Experience] = []       // bundled demos (offline fallback)
    @Published var current: Experience?                 // active walk (bundled or downloaded remote)
    @Published var offset: CoordinateOffset = .none
    @Published var hasOnboarded: Bool
    @Published var showPermissionDeniedAlert = false

    // Remote-walk download state (for the browser UI).
    @Published var downloadingWalkId: String?
    @Published var downloadProgress: Double = 0
    @Published var catalogError: String?

    let location = LocationManager()
    let engine = RenderEngine()
    let catalog = RemoteCatalog()

    private var pendingWalkId: String?                  // deep link to open after onboarding/catalog load
    private var cancellables = Set<AnyCancellable>()
    private let onboardKey = "hasOnboarded.v1"

    // GPS slewing: feed the engine a virtual position that eases toward each new fix in small steps,
    // so a jumpy GPS reading can't teleport across (and skip) a zone.
    private var virtualCoord: CLLocationCoordinate2D?
    private var slewTimer: Timer?

    var selectedExperience: Experience? { current }
    var currentIsBundled: Bool { current.map { c in experiences.contains { $0.id == c.id } } ?? false }

    init() {
        hasOnboarded = UserDefaults.standard.bool(forKey: onboardKey)
        experiences = ExperienceLibrary.loadAll()
        // Default to the bundled "magic_square" when present (else the first bundled one).
        current = experiences.first(where: { $0.id == "magic_square" }) ?? experiences.first

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
        // When the catalog arrives, honor any pending deep link.
        catalog.$walks.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.processPendingWalk() }.store(in: &cancellables)
        // Keep the catalog sorted nearest-first as fixes arrive (fixes only flow while playing,
        // so the list is correctly ordered the next time the browser is opened).
        location.$location.compactMap { $0 }.receive(on: RunLoop.main)
            .sink { [weak self] coord in self?.catalog.resort(near: coord) }.store(in: &cancellables)

        if let c = current { engine.load(c) }
        refreshCatalog()
    }

    func refreshCatalog() { catalog.refresh(near: location.lastKnownLocation) }

    // MARK: - Active experience

    func setCurrent(_ exp: Experience) {
        current = exp
        offset = .none
        engine.load(exp)            // stops current playback
        engine.setOffset(.none)
        location.stop(); stopSlew() // switching pauses playback → release GPS + reset slewing
    }

    func selectBundled(_ index: Int) {
        guard experiences.indices.contains(index) else { return }
        setCurrent(experiences[index])
    }

    // MARK: - Remote walks

    func openRemote(_ walk: RemoteWalk) {
        if let exp = WalkDownloader.cachedExperience(walk.id) { setCurrent(exp); return }
        downloadingWalkId = walk.id; downloadProgress = 0; catalogError = nil
        WalkDownloader.download(walk, progress: { [weak self] p in self?.downloadProgress = p }) { [weak self] result in
            guard let self = self else { return }
            self.downloadingWalkId = nil
            switch result {
            case .success(let exp): self.setCurrent(exp)
            case .failure(let e): self.catalogError = "Download failed: \(e.localizedDescription)"
            }
        }
    }

    /// Delete a downloaded walk's local files (server copy untouched; re-download to listen again).
    func deleteDownloaded(_ id: String) {
        WalkDownloader.deleteCache(id)
        objectWillChange.send()
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
