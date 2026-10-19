import CoreLocation
import Combine
import DashCamCore

final class SpeedTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var currentSpeed: Double = 0 // km/h
    /// True when the user has refused (or the system restricts) location access.
    @Published private(set) var isLocationDenied = false

    /// Most recent fix; attached to clips saved to Photos. Main thread only.
    private(set) var lastLocation: CLLocation?

    private let locationManager = CLLocationManager()
    private var wantsTracking = false

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.activityType = .automotiveNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        updateAuthorizationState(locationManager.authorizationStatus)
    }

    func startTracking() {
        wantsTracking = true

        let status = locationManager.authorizationStatus
        updateAuthorizationState(status)
        switch status {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.startUpdatingLocation()
        default:
            break // denied or restricted: recording works, the speed readout is just unavailable
        }
    }

    func stopTracking() {
        wantsTracking = false
        locationManager.stopUpdatingLocation()
        DispatchQueue.main.async {
            self.currentSpeed = 0
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        updateAuthorizationState(status)
        if wantsTracking && (status == .authorizedWhenInUse || status == .authorizedAlways) {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let speed = SpeedConversion.kilometersPerHour(metersPerSecond: location.speed)
        DispatchQueue.main.async {
            self.lastLocation = location
            self.currentSpeed = speed
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // GPS temporarily unavailable: keep the last known speed
        Log.location.error("location error: \(error.localizedDescription)")
    }

    // MARK: - Private

    private func updateAuthorizationState(_ status: CLAuthorizationStatus) {
        let denied = status == .denied || status == .restricted
        DispatchQueue.main.async {
            self.isLocationDenied = denied
        }
    }
}
