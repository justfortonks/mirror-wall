import XCTest
import AppKit
import SwiftUI
import MirrorCore
@testable import MirrorWall

final class VisualReviewTests: XCTestCase {
    /// Optional offscreen inspection, without launching a second receiver or touching live devices.
    @MainActor func testRenderReviewArtifacts() throws {
        guard let path = ProcessInfo.processInfo.environment["MIRRORWALL_REVIEW_RENDERS"] else {
            throw XCTSkip("Set MIRRORWALL_REVIEW_RENDERS to export offscreen UI previews")
        }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        func save<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String) throws {
            let host = NSHostingView(rootView: view.frame(width: width, height: height))
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: folder.appendingPathComponent(name + ".png"))
        }
        let presets = ["iphone-12", "iphone-se-3rd-generation", "zebra-hc50", "zebra-tc53e", "ipad-11-a16"]
            .compactMap { id in BezelPreset.catalog.first { $0.id == id } }
        for landscape in [false, true] {
            let row = HStack(alignment: .top, spacing: 20) {
                ForEach(presets) { preset in
                    let width: CGFloat = preset.style == .tablet ? 1640 : 1080
                    let height: CGFloat = preset.style == .tablet ? 2360 : preset.style == .homeButton ? 1920 : 2160
                    let picture = CGSize(width: landscape ? height : width, height: landscape ? width : height)
                    VStack(spacing: 12) {
                        Text(preset.title).font(.system(size: 14)).foregroundStyle(.white)
                        PhoneBezel(geometry: BezelGeometry(style: preset.style, pictureWidth: picture.width, pictureHeight: picture.height, portraitAspect: preset.portraitAspect), picture: picture) {
                            ZStack {
                                Color(red: 0.12, green: 0.4, blue: 0.6)
                                VStack { Text("Demo preview"); Image(systemName: "checkmark.circle").font(.largeTitle) }.foregroundStyle(.white)
                            }
                        }
                    }.frame(width: 210, height: 470)
                }
            }.padding(20).background(Brand.stage)
            try save(row, width: 1190, height: 510, name: landscape ? "bezels-landscape" : "bezels-portrait")
        }
        let store = SlotStore()
        let phones = (1...8).map { Slot(config: SlotConfig(id: $0, name: "Long demo device name \($0)")) }
        try save(StageControls(store: store, phones: phones, recording: false), width: 320, height: 48, name: "controls-320")
        try save(StageControls(store: store, phones: Array(phones.prefix(3)), recording: false), width: 1280, height: 48, name: "controls-1280")
        let demo = phones[0]
        demo.apply(.clientConnecting(name: "Zebra nurse workflow", model: "HC50", deviceID: "preview"))
        let tile = SlotTile(slot: demo, isFocused: false, maxVideoHeight: 540, toggleFocus: {})
            .environmentObject(store).padding(24).background(Brand.surface)
            .foregroundStyle(Brand.ink)
        try save(tile, width: 360, height: 660, name: "wall")
    }
}
