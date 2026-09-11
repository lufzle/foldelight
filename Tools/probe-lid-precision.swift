// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
// Read-only: waits at most 180 seconds for a two-degree movement, then records 12 seconds.
// Usage: swift Tools/probe-lid-precision.swift /tmp/lid-trace.csv
import Foundation
import IOKit.hid
import QuartzCore
let matching: [String: Any] = [kIOProviderClassKey: "IOHIDDevice", kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 0x8a]
let service = IOServiceGetMatchingService(kIOMainPortDefault, matching as CFDictionary)
guard service != 0, let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { exit(1) }
IOObjectRelease(service)
guard IOHIDDeviceOpen(device, 0) == 0 else { exit(1) }
defer { IOHIDDeviceClose(device, 0) }
func read(_ id: Int) -> (Double, Int, UInt64?) {
    var data = [UInt8](repeating: 0, count: 8), count = 8
    let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, id, &data, &count)
    let value = result == 0 && count >= 3 && count <= 8 ? data[1..<count].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) } : nil
    return (CACurrentMediaTime(), count, value)
}
let origin = CACurrentMediaTime()
var began: Double?, first: UInt64?, rows: [String] = []
var next = origin
while CACurrentMediaTime() - origin < 180 {
    let (t1, _, coarse) = read(1)
    let (t7, count, fine) = read(7)
    if first == nil { first = fine }
    if began == nil, let first, let fine, abs(Double(fine) - Double(first)) >= 200 { began = t7 }
    if began != nil {
        rows.append(String(format:"%.9f,%.9f,%llu,%llu,%d", t1-origin, t7-origin, coarse ?? UInt64.max, fine ?? UInt64.max, count))
        if t7 - began! >= 12 { break }
    }
    next += 1.0/120
    let delay=next-CACurrentMediaTime()
    if delay>0 { Thread.sleep(forTimeInterval:delay) } else { next=CACurrentMediaTime() }
}
try ("coarse_read_s,fine_read_s,coarse_degrees,fine_hundredths,report_length\n"+rows.joined(separator:"\n")+"\n").write(toFile:CommandLine.arguments.dropFirst().first ?? "/tmp/foldelight-precision-trace.csv",atomically:true,encoding:.utf8)
print("TRACE_ROWS",rows.count)
