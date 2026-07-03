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
            self.onLocation?(coord)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        DispatchQueue.main.async { self.heading = newHeading.trueHeading }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[LocationManager] error: \(error.localizedDescription)")
    }
}
