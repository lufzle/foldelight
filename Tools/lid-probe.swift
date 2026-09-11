// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import IOKit.hid
let matching: [String: Any] = [kIOProviderClassKey: "IOHIDDevice", kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 0x8a]
let service = IOServiceGetMatchingService(kIOMainPortDefault, matching as CFDictionary)
guard service != 0 else { print("No matching sensor"); exit(1) }
guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { exit(1) }
IOObjectRelease(service)
print("open", IOHIDDeviceOpen(device, 0))
var report = [UInt8](repeating: 0, count: 8)
var length = report.count
print("feature", IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length), "length", length, "bytes", report)
length = report.count
print("input", IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, 1, &report, &length), "length", length, "bytes", report)
IOHIDDeviceRegisterInputValueCallback(device, { _, result, _, value in
 let element = IOHIDValueGetElement(value)
 print("event", result, IOHIDElementGetUsage(element), IOHIDValueGetIntegerValue(value))
}, nil)
IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
RunLoop.main.run(until: Date(timeIntervalSinceNow: 3))
IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
IOHIDDeviceClose(device, 0)
