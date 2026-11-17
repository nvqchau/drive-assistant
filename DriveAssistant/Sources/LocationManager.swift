import CoreLocation
import Foundation

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var speedKMPH: Double = 0
    @Published private(set) var horizontalAccuracy: CLLocationAccuracy = .infinity
    @Published private(set) var weatherRoadCondition: RoadCondition = .dry
    @Published private(set) var isAstronomicalNight: Bool? = nil
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
        computeIsAstronomicalNight(for: location)
        weatherService.update(for: location) { [weak self] condition in
            self?.weatherRoadCondition = condition
        }
    }

    /// Compute whether sun is below horizon using NOAA solar elevation formula
    private func computeIsAstronomicalNight(for location: CLLocation) {
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date()
        let year = utcCal.component(.year, from: date)
        let month = utcCal.component(.month, from: date)
        let day = utcCal.component(.day, from: date)
        let hour = utcCal.component(.hour, from: date)
        let minute = utcCal.component(.minute, from: date)
        let second = utcCal.component(.second, from: date)
        
        // Fractional day of year (1-365/366)
        var dayOfYear = 0
        for m in 1..<month {
            dayOfYear += daysInMonth(month: m, year: year)
        }
        dayOfYear += day
        let dayFraction = Double(hour) / 24.0 + Double(minute) / 1440.0 + Double(second) / 86400.0
        
        // Julian day number
        let jd = Double(dayOfYear) + dayFraction + 2451545.0 - 0.5 + Double(year - 2000) * 365.25
        
        // Julian centuries since J2000
        let n = jd - 2451545.0
        let L = (280.460 + 0.9856474 * n).truncatingRemainder(dividingBy: 360.0)
        let g = (357.528 + 0.9856003 * n).truncatingRemainder(dividingBy: 360.0) * .pi / 180.0
        let lambda = (L + 1.915 * sin(g) + 0.020 * sin(2 * g)) * .pi / 180.0
        let epsilon = (23.439 - 0.0000004 * n) * .pi / 180.0
        
        // Right ascension and declination
        let sinDelta = sin(epsilon) * sin(lambda)
        let delta = asin(sinDelta)  // Solar declination
        
        // Hour angle
        let lat = location.coordinate.latitude * .pi / 180.0
        let lon = location.coordinate.longitude * .pi / 180.0
        let gmst = (280.46061837 + 360.98564736629 * n) * .pi / 180.0
        let lst = gmst + lon
        let hourAngle = lst - atan2(sin(lambda) * cos(epsilon), cos(lambda))
        
        // Solar elevation angle
        let sinElev = sin(lat) * sin(delta) + cos(lat) * cos(delta) * cos(hourAngle)
        let elevation = asin(max(-1.0, min(1.0, sinElev))) * 180.0 / .pi
        
        // Civil twilight zenith: 90.833° (accounts for atmospheric refraction + sun disc)
        let isNight = elevation < -0.833  // Below horizon (civil twilight)
        
        DispatchQueue.main.async { [weak self] in
            self?.isAstronomicalNight = isNight
        }
    }
    
    private func daysInMonth(month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2:
            return (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) ? 29 : 28
        default: return 30
        }
    }
}
