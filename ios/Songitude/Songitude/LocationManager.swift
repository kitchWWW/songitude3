import Foundation
import CoreLocation

/// Wraps CoreLocation. Publishes authorization state and the latest fix, and keeps updates
/// flowing while backgrounded so the audio engine can react in the user's pocket.
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published var authorization: CLAuthorizationStatus
    @Published var location: CLLocationCoordinate2D?
    @Published var heading: CLLocationDirection?

    private let manager = CLLocationManager()

    /// True while playback wants live fixes. We only run the (energy-intensive) high-accuracy
    /// updates when this is set — i.e. while an experience is playing — and pause them otherwise.
    private var wantsUpdates = false

    /// Set while a one-shot fix is outstanding. That fix updates `location` (so the walks list can
    /// sort nearest-first) but is deliberately NOT forwarded to `onLocation` — opening a list must
    /// not drive the audio engine.
    private var oneShotOnly = false
    /// Set while we want a single compass reading (to orient a transportable walk) without
    /// leaving the magnetometer running.
    private var oneShotHeading = false

    /// Called on every new fix so the owner can drive the audio engine.
    var onLocation: ((CLLocationCoordinate2D) -> Void)?

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 3            // meters
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
    }

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    /// Best guess at where we are WITHOUT starting updates — the system's most recent cached fix.
    /// Used to sort the walk catalog nearest-first; never triggers a new location request.
    var lastKnownLocation: CLLocationCoordinate2D? {
        location ?? (isAuthorized ? manager.location?.coordinate : nil)
    }

    /// One fix, then nothing — no continuous updates, no background mode. Used when the walks
    /// list opens so it can be ordered by distance even though playback isn't running.
    func requestOneShotFix() {
        guard isAuthorized, !wantsUpdates else { return }
        oneShotOnly = true
        manager.requestLocation()
        if CLLocationManager.headingAvailable() {
            oneShotHeading = true
            manager.startUpdatingHeading()
        }
    }

    /// The big onboarding button calls this.
    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// Offered in Settings — nudges toward Always for the best in-pocket behavior.
    func requestAlways() {
        manager.requestAlwaysAuthorization()
    }

    /// Begin high-accuracy updates. Call when playback starts. Keeps running in the background
    /// (locked / in-pocket) via the "location" background mode while the experience plays.
    func start() {
        wantsUpdates = true
        guard isAuthorized else { return }
        manager.allowsBackgroundLocationUpdates = true
        if #available(iOS 11.0, *) { manager.showsBackgroundLocationIndicator = true }
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    /// Stop all updates. Call when playback pauses — releases the intensive GPS so a paused
    /// experience uses no location, foreground or background.
    func stop() {
        wantsUpdates = false
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        manager.allowsBackgroundLocationUpdates = false
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.authorization = manager.authorizationStatus
            // Only (re)start if playback still wants updates — e.g. permission was granted right
            // after hitting play. Granting while paused must NOT begin obsessive updates.
            if self.isAuthorized && self.wantsUpdates { self.start() }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let coord = loc.coordinate
        DispatchQueue.main.async {
            self.location = coord
            if self.oneShotOnly && !self.wantsUpdates { self.oneShotOnly = false; return }
            self.onLocation?(coord)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // trueHeading is -1 until the compass has calibrated; magneticHeading is the usable fallback.
        let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        guard h >= 0 else { return }
        DispatchQueue.main.async { self.heading = h }
        if oneShotHeading && !wantsUpdates {
            oneShotHeading = false
            manager.stopUpdatingHeading()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[LocationManager] error: \(error.localizedDescription)")
    }
}
