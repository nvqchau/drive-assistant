import CoreLocation
import Foundation

final class WeatherService {
    private let queue = DispatchQueue(label: "drive-assistant.weather")
    private var lastRequestDate: Date?
    private var lastRequestLocation: CLLocation?
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    func update(for location: CLLocation, completion: @escaping (RoadCondition) -> Void) {
        queue.async {
            if let lastRequestDate = self.lastRequestDate,
               let lastRequestLocation = self.lastRequestLocation,
               Date().timeIntervalSince(lastRequestDate) < 300,
               location.distance(from: lastRequestLocation) <= 5_000 {
                return
            }

            self.lastRequestDate = Date()
            self.lastRequestLocation = location
            guard var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast") else {
                DispatchQueue.main.async { completion(.dry) }
                return
            }
            components.queryItems = [
                URLQueryItem(name: "latitude", value: String(location.coordinate.latitude)),
                URLQueryItem(name: "longitude", value: String(location.coordinate.longitude)),
                URLQueryItem(name: "current", value: "precipitation,rain,weather_code")
            ]
            guard let url = components.url else {
                DispatchQueue.main.async { completion(.dry) }
                return
            }

            self.session.dataTask(with: url) { data, response, _ in
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode),
                      let data,
                      let payload = try? JSONDecoder().decode(OpenMeteoResponse.self, from: data) else {
                    DispatchQueue.main.async { completion(.dry) }
                    return
                }
                let current = payload.current
                let isWet = current.precipitation > 0.1 || current.rain > 0.1 || current.weatherCode >= 51
                DispatchQueue.main.async { completion(isWet ? .wet : .dry) }
            }.resume()
        }
    }
}

private struct OpenMeteoResponse: Decodable {
    let current: CurrentWeather

    struct CurrentWeather: Decodable {
        let precipitation: Double
        let rain: Double
        let weatherCode: Int

        enum CodingKeys: String, CodingKey {
            case precipitation
            case rain
            case weatherCode = "weather_code"
        }
    }
}
