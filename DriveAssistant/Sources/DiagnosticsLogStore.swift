import Foundation
import UIKit
import os
import Combine

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
    private let maxEvents = 5000
    private let logger = Logger(subsystem: "vn.ai.driveassistant", category: "Diagnostics")

    // Publisher for real-time event observation
    let eventPublisher = PassthroughSubject<DiagnosticEvent, Never>()

    // Daily file logging
    private let dailyLogQueue = DispatchQueue(label: "vn.ai.driveassistant.daily-log", qos: .utility)
    private var currentDailyLogDate: Date?
    private var currentDailyLogHandle: FileHandle?

    init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [] // compact JSON Lines
    }

    func record(type: String, speedKMPH: Double? = nil, distanceMeters: Double? = nil, isDangerous: Bool? = nil, orientation: String? = nil, details: String? = nil) {
        let event = DiagnosticEvent(timestamp: Date(), type: type, speedKMPH: speedKMPH, distanceMeters: distanceMeters, isDangerous: isDangerous, orientation: orientation, details: details)
        lock.lock()
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        lock.unlock()

        // Persist to daily JSONL file asynchronously
        appendToDailyLog(event)

        // Emit event for real-time observers
        eventPublisher.send(event)
    }

    private func appendToDailyLog(_ event: DiagnosticEvent) {
        dailyLogQueue.async { [weak self] in
            self?.writeEventToDailyLog(event)
        }
    }

    private func writeEventToDailyLog(_ event: DiagnosticEvent) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Check if we need to rotate to a new day's file
        if currentDailyLogDate != today {
            closeCurrentDailyLog()
            openDailyLogForDate(today)
        }

        guard let handle = currentDailyLogHandle else { return }

        do {
            let data = try encoder.encode(event)
            var jsonString = String(data: data, encoding: .utf8) ?? ""
            jsonString += "\n"
            if let lineData = jsonString.data(using: .utf8) {
                handle.seekToEndOfFile()
                handle.write(lineData)
            }
        } catch {
            logger.error("Failed to encode daily log event: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func openDailyLogForDate(_ date: Date) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let fileName = "DriveAssistant-\(formatter.string(from: date)).jsonl"

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let logsDir = documentsURL.appendingPathComponent("DriveAssistantLogs", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.error("Failed to create logs directory: \(error.localizedDescription, privacy: .public)")
            return
        }

        let fileURL = logsDir.appendingPathComponent(fileName)

        // Create file if it doesn't exist
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        }

        do {
            currentDailyLogHandle = try FileHandle(forWritingTo: fileURL)
            currentDailyLogDate = date
        } catch {
            logger.error("Failed to open daily log file: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func closeCurrentDailyLog() {
        currentDailyLogHandle?.closeFile()
        currentDailyLogHandle = nil
        currentDailyLogDate = nil
    }

    func clear() {
        lock.lock()
        events.removeAll()
        lock.unlock()

        // Close active FileHandle BEFORE deleting files to avoid leaking open fd on deleted inode
        closeCurrentDailyLog()

        // Delete all .jsonl files in the logs directory
        dailyLogQueue.async { [weak self] in
            self?.deleteAllDailyLogs()
        }
    }

    private func deleteAllDailyLogs() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let logsDir = documentsURL.appendingPathComponent("DriveAssistantLogs", isDirectory: true)

        guard FileManager.default.fileExists(atPath: logsDir.path) else { return }

        do {
            let files = try FileManager.default.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "jsonl" {
                try FileManager.default.removeItem(at: file)
            }
        } catch {
            logger.error("Failed to delete daily logs: \(error.localizedDescription, privacy: .public)")
        }
    }

    func exportURL() -> URL {
        let exportedEvents: [DiagnosticEvent]
        lock.lock()
        exportedEvents = events
        lock.unlock()

        // If no in-memory events, try to read today's daily log file
        let eventsToExport: [DiagnosticEvent]
        if exportedEvents.isEmpty {
            eventsToExport = readTodaysDailyLog()
        } else {
            eventsToExport = exportedEvents
        }

        let payload: [String: AnyEncodable] = [
            "app": AnyEncodable("DriveAssistant"),
            "bundleID": AnyEncodable(Bundle.main.bundleIdentifier ?? "unknown"),
            "systemVersion": AnyEncodable(UIDevice.current.systemVersion),
            "deviceModel": AnyEncodable(UIDevice.current.model),
            "events": AnyEncodable(eventsToExport)
        ]

        // Use pretty-printed encoder for export
        let exportEncoder = JSONEncoder()
        exportEncoder.dateEncodingStrategy = .iso8601
        exportEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data: Data
        do {
            data = try exportEncoder.encode(payload)
        } catch {
            logger.error("Failed to encode diagnostics: \(error.localizedDescription, privacy: .public)")
            data = Data("{\"error\":\"Unable to encode diagnostics\"}".utf8)
        }

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = documentsURL.appendingPathComponent("DriveAssistant-Export-\(formatter.string(from: Date())).json")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to write diagnostics export: \(error.localizedDescription, privacy: .public)")
        }
        return url
    }

    private func readTodaysDailyLog() -> [DiagnosticEvent] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let fileName = "DriveAssistant-\(formatter.string(from: today)).jsonl"

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let logsDir = documentsURL.appendingPathComponent("DriveAssistantLogs", isDirectory: true)
        let fileURL = logsDir.appendingPathComponent(fileName)

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let lines = String(data: data, encoding: .utf8)?.split(separator: "\n") ?? []
            var events: [DiagnosticEvent] = []
            for line in lines {
                if let lineData = line.data(using: .utf8),
                   let event = try? decoder.decode(DiagnosticEvent.self, from: lineData) {
                    events.append(event)
                }
            }
            return events
        } catch {
            logger.error("Failed to read today's daily log: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    deinit {
        closeCurrentDailyLog()
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