import SwiftUI
import XCTest
@testable import OpenUsage

/// Account cards keep their family's recognizable ring color without collapsing several account
/// slices into the four-color fallback reserved for previously unknown provider brands.
final class TotalSpendPaletteTests: XCTestCase {
    func testBareProviderBrandColorsRemainUnchanged() {
        XCTAssertEqual(
            TotalSpendPalette.color(for: "claude"),
            Color(red: Double(0xDE) / 255, green: Double(0x73) / 255, blue: Double(0x56) / 255)
        )
        XCTAssertEqual(
            TotalSpendPalette.color(for: "codex"),
            Color(red: Double(0x10) / 255, green: Double(0xA3) / 255, blue: Double(0x7F) / 255)
        )
        XCTAssertNil(TotalSpendPalette.accountComponents(for: "claude"))
        XCTAssertNil(TotalSpendPalette.accountComponents(for: "codex"))
    }

    func testAccountColorIsStableAndMatchesItsRemoteOnlyAlias() throws {
        let local = try XCTUnwrap(TotalSpendPalette.accountComponents(for: "claude@ab12cd34"))

        XCTAssertEqual(local, TotalSpendPalette.accountComponents(for: "claude@ab12cd34"))
        XCTAssertEqual(local, TotalSpendPalette.accountComponents(for: "claude@AB12CD34"))
        XCTAssertEqual(local, TotalSpendPalette.accountComponents(for: "claude@peer-ab12cd34"))
        XCTAssertEqual(
            TotalSpendPalette.color(for: "claude@ab12cd34"),
            TotalSpendPalette.color(for: "claude@peer-ab12cd34")
        )
    }

    func testSiblingAccountsThatCollidedInTheLegacyFallbackGetDistinctColors() throws {
        // All three ids selected the same four-color fallback entry before account-aware coloring.
        let first = try XCTUnwrap(TotalSpendPalette.accountComponents(for: "claude@11111111"))
        let second = try XCTUnwrap(TotalSpendPalette.accountComponents(for: "claude@22222222"))
        let third = try XCTUnwrap(TotalSpendPalette.accountComponents(for: "claude@33333333"))

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, third)
        XCTAssertNotEqual(second, third)
    }

    func testAccountShadesStayNearTheirFamilyBrandAndRemainLegible() throws {
        let claude = try XCTUnwrap(TotalSpendPalette.accountComponents(for: "claude@ab12cd34"))
        let codex = try XCTUnwrap(TotalSpendPalette.accountComponents(for: "codex@ab12cd34"))

        XCTAssertTrue(claude.hue <= 0.15 || claude.hue >= 0.90, "Claude accounts stay in the warm terracotta family")
        XCTAssertGreaterThan(codex.hue, 0.33, "Codex accounts stay in the green/teal family")
        XCTAssertLessThan(codex.hue, 0.56, "Codex accounts stay in the green/teal family")
        for color in [claude, codex] {
            XCTAssertGreaterThanOrEqual(color.saturation, 0.50)
            XCTAssertGreaterThanOrEqual(color.brightness, 0.62)
            XCTAssertLessThanOrEqual(color.brightness, 0.94)
        }
    }

    func testUnknownProvidersRetainTheExistingFallbackPalette() {
        // The legacy 16-bit hash selects index 3 for this unknown provider id.
        XCTAssertEqual(
            TotalSpendPalette.color(for: "mystery-provider"),
            Color(red: Double(0xA2) / 255, green: Double(0x84) / 255, blue: Double(0x5E) / 255)
        )
        XCTAssertNil(TotalSpendPalette.accountComponents(for: "mystery-provider"))
        XCTAssertNil(TotalSpendPalette.accountComponents(for: "cursor@ab12cd34"))
    }
}
