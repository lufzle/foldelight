// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Report 7 is a private Apple format. Restrict it to the actual device and
/// element descriptor verified by the paired hardware trace, not its name.
enum PreciseLidCapability {
    static func supports(vendor: Int, product: Int, report: Int, usagePage: Int,
                         usage: Int, minimum: Int, maximum: Int, exponent: Int) -> Bool {
        vendor == 0x05ac && product == 0x8104 && report == 7 && usagePage == 0x20
            && usage == 0x0545 && minimum == 0 && maximum == 36000 && exponent == 14
    }
}

/// Validates the private fine report against bracketing coarse reads at open.
/// A failed fine read falls back immediately and disables fine reads for this
/// connection. A new connection rechecks capability and agreement.
struct LidReportSelection {
    private(set) var usesPrecision = false

    mutating func open(supportsPrecision: Bool, read: (Int) -> Double?) -> Double? {
        usesPrecision = false
        guard let before = read(1) else { return nil }
        guard supportsPrecision, let fine = read(7), let after = read(1) else { return before }
        guard fine >= min(before, after) - 0.51, fine <= max(before, after) + 0.51 else { return after }
        usesPrecision = true
        return fine
    }

    mutating func next(read: (Int) -> Double?) -> Double? {
        if usesPrecision {
            if let fine = read(7) { return fine }
            usesPrecision = false
        }
        return read(1)
    }
}
