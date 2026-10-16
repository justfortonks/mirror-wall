import XCTest
@testable import MirrorCore

final class BezelPresetTests: XCTestCase {
    func testModelAliasesAndManualOverride() {
        XCTAssertEqual(BezelPreset.resolve(model: "Zebra Technologies HC50")?.id, "zebra-hc50")
        XCTAssertEqual(BezelPreset.resolve(model: "Zebra TC53e")?.style, .rugged)
        XCTAssertEqual(BezelPreset.resolve(model: "iPad15,8")?.id, "ipad-11-a16")
        XCTAssertEqual(BezelPreset.resolve(selection: "zebra-hc50", model: "unknown")?.style, .healthcare)
        XCTAssertNil(BezelPreset.resolve(selection: "removed-preset", model: "unknown"))
        XCTAssertEqual(BezelPreset.resolve(selection: "removed-preset", model: "iPad15,7")?.style, .tablet)
    }

    func testAllPresetsPreserveVideoAspectInBothOrientations() {
        XCTAssertEqual(Set(BezelPreset.catalog.map(\.id)).count, BezelPreset.catalog.count)
        for preset in BezelPreset.catalog {
            for (width, height) in [(1080.0, 2400.0), (2400.0, 1080.0), (1640.0, 2360.0), (2360.0, 1640.0)] {
                let g = BezelGeometry(style: preset.style, pictureWidth: width, pictureHeight: height, portraitAspect: preset.portraitAspect)
                let outer = g.outerSize(pictureWidth: width, pictureHeight: height)
                XCTAssertEqual(outer.width / outer.height, width > height ? 1 / preset.portraitAspect : preset.portraitAspect, accuracy: 0.000001, preset.id)
                XCTAssertEqual((outer.width - g.left - g.right) / (outer.height - g.top - g.bottom), width / height, accuracy: 0.000001, preset.id)
            }
        }
    }

    func testSelectionSurvivesConfigurationRoundTripAndOldConfigsDecode() throws {
        var config = SlotConfig(id: 1, name: "Test")
        config.bezelModel = "ipad-11-a16"
        config.displayAlias = "Tablet demo"
        let decoded = try JSONDecoder().decode(SlotConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.bezelModel, config.bezelModel)
        XCTAssertEqual(decoded.displayAlias, config.displayAlias)
        let old = try JSONDecoder().decode(SlotConfig.self, from: Data(#"{"id":1,"name":"Old"}"#.utf8))
        XCTAssertNil(old.bezelModel)
        XCTAssertNil(old.displayAlias)
    }
}
