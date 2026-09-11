// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import ScreenCaptureKit
import CoreMedia
final class Output: NSObject, SCStreamOutput, SCStreamDelegate {
 var count = 0
 func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
  count += 1
  if count <= 3 { print("sample \(count), valid \(sampleBuffer.isValid), image \(sampleBuffer.imageBuffer != nil)") }
 }
 func stream(_ stream: SCStream, didStopWithError error: Error) { print("STOP ERROR: \(error)") }
}
let app = NSApplication.shared
let output = Output()
Task { @MainActor in
 do {
  let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
  let display = content.displays.first { CGDisplayIsBuiltin($0.displayID) != 0 }!
  let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
  let config = SCStreamConfiguration()
  config.width = display.width; config.height = display.height
  config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
  let stream = SCStream(filter: filter, configuration: config, delegate: output)
  try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .main)
  try await stream.startCapture()
  print("started display \(display.displayID), \(display.width)x\(display.height)")
  try await Task.sleep(for: .seconds(3))
  try await stream.stopCapture()
  print("TOTAL \(output.count)")
 } catch { print("ERROR: \(error)") }
 exit(0)
}
app.run()
