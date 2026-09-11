// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import XCTest
@testable import foldelight

final class AssetTests: XCTestCase {
    func testBundledFontsRegisterWithoutFallback() throws {
        BrandFont.register()
        for name in ["IBMPlexSans", "IBMPlexSans-Medm", "IBMPlexSans-SmBld"] {
            let font = try XCTUnwrap(NSFont(name: name, size: 13))
            XCTAssertEqual(font.fontName, name)
        }
    }
    func testMenuIconIsAccessibleTemplateWithDrawableContent() throws {
        let icon = FoldingIcon.menuBarImage()
        XCTAssertTrue(icon.isTemplate)
        XCTAssertEqual(icon.accessibilityDescription, "foldelight")
        XCTAssertEqual(icon.size, NSSize(width: 18, height: 18))
        XCTAssertNotNil(icon.tiffRepresentation)
    }
}
