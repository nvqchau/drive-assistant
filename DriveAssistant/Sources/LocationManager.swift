import CoreLocation
import Foundation

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var speedKMPH: Double = 0
    @Published private(set) var weatherRoadCondition: RoadCondition = .dry
    private let manager = CLLocationManager()
    private let weatherService = WeatherService()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func stop() { manager.stopUpdatingLocation() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.speed >= 0 else { return }
        speedKMPH = location.speed * 3.6
        weatherService.update(for: location) { [weak self] condition in
            self?.weatherRoadCondition = condition
        }
    }
}
