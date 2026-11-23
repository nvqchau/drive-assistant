import Foundation
import CoreLocation

/// Free OpenStreetMap (Overpass API) road-type lookup for Vietnam TT38 statutory speed limits.
/// Queries Overpass API to determine if current road is divided/dual-carriageway, fetches maxspeed tags,
/// and detects if ego vehicle is inside a residential/urban area for automatic TT38 50/60 km/h limit.
@MainActor
final class RoadMetadataService: ObservableObject {
    @Published var isDividedRoad: Bool = false
    @Published var roadMaxSpeed: Int? = nil
    @Published var osmIsInResidentialArea: Bool? = nil  // nil=unknown until first Overpass response, true=inside, false=outside
    @Published private(set) var lastQueryLocation: CLLocation?
    @Published private(set) var isQuerying: Bool = false
    @Published private(set) var lastQueryDate: Date?
    @Published var detectedCountryCode: String? = nil  // ISO country code from CLGeocoder

    // Diagnostics for road metadata updates
    private weak var diagnostics: DiagnosticsLogStore?
    private var lastLoggedResidential: Bool? = nil
    private var lastLoggedDivided: Bool? = nil
    // Track if we've logged the first geocoder/overpass result for visibility
    private var hasLoggedFirstGeocoder = false
    private var hasLoggedFirstOverpass = false

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
    var cachedSubLocality: String? = nil
    // Cached urban/rural result from full CLPlacemark evaluation (never nil after first geocoder success)
    var cachedUrbanFromGeocoder: Bool? = nil

    /// Attach diagnostics store for road metadata update logging
    func attachDiagnostics(_ diagnostics: DiagnosticsLogStore) {
        self.diagnostics = diagnostics
    }

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

        // 1. CLGeocoder first: get country code + full placemark for Vietnam urban/rural detection
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            if let pm = placemarks.first {
                self.detectedCountryCode = pm.isoCountryCode?.uppercased()
                self.cachedSubLocality = pm.subLocality
                // Evaluate residential status from full CLPlacemark context (handles nil subLocality in Hue)
                let oldResidential = self.osmIsInResidentialArea
                let fromGeocoder = evaluateResidentialFromPlacemark(pm)
                if fromGeocoder != nil {
                    self.osmIsInResidentialArea = fromGeocoder
                    self.cachedUrbanFromGeocoder = fromGeocoder
                }
                // Always log first CLGeocoder result for full visibility
                let country = self.detectedCountryCode ?? "unknown"
                let locality = pm.locality ?? "unknown"
                let subLocality = pm.subLocality ?? "nil"
                let thoroughfare = pm.thoroughfare ?? "nil"
                let adminArea = pm.administrativeArea ?? "nil"
                if !hasLoggedFirstGeocoder || fromGeocoder != oldResidential {
                    diagnostics?.record(type: "road_metadata_updated",
                        details: "country=\(country) adminArea=\(adminArea) locality=\(locality) subLocality=\(subLocality) thoroughfare=\(thoroughfare) inResidential=\(fromGeocoder?.description ?? "nil") isDivided=\(isDividedRoad) source=geocoder")
                    lastLoggedResidential = fromGeocoder
                    hasLoggedFirstGeocoder = true
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
            let oldDivided = self.isDividedRoad
            let oldResidential = self.osmIsInResidentialArea
            self.isDividedRoad = result.isDivided
            self.roadMaxSpeed = result.maxSpeed
            self.osmIsInResidentialArea = result.isInResidentialArea

            // Always log first Overpass result for full visibility
            let country = detectedCountryCode ?? "unknown"
            let locality = self.cachedSubLocality ?? "unknown"
            let subLocality = cachedSubLocality ?? "nil"
            let thoroughfare = "nil"
            let adminArea = "nil"
            if !hasLoggedFirstOverpass || result.isDivided != oldDivided || result.isInResidentialArea != oldResidential {
                diagnostics?.record(type: "road_metadata_updated",
                    details: "country=\(country) adminArea=\(adminArea) locality=\(locality) subLocality=\(subLocality) thoroughfare=\(thoroughfare) inResidential=\(result.isInResidentialArea) isDivided=\(result.isDivided) source=overpass")
                lastLoggedDivided = result.isDivided
                lastLoggedResidential = result.isInResidentialArea
                hasLoggedFirstOverpass = true
            }
        } catch {
            // Offline-safe: silently ignore, keep last known values
            print("RoadMetadataService: Overpass query failed: \(error)")
        }
    }

    /// Evaluate residential/urban status from full CLPlacemark context (Apple's administrative names).
    /// Returns: true = urban (phường/thị trấn/city), false = rural (xã), nil = unknown/unable to determine.
    func evaluateResidentialFromPlacemark(_ pm: CLPlacemark) -> Bool? {
        let countryCode = pm.isoCountryCode?.uppercased() ?? detectedCountryCode ?? "XX"

        // Vietnam-specific logic: Apple Maps in Huế puts "Hue"/"Thuan Hoa" in locality,
        // street names in thoroughfare, and subLocality may be nil
        if countryCode == "VN" {
            let sub = (pm.subLocality ?? "").lowercased()
            let loc = (pm.locality ?? "").lowercased()
            let thorough = (pm.thoroughfare ?? "").lowercased()
            let name = (pm.name ?? "").lowercased()
            let admin = (pm.administrativeArea ?? "").lowercased()

            // Rural markers: "xã " prefix, " xa " infix, " xã" suffix, exact "xã"
            // Check subLocality, locality, and name fields
            let allFields = [sub, loc, name, admin]
            for field in allFields {
                if field.hasPrefix("xã ") || field.contains(" xa ") || field.hasSuffix(" xã") || field == "xã" {
                    return false
                }
            }

            // Urban markers: "phường", "phuong", "thị trấn", "thi tran", "quận", "quan",
            // "thành phố", "tp.", "huế", "hue", "đà nẵng", "da nang", "hà nội", "hanoi",
            // "hồ chí minh", "ho chi minh", "cần thơ", "hải phòng"
            let urbanMarkers = ["phường", "phuong", "thị trấn", "thi tran", "quận", "quan",
                                "thành phố", "tp.", "huế", "hue", "đà nẵng", "da nang",
                                "hà nội", "hanoi", "hồ chí minh", "ho chi minh",
                                "cần thơ", "can tho", "hải phòng", "hai phong"]
            for field in allFields {
                for marker in urbanMarkers {
                    if field.contains(marker) {
                        return true
                    }
                }
            }

            // Heuristic: non-empty thoroughfare (urban street name) that is NOT a national/provincial highway
            // National highways: "QL", "quốc lộ", "cao tốc", "DT", "đt", "TL", "tỉnh lộ"
            if !thorough.isEmpty {
                let highwayMarkers = ["ql ", "quốc lộ", "cao tốc", "dt ", "đt ", "tl ", "tỉnh lộ"]
                let isHighway = highwayMarkers.contains { thorough.contains($0) }
                if !isHighway {
                    return true
                }
            }

            // If we have locality but no rural/urban markers, assume urban (city center)
            if !loc.isEmpty {
                return true
            }

            return nil
        }

        // Non-Vietnam: fallback to subLocality only
        return evaluateResidentialFromSubLocality(pm.subLocality)
    }

    /// Evaluate residential/urban status from CLGeocoder subLocality only (legacy fallback).
    /// Returns: true = urban (phường/thị trấn), false = rural (xã), nil = unknown/unable to determine.
    func evaluateResidentialFromSubLocality(_ subLocality: String?) -> Bool? {
        guard let sub = subLocality else { return nil }
        let lower = sub.lowercased()
        let countryCode = detectedCountryCode ?? "XX"

        // Vietnam-specific logic: CLGeocoder often returns subLocality WITHOUT "Phường" prefix
        // e.g., "Thuan Hoa", "Thuận Hóa", "Phu Hoi" instead of "Phường Thuận Hóa"
        // Rural communes consistently include "Xã" or "Xa " prefix/suffix.
        if countryCode == "VN" {
            // Rural markers: "xã " prefix, " xa " infix, " xã" suffix, exact "xã"
            if lower.hasPrefix("xã ") || lower.contains(" xa ") || lower.hasSuffix(" xã") || lower == "xã" {
                return false
            }
            // Urban markers: "phường", "phuong", "thị trấn", "thi tran"
            if lower.contains("phường") || lower.contains("phuong") || lower.contains("thị trấn") || lower.contains("thi tran") {
                return true
            }
            // Heuristic: non-empty subLocality inside a city (locality non-empty) without rural marker -> urban
            // Note: caller must ensure locality context is available; we assume urban if not rural
            if !lower.isEmpty {
                return true
            }
            return nil
        }

        // Non-Vietnam: original logic
        if lower.contains("phường") || lower.contains("thị trấn") {
            return true
        }
        if lower.hasPrefix("xã ") || lower == "xã" || lower.hasSuffix(" xã") {
            return false
        }
        return nil
    }

    /// Parse Overpass JSON response for oneway, dual_carriageway, lanes, maxspeed tags,
    /// and residential/urban area detection.
    func parseOverpassResponse(_ data: Data) throws -> (isDivided: Bool, maxSpeed: Int?, isInResidentialArea: Bool) {
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
        // Initialize from cached CLGeocoder full-placemark evaluation (never overwritten by Overpass).
        // cachedUrbanFromGeocoder is set in queryRoadMetadata after successful geocoder call.
        // Fallback to evaluating cachedSubLocality for backward compatibility with direct test calls.
        let geocoderUrban = cachedUrbanFromGeocoder ?? evaluateResidentialFromSubLocality(cachedSubLocality)
        var foundVietnamWardOrTownship = (isVN && geocoderUrban == true)

        // Priority: primary > secondary > tertiary > unclassified > residential > service > living_street
        let highwayPriority: [String: Int] = [
            "motorway": 7, "trunk": 6, "primary": 5, "secondary": 4,
            "tertiary": 3, "unclassified": 2, "residential": 1, "service": 0, "living_street": 0
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
                    // Direct urban markers: Phường, Thị trấn, Quận (district), Huyện (district)
                    let hasUrbanMarker = lower.contains("phường") || lower.contains("thị trấn") || lower.contains("quận") || lower.contains("huyện")
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