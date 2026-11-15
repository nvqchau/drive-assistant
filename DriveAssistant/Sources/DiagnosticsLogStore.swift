import Foundation
import UIKit

struct DiagnosticEvent: Codable {
    let timestamp: Date
    let type: String
    let speedKMPH: Double?
    let distanceMeters: Double?
    let isDangerous: Bool?
    let orientation: String?
    let details: String?
}

final class DiagnosticsLogStore {
    private var events: [DiagnosticEvent] = []
    private let lock = NSLock()
    private let encoder: JSONEncoder

    init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func record(type: String, speedKMPH: Double? = nil, distanceMeters: Double? = nil, isDangerous: Bool? = nil, orientation: String? = nil, details: String? = nil) {
        let event = DiagnosticEvent(timestamp: Date(), type: type, speedKMPH: speedKMPH, distanceMeters: distanceMeters, isDangerous: isDangerous, orientation: orientation, details: details)
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        events.removeAll()
        lock.unlock()
    }

    func exportURL() -> URL {
        let exportedEvents: [DiagnosticEvent]
        lock.lock()
        exportedEvents = events
        lock.unlock()

        let payload: [String: AnyEncodable] = [
            "app": AnyEncodable("DriveAssistant"),
            "bundleID": AnyEncodable(Bundle.main.bundleIdentifier ?? "unknown"),
            "systemVersion": AnyEncodable(UIDevice.current.systemVersion),
            "deviceModel": AnyEncodable(UIDevice.current.model),
            "events": AnyEncodable(exportedEvents)
        ]

        let data: Data
        do {
            data = try encoder.encode(payload)
        } catch {
            data = Data("{\"error\":\"Unable to encode diagnostics\"}".utf8)
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DriveAssistant-\(timestamp()).json")
        try? data.write(to: url, options: .atomic)
        return url
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T) {
        encodeValue = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}
