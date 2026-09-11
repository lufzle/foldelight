// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import CoreVideo
import CoreGraphics
import Darwin
import Foundation
import ScreenCaptureKit

struct CapturedFrame {
    let buffer: CVPixelBuffer
    let displayTime: Double?
    var damage: [CGRect]?
    let generation: UInt64?

    init(buffer: CVPixelBuffer, displayTime: Double?, damage: [CGRect]?, generation: UInt64? = nil) {
        self.buffer = buffer; self.displayTime = displayTime; self.damage = damage; self.generation = generation
    }
}

struct CaptureMetadata {
    let displayTime: Double?
    let damage: [CGRect]?

    static func decode(_ info: [SCStreamFrameInfo: Any]) -> CaptureMetadata {
        let displayTime: Double?
        if let value = info[.displayTime] as? NSNumber, value.doubleValue.isFinite,
           value.doubleValue >= 0, value.decimalValue == Decimal(value.uint64Value) {
            displayTime = HostClock.seconds(ticks: value.uint64Value)
        } else { displayTime = nil }
        let damage: [CGRect]?
        if let values = info[.dirtyRects] as? [NSValue] {
            let rectType = String(cString: NSValue(rect: .zero).objCType)
            if values.allSatisfy({ String(cString: $0.objCType) == rectType }) {
                damage = FrameDamage.merging([], values.map(\.rectValue))
            } else { damage = nil }
        } else { damage = nil }
        return CaptureMetadata(displayTime: displayTime, damage: damage)
    }
}

enum FrameDamage {
    // Unknown damage always requires a full rebuild. A single conservative
    // rectangle bounds storage even when many captures replace a pending frame.
    static func merging(_ previous: [CGRect]?, _ incoming: [CGRect]?) -> [CGRect]? {
        guard let previous, let incoming else { return nil }
        var bounds = CGRect.null
        for rect in previous + incoming {
            guard rect.origin.x.isFinite, rect.origin.y.isFinite,
                  rect.width.isFinite, rect.height.isFinite,
                  rect.size.width >= 0, rect.size.height >= 0,
                  rect.maxX.isFinite, rect.maxY.isFinite else { return nil }
            if !rect.isEmpty { bounds = bounds.union(rect) }
        }
        guard bounds.isNull || (bounds.origin.x.isFinite && bounds.origin.y.isFinite
            && bounds.width.isFinite && bounds.height.isFinite) else { return nil }
        return bounds.isNull ? [] : [bounds]
    }
}

enum HostClock {
    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()
    static func seconds(ticks: UInt64) -> Double { Double(ticks) * secondsPerTick }
}
