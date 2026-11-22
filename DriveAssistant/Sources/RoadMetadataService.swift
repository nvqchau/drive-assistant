import Foundation
import CoreLocation

/// Free OpenStreetMap (Overpass API) road-type lookup for Vietnam TT38 statutory speed limits.
/// Queries Overpass API to determine if current road is divided/dual-carriageway, fetches maxspeed tags,
/// and detects if ego vehicle is inside a residential/urban area for automatic TT38 50/60 km/h limit.
@MainActor
final class RoadMetadataService: ObservableObject {
    @Published private(set) var isDividedRoad: Bool = false
    @Published private(set) var roadMaxSpeed: Int? = nil
    @Published private(set) var osmIsInResidentialArea: Bool? = nil  // nil=unknown until first Overpass response, true=inside, false=outside
    @Published private(set) var lastQueryLocation: CLLocation?
    @Published private(set) var isQuerying: Bool = false
    @Published private(set) var lastQueryDate: Date?
    @Published private(set) var detectedCountryCode: String? = nil  // ISO country code from CLGeocoder

    // Throttling: max once per 20s or 150m travel
    private let minQueryInterval: TimeInterval = 20.0
    private let minDistanceMeters: Double = 150.0
    private var lastQueryTime: Date = .distantPast
    private let queryRadius: Double = 25.0  // meters
    private let overpassURL = "https://overpass-api.de/api/interpreter"
    private let requestTimeout: TimeInterval = 8.0

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8.0
        config.timeoutIntervalForResource = 8.0
        return URLSession(configuration: config)
    }()
    private let geocoder = CLGeocoder()

    // Cached subLocality from CLGeocoder (e.g., "Phường X", "Thị trấn Y", "Xã Z") for Vietnam admin boundary resolution
    private var cachedSubLocality: String? = nil

    /// Call from LocationManager when location updates significantly.
    func maybeQueryRoadMetadata(for location: CLLocation) {
        let now = Date()
        // Time throttle
        if now.timeIntervalSince(lastQueryTime) < minQueryInterval { return }
        // Distance throttle
        if let lastLoc = lastQueryLocation, location.distance(from: lastLoc) < minDistanceMeters { return }

        lastQueryTime = now
        lastQueryLocation = location
        Task { await queryRoadMetadata(for: location) }
    }

    private func queryRoadMetadata(for location: CLLocation) async {
        isQuerying = true
        defer { isQuerying = false; lastQueryDate = Date() }

        // 1. CLGeocoder first: get country code + subLocality (ward/commune/township name)
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            if let pm = placemarks.first {
                self.detectedCountryCode = pm.isoCountryCode?.uppercased()
                self.cachedSubLocality = pm.subLocality
                // Immediately evaluate residential status from CLGeocoder subLocality
                // so osmIsInResidentialArea is set even if Overpass is slow/fails
                let fromGeocoder = evaluateResidentialFromSubLocality(pm.subLocality)
                if fromGeocoder != nil {
                    self.osmIsInResidentialArea = fromGeocoder
                }
            }
        } catch {
            // Ignore geocoder errors; continue with Overpass
        }

        // 2. SINGLE combined Overpass query (highway + is_in with admin_level 6/8)
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let query = """
        [out:json][timeout:5];
        way(around:\(queryRadius),\(lat),\(lon))["highway"];
        out tags 1;
        is_in(\(lat),\(lon))->.a;
        area.a["landuse"="residential"];
        out tags 1;
        area.a["place"~"^(town|suburb|quarter|neighbourhood|village)$"];
        out tags 1;
        area.a["admin_level"~"^(6|8)$"];
        out tags 3;
        """

        guard let url = URL(string: overpassURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = query.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout

        do {
            let (data, _) = try await session.data(for: request)
            let result = try parseOverpassResponse(data)
            self.isDividedRoad = result.isDivided
            self.roadMaxSpeed = result.maxSpeed
            self.osmIsInResidentialArea = result.isInResidentialArea
        } catch {
            // Offline-safe: silently ignore, keep last known values
            print("RoadMetadataService: Overpass query failed: \(error)")
        }
    }

    /// Evaluate residential/urban status from CLGeocoder subLocality (Apple's administrative name).
    /// Returns: true = urban (phường/thị trấn), false = rural (xã), nil = unknown/unable to determine.
    private func evaluateResidentialFromSubLocality(_ subLocality: String?) -> Bool? {
        guard let sub = subLocality else { return nil }
        let lower = sub.lowercased()
        // Urban: contains "phường" or "thị trấn"
        if lower.contains("phường") || lower.contains("thị trấn") {
            return true
        }
        // Rural: contains "xã " (with space) or is exactly "xã" or ends with " xã"
        // Note: "xã" alone could be part of a ward name like "xã hội" but that's rare;
        // rural communes consistently carry "Xã" as prefix or standalone.
        if lower.hasPrefix("xã ") || lower == "xã" || lower.hasSuffix(" xã") {
            return false
        }
        return nil  // ambiguous (e.g., some towns without clear marker)
    }

    /// Parse Overpass JSON response for oneway, dual_carriageway, lanes, maxspeed tags,
    /// and residential/urban area detection.
    private func parseOverpassResponse(_ data: Data) throws -> (isDivided: Bool, maxSpeed: Int?, isInResidentialArea: Bool) {
        struct OverpassResponse: Decodable {
            let elements: [Element]
            struct Element: Decodable {
                let tags: [String: String]?
            }
        }
        let response = try JSONDecoder().decode(OverpassResponse.self, from: data)

        var bestHighway: String? = nil
        var bestLanes: Int? = nil
        var bestMaxSpeed: Int? = nil
        var bestOneway: String? = nil
        var bestDualCarriageway: String? = nil
        var foundResidentialArea = false
        var foundUrbanArea = false
        let isVN = detectedCountryCode == "VN"
        // Initialize from CLGeocoder subLocality BEFORE loop so positive urban match
        // is never overwritten if Overpass omits admin_level=8 polygon
        var foundVietnamWardOrTownship = (isVN && evaluateResidentialFromSubLocality(cachedSubLocality) == true)

        // Priority: primary > secondary > tertiary > unclassified > residential > service
        let highwayPriority: [String: Int] = [
            "motorway": 7, "trunk": 6, "primary": 5, "secondary": 4,
            "tertiary": 3, "unclassified": 2, "residential": 1, "service": 0
        ]

        for element in response.elements {
            guard let tags = element.tags else { continue }

            // 1) Residential landuse (universal)
            if tags["landuse"] == "residential" {
                foundResidentialArea = true
            }

            // 2) Urban place types (universal) - excludes "city", "hamlet", "isolated_dwelling"
            if let place = tags["place"],
               ["town", "suburb", "quarter", "neighbourhood", "village"].contains(place) {
                foundUrbanArea = true
            }

            // 3) Admin boundaries: only admin_level 6 (district/huyện) and 8 (ward/commune/township)
            // For Vietnam: check if name contains "Phường" or "Thị trấn" (urban), OR if admin_level 8
            // boundary name does NOT contain "Xã" (rural commune marker).
            // Also cross-check with cachedSubLocality from CLGeocoder.
            if let adminLevel = tags["admin_level"],
               let level = Int(adminLevel),
               (level == 6 || level == 8) {
                let name = tags["name"] ?? ""
                if isVN {
                    let lower = name.lowercased()
                    // Direct urban markers
                    let hasUrbanMarker = lower.contains("phường") || lower.contains("thị trấn")
                    // Rural marker exclusion: admin_level 8 without "xã" implies urban ward
                    // (Vietnam OSM: rural communes consistently have "Xã" in name; urban wards often omit "Phường")
                    let isRuralCommune = lower.hasPrefix("xã ") || lower == "xã" || lower.hasSuffix(" xã")
                    let isAdminLevel8 = level == 8
                    let looksUrban = hasUrbanMarker || (isAdminLevel8 && !isRuralCommune && !name.isEmpty)
                    // Also check cachedSubLocality from CLGeocoder for this location
                    let geocoderUrban = evaluateResidentialFromSubLocality(cachedSubLocality) == true
                    if looksUrban || geocoderUrban {
                        foundVietnamWardOrTownship = true
                    }
                } else {
                    // Non-Vietnam: any admin_level 6/8 counts as urban boundary
                    foundVietnamWardOrTownship = true
                }
            }

            // Track best highway for divided road + residential road fallback
            let highway = tags["highway"] ?? ""
            let priority = highwayPriority[highway] ?? -1
            let currentBestPriority = highwayPriority[bestHighway ?? ""] ?? -1

            if priority > currentBestPriority {
                bestHighway = highway
                bestLanes = Int(tags["lanes"] ?? "")
                bestMaxSpeed = Int(tags["maxspeed"] ?? "")
                bestOneway = tags["oneway"]
                bestDualCarriageway = tags["dual_carriageway"]
            }
        }

        // Determine divided road status
        var isDivided = false
        if bestOneway == "yes" || bestDualCarriageway == "yes" {
            isDivided = true
        } else if let highway = bestHighway, let lanes = bestLanes, lanes >= 2 {
            if highway != "residential" && highway != "service" {
                isDivided = true
            }
        }

        // Determine residential/urban area:
        // - Universal: residential landuse OR urban place (town/suburb/quarter/neighbourhood/village) OR highway=residential/living_street
        // - Vietnam: additionally, admin_level 6/8 with name containing "Phường" or "Thị trấn" (exclude "Xã"),
        //   OR admin_level 8 boundary without "Xã" marker, OR CLGeocoder subLocality indicates urban
        let isInResidentialArea = foundResidentialArea
            || foundUrbanArea
            || (bestHighway == "residential" || bestHighway == "living_street")
            || (isVN && foundVietnamWardOrTownship)

        return (isDivided, bestMaxSpeed, isInResidentialArea)
    }

    /// Manual override from driver tap on HUD pill
    func toggleDividedRoad() {
        isDividedRoad.toggle()
    }
}