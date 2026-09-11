// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
// Read-only, five-second input callback probe. No HID writes.
import Foundation
import IOKit.hid
import QuartzCore
let matching: [String: Any] = [kIOProviderClassKey:"IOHIDDevice", kIOHIDPrimaryUsagePageKey:0x20, kIOHIDPrimaryUsageKey:0x8a]
let service=IOServiceGetMatchingService(kIOMainPortDefault,matching as CFDictionary)
guard service != 0, let device=IOHIDDeviceCreate(nil,service) else { exit(1) }
IOObjectRelease(service)
guard IOHIDDeviceOpen(device,0)==0 else { exit(2) }
let elements=IOHIDDeviceCopyMatchingElements(device,nil,0) as? [IOHIDElement] ?? []
for e in elements where IOHIDElementGetUsage(e)==0x545 {print("ELEMENT",IOHIDElementGetReportID(e),IOHIDElementGetLogicalMin(e),IOHIDElementGetLogicalMax(e),IOHIDElementGetUnitExponent(e))}
let bytes=UnsafeMutablePointer<UInt8>.allocate(capacity:64)
bytes.initialize(repeating:0,count:64)
var rows:[String]=[]
IOHIDDeviceRegisterInputReportCallback(device,bytes,64,{ _,result,_,_,id,data,count in
 rows.append("\(CACurrentMediaTime()),\(id),\(result),\(count)," + (0..<count).map{String(format:"%02x",data[$0])}.joined())
},nil)
IOHIDDeviceScheduleWithRunLoop(device,CFRunLoopGetCurrent(),CFRunLoopMode.defaultMode.rawValue)
CFRunLoopRunInMode(.defaultMode,5,false)
IOHIDDeviceUnscheduleFromRunLoop(device,CFRunLoopGetCurrent(),CFRunLoopMode.defaultMode.rawValue)
IOHIDDeviceClose(device,0)
bytes.deallocate()
print("CALLBACKS",rows.count)
for row in rows.prefix(30){print(row)}
