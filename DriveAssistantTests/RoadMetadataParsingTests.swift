import XCTest
import CoreLocation
@testable import DriveAssistant

/// Tests for RoadMetadataService: Vietnam admin boundary parsing, residential detection, divided road detection.
@MainActor
final class RoadMetadataParsingTests: XCTestCase {

    var service: RoadMetadataService!

    override func setUp() {
        super.setUp()
        service = RoadMetadataService()
    }

    // MARK: - Vietnam Urban Ward Recognition (CLGeocoder subLocality)

    func testEvaluateResidentialFromSubLocality_Phuong_ReturnsTrue() {
        let result = service.evaluateResidentialFromSubLocality("Phường 1")
        XCTAssertTrue(result == true, "Phường should be urban (true)")

        let result2 = service.evaluateResidentialFromSubLocality("PHƯỜNG BÌNH THẠNH")
        XCTAssertTrue(result2 == true, "Uppercase Phường should be urban")
    }

    func testEvaluateResidentialFromSubLocality_ThiTran_ReturnsTrue() {
        let result = service.evaluateResidentialFromSubLocality("Thị trấn Củ Chi")
        XCTAssertTrue(result == true, "Thị trấn should be urban (true)")

        let result2 = service.evaluateResidentialFromSubLocality("THỊ TRẤN HÓA HỮU")
        XCTAssertTrue(result2 == true, "Uppercase Thị trấn should be urban")
    }

    func testEvaluateResidentialFromSubLocality_Xa_ReturnsFalse() {
        let result = service.evaluateResidentialFromSubLocality("Xã An Phú")
        XCTAssertFalse(result == true, "Xã should be rural (false)")

        let result2 = service.evaluateResidentialFromSubLocality("XÃ TÂN HÒA")
        XCTAssertFalse(result2 == true, "Uppercase Xã should be rural")

        let result3 = service.evaluateResidentialFromSubLocality("xã") // exact match
        XCTAssertFalse(result3 == true, "Exact 'xã' should be rural")

        let result4 = service.evaluateResidentialFromSubLocality("An Phú xã") // suffix
        XCTAssertFalse(result4 == true, "Suffix ' xã' should be rural")
    }

    func testEvaluateResidentialFromSubLocality_Ambiguous_ReturnsNil() {
        let result = service.evaluateResidentialFromSubLocality("Quận 1")
        XCTAssertNil(result, "Quận should be ambiguous (nil)")

        let result2 = service.evaluateResidentialFromSubLocality("Huyện Củ Chi")
        XCTAssertNil(result2, "Huyện should be ambiguous (nil)")

        let result3 = service.evaluateResidentialFromSubLocality(nil)
        XCTAssertNil(result3, "nil should return nil")

        let result4 = service.evaluateResidentialFromSubLocality("")
        XCTAssertNil(result4, "Empty string should return nil")
    }

    // MARK: - Overpass Response Parsing: Divided Road Detection

    func testParseOverpassResponse_OnewayYes_IsDivided() throws {
        let json = """
        {"elements":[{"tags":{"highway":"primary","oneway":"yes","name":"QL1A"}}]}
        """
        let result = try service.parseOverpassResponseForTest(json.data(using: .utf8)!)
        XCTAssertTrue(result.isDivided, "oneway=yes should be divided")
    }

    func testParseOverpassResponse_DualCarriagewayYes_IsDivided() throws {
        let json = """
        {"elements":[{"tags":{"highway":"trunk","dual_carriageway":"yes","name":"QL1"}}]}
        """
        let result = try service.parseOverpassResponseForTest(json.data(using: .utf8)!)
        XCTAssertTrue(result.isDivided, "dual_carriageway=yes should be divided")
    }

    func testParseOverpassResponse_Lanes2OrMore_Primary_IsDivided() throws {
        let json = """
        {"elements":[{"tags":{"highway":"primary","lanes":"2","name":"ĐTL"}}]}
        """
        let result = try service.parseOverpassResponseForTest(json.data(using: .utf8)!)
        XCTAssertTrue(result.isDivided, "primary with lanes=2 should be divided")
    }

    func testParseOverpassResponse_Lanes2_Residential_NotDivided() throws {
        let json = """
        {"elements":[{"tags":{"highway":"residential","lanes":"2","name":"Ngõ 123"}}]}
        """
        let result = try service.parseOverpassResponseForTest(json.data(using: .utf8)!)
        XCTAssertFalse(result.isDivided, "residential with lanes=2 should NOT be divided")
    }

    func testParseOverpassResponse_Lanes2_Service_NotDivided() throws {
        let json = """
        {"elements":[{"tags":{"highway":"service","lanes":"2","name":"Đường vào bãi xe"}}]}
        """
        let result = try service.parseOverpassResponseForTest(json.data(using: .utf8)!)
        XCTAssertFalse(result.isDivided, "service with lanes=2 should NOT be divided")
    }

    func testParseOverpassResponse_Unclassified_SingleLane_NotDivided() throws {
        let json = """
        {"elements":[{"tags":{"highway":"unclassified","lanes":"1","name":"Đường địa phương"}}]}
        """
        let result = try service.parseOverpassResponseForTest(json.data(using: .utf8)!)
        XCTAssertFalse(result.isDivided, "unclassified single lane should NOT be divided")
    }

    // MARK: - Overpass Response Parsing: Residential/Urban Area Detection

    func testParseOverpassResponse_LanduseResidential_IsResidential() throws {
        let json = """
        {"elements":[{"tags":{"landuse":"residential","name":"Khu dân cư"}}]}
        """
        let result = try service.parseOverpassResponseForTest(json.data(using: .utf8)!)
        XCTAssertTrue(result.isInResidentialArea, "landuse=residential should be residential area")
    }

    func testParseOverpassResponse_PlaceTown_IsUrban() throws {
        let json = """
        {"elements":[{"tags":{"place":"town","name":"Thị xã Củ Chi"}}]}
        """
        let result = try service.parseOverpassResponseForTest(json.data(using: .utf8)!)
        XCTAssertTrue(result.isInResidentialArea, "place=town should be urban area")
    }

    func testParseOverpassResponse_PlaceSuburb_IsUrban() throws {
        let json = """
        {"elements":[{"tags":{"place":"suburb","name":"Quận 7"}}]}
        """
        let result = try service.parseOverpassResponseForTest(json.data(using: .utf8)!)
        XCTAssertTrue(result.isInResidentialArea, "place=suburb should be urban area")
    }

    func testParseOverpassResponse_PlaceQuarter_IsUrban() throws {
        let json = """
        {"elements":[{"tags":{"place":"quarter","name":"Khu phố 5"}}]}
        """
        let result = try service.parseOverpassResponseForTest(json.data(using: .utf8)!)
        XCTAssertTrue(result.isInResidentialArea, "place=quarter should be urban area")
    }

    func testParseOverpassResponse_PlaceNeighbourhood_IsUrban() throws {
        let json = """
        {"elements":[{"tags":{"place":"neighbourhood","name":"Khu dân cư A"}}]}
        """
        let result = try service.parseOverpassResponseForTest(json.data(using: .utf8)!)
        XCTAssertTrue(result.isInResidentialArea, "place=neighbourhood should be urban area")
    }

    func testParseOverpassResponse_PlaceVillage_IsUrban() throws {
        let json = """
        {"elements":[{"tags":{"place":"village","name":"Làng Cổ"}}]}
        """
        let result = try service.parseOverpassResponseForTest(json.data(using: .utf8)!)
        XCTAssertTrue(result.isInResidentialArea, "place=village should be urban area")
    }

    func testParseOverpassResponse_PlaceCity_Excluded() throws {
        // "city" was removed from place regex to avoid false positives
        let json = """
        {"elements":[{"tags":{"place":"city","name":"TP.HCM"}}]}
        """
        let result = try service.parseOverpassResponseForTest(json.data(using: .utf8)!)
        XCTAssertFalse(result.isInResidentialArea, "place=city should NOT count as urban (excluded from regex)")
    }

    func testParseOverpassResponse_HighwayResidential_IsResidential() throws {
        let json = """
        {"elements":[{"tags":{"highway":"residential","name":"Ngõ 123"}}]}
        """
        let result = try service.parseOverpassResponseForTest(json.data(using: .utf8)!)
        XCTAssertTrue(result.isInResidentialArea, "highway=residential should be residential area")
    }

    func testParseOverpassResponse_HighwayLivingStreet_IsResidential() throws {
        let json = """
        {"elements":[{"tags":{"highway":"living_street","name":"Đường bộ hành"}}]}
        """
        let result = try service.parseOverpassResponseForTest(json.data(using: .utf8)!)
        XCTAssertTrue(result.isInResidentialArea, "highway=living_street should be residential area")
    }

    // MARK: - Vietnam Admin Level 6/8 Boundary Parsing

    func testParseOverpassResponse_AdminLevel8_Phuong_IsUrban() throws {
        let json = """
        {"elements":[{"tags":{"admin_level":"8","name":"Phường Bến Nghé"}}]}
        """
        let result = try service.parseOverpassResponseForTest(json.data(using: .utf8)!)
        XCTAssertTrue(result.isInResidentialArea, "admin_level=8 with Phường should be urban")
    }

    func testParseOverpassResponse_AdminLevel8_ThiTran_IsUrban() throws {
        let json = """
        {"elements":[{"tags":{"admin_level":"8","name":"Thị trấn Củ Chi"}}]}
        """
        let result = try service.parseOverpassResponseForTest(json.data(using: .utf8)!)
        XCTAssertTrue(result.isInResidentialArea, "admin_level=8 with Thị trấn should be urban")
    }

    func testParseOverpassResponse_AdminLevel8_Xa_IsRural() throws {
        let json = """
        {"elements":[{"tags":{"admin_level":"8","name":"Xã An Phú"}}]}
        """
        let result = try service.parseOverpassResponseForTest(json.data(using: .utf8)!)
        XCTAssertFalse(result.isInResidentialArea, "admin_level=8 with Xã should be rural (false)")
    }

    func testParseOverpassResponse_AdminLevel8_NoXaMarker_IsUrban() throws {
        // Admin level 8 without "Xã" marker treated as urban ward (e.g., "Thuận Hóa")
        let json = """
        {"elements":[{"tags":{"admin_level":"8","name":"Thuận Hóa"}}]}
        """
        let result = try service.parseOverpassResponseForTest(json.data(using: .utf8)!)
        XCTAssertTrue(result.isInResidentialArea, "admin_level=8 without Xã should be urban")
    }

    func testParseOverpassResponse_AdminLevel6_IsUrban() throws {
        let json = """
        {"elements":[{"tags":{"admin_level":"6","name":"Quận 1"}}]}
        """
        let result = try service.parseOverpassResponseForTest(json.data(using: .utf8)!)
        XCTAssertTrue(result.isInResidentialArea, "admin_level=6 should be urban")
    }

    func testParseOverpassResponse_AdminLevel4_Excluded() throws {
        // Admin level 4 (provincial) should be excluded from query and not affect result
        let json = """
        {"elements":[{"tags":{"admin_level":"4","name":"TP.HCM"}}]}
        """
        let result = try service.parseOverpassResponseForTest(json.data(using: .utf8)!)
        XCTAssertFalse(result.isInResidentialArea, "admin_level=4 should NOT affect residential detection")
    }

    // MARK: - CLGeocoder Cross-Check Priority

    func testCLGeocoderUrbanMatch_PersistsWhenOverpassOmitsAdminLevel8() throws {
        // Simulate CLGeocoder returning urban subLocality
        service.cachedSubLocality = "Phường Bến Nghé"
        service.detectedCountryCode = "VN"

        // Overpass response OMITS admin_level=8 but has highway
        let json = """
        {"elements":[{"tags":{"highway":"primary","name":"QL1A"}}]}
        """
        let result = try service.parseOverpassResponseForTest(json.data(using: .utf8)!)

        // The urban match from CLGeocoder should persist because foundVietnamWardOrTownship
        // is initialized from cachedSubLocality BEFORE the loop
        XCTAssertTrue(result.isInResidentialArea, "CLGeocoder urban match should persist when Overpass omits admin_level=8")
    }

    func testCLGeocoderRuralMatch_OverriddenByOverpassUrban() throws {
        // CLGeocoder says rural
        service.cachedSubLocality = "Xã An Phú"
        service.detectedCountryCode = "VN"

        // But Overpass has urban admin_level=8
        let json = """
        {"elements":[{"tags":{"admin_level":"8","name":"Phường Bến Nghé"}}]}
        """
        let result = try service.parseOverpassResponseForTest(json.data(using: .utf8)!)

        // Overpass urban should override CLGeocoder rural
        XCTAssertTrue(result.isInResidentialArea, "Overpass urban admin_level=8 should override CLGeocoder rural")
    }
}

// Test helper extension to expose private parseOverpassResponse
extension RoadMetadataService {
    func parseOverpassResponseForTest(_ data: Data) throws -> (isDivided: Bool, maxSpeed: Int?, isInResidentialArea: Bool) {
        // Need to set detectedCountryCode for Vietnam tests
        self.detectedCountryCode = "VN"
        return try self.parseOverpassResponse(data)
    }
}