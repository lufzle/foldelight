// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Low-frequency diagnostics only. No desktop pixels or per-frame disk writes.
final class DebugLog {
    static let shared = DebugLog()
    private let lock = NSLock()
    private let directory: URL
    private let limit: Int
    private var handle: FileHandle?
    private var bytes = 0
    private let timestamp = ISO8601DateFormatter()
    private(set) var lastError: String?

    init(directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("foldelight-debug", isDirectory: true), limit: Int = 2 * 1024 * 1024) {
        self.directory = directory
        self.limit = limit
    }
    var folder: URL { directory }
    var enabled: Bool { lock.lock(); defer { lock.unlock() }; return handle != nil }

    @discardableResult func setEnabled(_ enabled: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        do {
            if enabled {
                guard handle == nil else { return true }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try open()
                try append("Debug enabled · pid \(ProcessInfo.processInfo.processIdentifier) · \(ProcessInfo.processInfo.operatingSystemVersionString)")
            } else {
                if handle != nil { try append("Debug disabled") }
                try handle?.close(); handle = nil
            }
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            try? handle?.close(); handle = nil
            NSLog("foldelight debug logging failed: %@", error.localizedDescription)
            return false
        }
    }
    private func open() throws {
        let file = directory.appendingPathComponent("foldelight.log")
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        handle = try FileHandle(forWritingTo: file)
        bytes = Int(try handle!.seekToEnd())
    }
    private func append(_ message: String) throws {
        guard let handle else { return }
        let data = Data("\(timestamp.string(from: Date())) \(message)\n".utf8)
        if bytes + data.count > limit {
            try handle.close(); self.handle = nil
            let manager = FileManager.default
            let oldest = directory.appendingPathComponent("foldelight.2.log")
            if manager.fileExists(atPath: oldest.path) { try manager.removeItem(at: oldest) }
            let previous = directory.appendingPathComponent("foldelight.1.log")
            if manager.fileExists(atPath: previous.path) { try manager.moveItem(at: previous, to: oldest) }
            try manager.moveItem(at: directory.appendingPathComponent("foldelight.log"), to: previous)
            try open()
        }
        try self.handle?.write(contentsOf: data)
        bytes += data.count
    }
    func write(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        do { try append(message) }
        catch { lastError = error.localizedDescription; try? handle?.close(); handle = nil }
    }
    static func log(_ format: String, _ arguments: CVarArg...) {
        let message = String(format: format, arguments: arguments)
        NSLog("%@", message)
        shared.write(message)
    }
}
