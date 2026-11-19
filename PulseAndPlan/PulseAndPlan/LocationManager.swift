@preconcurrency import CoreLocation
import Observation

/// Battery-safe location engine: ~100 m accuracy, 50 m distance filter, significant-change monitoring
/// and a CLBackgroundActivitySession so a When-In-Use session keeps updating in the background.
@Observable
@MainActor
final class LocationManager: NSObject, CLLocationManagerDelegate {
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var lastLocation: CLLocation?
    private(set) var placeName: String?
    private(set) var isUpdating = false
    @ObservationIgnored var onUpdate: ((CLLocation) -> Void)?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?
    @ObservationIgnored private var pendingStart = false
    @ObservationIgnored private var lastGeocoded: CLLocation?
    @ObservationIgnored private let geocoder = CLGeocoder()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        manager.activityType = .other
        authorization = manager.authorizationStatus
    }

    /// iOS throws (or silently stops) if background updates are enabled without the Info.plist mode.
    static var hasLocationBackgroundMode: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("location") == true
    }

    var canUpgradeToAlways: Bool { authorization == .authorizedWhenInUse }
    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    /// Call only from foreground UI (button tap / app becoming active): iOS ignores background starts.
    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            pendingStart = true
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdates()
        default:
            break
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        backgroundSession?.invalidate()
        backgroundSession = nil
        isUpdating = false
    }

    func requestAlways() { manager.requestAlwaysAuthorization() }

    private func beginUpdates() {
        if Self.hasLocationBackgroundMode {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        manager.startUpdatingLocation()
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
        if backgroundSession == nil { backgroundSession = CLBackgroundActivitySession() }
        isUpdating = true
    }

    private func handle(_ location: CLLocation) {
        lastLocation = location
        onUpdate?(location)
        // Geocoding is rate-limited by Apple; only refresh after moving ~1 km.
        if lastGeocoded.map({ $0.distance(from: location) > 1000 }) ?? true {
            lastGeocoded = location
            Task { await self.reverseGeocode(location) }
        }
    }

    private func reverseGeocode(_ location: CLLocation) async {
        guard let mark = try? await geocoder.reverseGeocodeLocation(location).first else { return }
        let parts = [mark.subLocality, mark.locality].compactMap { $0 }
        placeName = parts.isEmpty ? mark.name : parts.joined(separator: ", ")
        if let lastLocation { onUpdate?(lastLocation) } // republish with the new label
    }

    // MARK: CLLocationManagerDelegate (called on the main run loop; hop explicitly for the compiler)

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if self.pendingStart, status == .authorizedWhenInUse || status == .authorizedAlways {
                self.pendingStart = false
                self.beginUpdates()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in self.handle(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // kCLErrorLocationUnknown is transient; denial is surfaced through `authorization`.
    }
}
