// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import foldelight

final class DebugLogTests: XCTestCase {
    func testToggleAndRotation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = DebugLog(directory: folder, limit: 250)
        log.write("disabled event")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(log.setEnabled(true))
        for index in 0..<30 { log.write("event \(index) " + String(repeating: "x", count: 60)) }
        XCTAssertTrue(log.setEnabled(false))
        let current = folder.appendingPathComponent("foldelight.log")
        let before = try Data(contentsOf: current)
        log.write("must not be written")
        XCTAssertEqual(try Data(contentsOf: current), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["foldelight.1.log", "foldelight.2.log", "foldelight.log"])
        XCTAssertTrue(log.setEnabled(true))
        XCTAssertTrue(log.enabled)
        XCTAssertTrue(log.setEnabled(false))
    }
    func testConcurrentMessagesAreCompleteUniqueAndUTF8Safe() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = DebugLog(directory: folder)
        XCTAssertTrue(log.setEnabled(true))
        DispatchQueue.concurrentPerform(iterations: 2_000) { index in
            log.write("message-\(index)-é雪")
        }
        XCTAssertTrue(log.setEnabled(false))
        let content = try String(contentsOf: folder.appendingPathComponent("foldelight.log"), encoding: .utf8)
        let messages = content.split(separator: "\n").compactMap { line -> String? in
            guard let range = line.range(of: "message-") else { return nil }
            return String(line[range.lowerBound...])
        }
        XCTAssertEqual(messages.count, 2_000)
        XCTAssertEqual(Set(messages), Set((0..<2_000).map { "message-\($0)-é雪" }))
    }

    func testEnableIsIdempotentAndReenableAppends() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = DebugLog(directory: folder)
        XCTAssertEqual(log.folder, folder)
        XCTAssertFalse(log.enabled)
        XCTAssertTrue(log.setEnabled(false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(log.setEnabled(true))
        XCTAssertTrue(log.setEnabled(true))
        log.write("first-session")
        XCTAssertTrue(log.setEnabled(false))
        XCTAssertTrue(log.setEnabled(true))
        log.write("second-session")
        XCTAssertTrue(log.setEnabled(false))
        let content = try String(contentsOf: folder.appendingPathComponent("foldelight.log"), encoding: .utf8)
        XCTAssertEqual(content.components(separatedBy: "Debug enabled").count - 1, 2)
        XCTAssertEqual(content.components(separatedBy: "Debug disabled").count - 1, 2)
        XCTAssertTrue(content.contains("first-session"))
        XCTAssertTrue(content.contains("second-session"))
        XCTAssertNil(log.lastError)
    }

    func testInvalidDirectoryFailsClosedAndCanRecover() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("occupied".utf8).write(to: folder)
        let log = DebugLog(directory: folder)
        XCTAssertFalse(log.setEnabled(true))
        XCTAssertFalse(log.enabled)
        XCTAssertNotNil(log.lastError)
        log.write("ignored-after-error")
        XCTAssertEqual(try String(contentsOf: folder), "occupied")
        try FileManager.default.removeItem(at: folder)
        XCTAssertTrue(log.setEnabled(true))
        XCTAssertNil(log.lastError)
        XCTAssertTrue(log.setEnabled(false))
    }

    func testRotationRetainsNewestRecordsInOrderAndBoundsDiskUse() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = DebugLog(directory: folder, limit: 512)
        XCTAssertTrue(log.setEnabled(true))
        for index in 0..<100 { log.write("record-\(index) " + String(repeating: "x", count: 60)) }
        XCTAssertTrue(log.setEnabled(false))
        var records: [Int] = []
        for name in ["foldelight.2.log", "foldelight.1.log", "foldelight.log"] {
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            XCTAssertLessThanOrEqual(data.count, 512)
            let content = try XCTUnwrap(String(data: data, encoding: .utf8))
            records += content.split(separator: "\n").compactMap { line in
                guard let range = line.range(of: "record-") else { return nil }
                return Int(line[range.upperBound...].prefix(while: { $0.isNumber }))
            }
        }
        XCTAssertFalse(records.isEmpty)
        XCTAssertEqual(records.last, 99)
        XCTAssertGreaterThan(try XCTUnwrap(records.first), 0)
        XCTAssertEqual(records, Array(try XCTUnwrap(records.first)...99))
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
        let filePermissions = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("foldelight.log").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(filePermissions?.intValue, 0o600)
    }

}
