import CoreLocation
import Combine

final class SpeedTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var currentSpeed: Double = 0 // km/h

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
    }

    func startTracking() {
        wantsTracking = true

        let status = locationManager.authorizationStatus
        switch status {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.startUpdatingLocation()
        default:
            break // denied or restricted — nothing we can do
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
        if wantsTracking && (status == .authorizedWhenInUse || status == .authorizedAlways) {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let speed = max(0, location.speed) * 3.6 // m/s -> km/h, clamp negatives to 0
        DispatchQueue.main.async {
            self.currentSpeed = speed
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // GPS temporarily unavailable — keep last known speed
        print("SpeedTracker location error: \(error.localizedDescription)")
    }
}
