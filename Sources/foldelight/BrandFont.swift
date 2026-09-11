// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import CoreText
import SwiftUI

/// IBM Plex Sans is bundled under the SIL Open Font License 1.1.
enum BrandFont {
    private static let registration: Void = {
        let resourceBundle = Bundle.main.url(forResource: "foldelight_foldelight", withExtension: "bundle")
            .flatMap(Bundle.init(url:)) ?? Bundle.module
        for face in ["Regular", "Medium", "SemiBold"] {
            guard let url = resourceBundle.url(forResource: "IBMPlexSans-\(face)",
                                               withExtension: "ttf", subdirectory: "Fonts") else {
                assertionFailure("Missing bundled IBM Plex Sans \(face) font")
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    static func register() { _ = registration }

    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        register()
        // Use the actual PostScript names in the bundled font name tables.
        let name: String
        switch weight {
        case .medium: name = "IBMPlexSans-Medm"
        case .semibold, .bold, .heavy, .black: name = "IBMPlexSans-SmBld"
        default: name = "IBMPlexSans"
        }
        return .custom(name, fixedSize: size)
    }
}
