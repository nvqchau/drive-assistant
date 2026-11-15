import CoreLocation
import Foundation

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var speedKMPH: Double = 0
    @Published private(set) var horizontalAccuracy: CLLocationAccuracy = .infinity
    @Published private(set) var weatherRoadCondition: RoadCondition = .dry
    private let manager = CLLocationManager()
    private let weatherService = WeatherService()
    private var stallTimer: Timer?
    private let stallThreshold: TimeInterval = 5.0

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
        startStallTimer()
    }

    func stop() {
        manager.stopUpdatingLocation()
        stallTimer?.invalidate()
        stallTimer = nil
    }

    private func startStallTimer() {
        stallTimer?.invalidate()
        stallTimer = Timer.scheduledTimer(withTimeInterval: stallThreshold, repeats: true) { [weak self] _ in
            self?.handleStall()
        }
    }

    private func handleStall() {
        DispatchQueue.main.async { [weak self] in
            self?.speedKMPH = 0
            self?.horizontalAccuracy = .infinity
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        horizontalAccuracy = location.horizontalAccuracy
        guard location.speed >= 0,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 50 else {
            return
        }
        speedKMPH = location.speed * 3.6
        startStallTimer()
        weatherService.update(for: location) { [weak self] condition in
            self?.weatherRoadCondition = condition
        }
    }
}
