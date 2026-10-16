import XCTest
import AVFoundation
import MirrorCore
@testable import MirrorWall

final class RecordingTests: XCTestCase {
    func testSameNamedRecordersAndRotationFinishPlayableFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = SlotRecorder(folder: folder, baseName: "Demo phone")
        let second = SlotRecorder(folder: folder, baseName: "Demo phone")
        func buffer(_ width: Int, _ height: Int) throws -> CVPixelBuffer {
            var output: CVPixelBuffer?
            let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &output)
            XCTAssertEqual(status, kCVReturnSuccess)
            let image = try XCTUnwrap(output)
            CVPixelBufferLockBaseAddress(image, [])
            memset(CVPixelBufferGetBaseAddress(image), 128, CVPixelBufferGetBytesPerRow(image) * height)
            CVPixelBufferUnlockBaseAddress(image, [])
            return image
        }
        func append(_ recorder: SlotRecorder, _ image: CVPixelBuffer) {
            recorder.append(image: image, rtpTimestamp: nil, arrival: Double(DispatchTime.now().uptimeNanoseconds) / 1e9)
        }
        let portrait = try buffer(64, 128)
        append(first, portrait)
        append(second, portrait)
        XCTAssertNotEqual(try XCTUnwrap(first.currentURL), try XCTUnwrap(second.currentURL))
        append(first, try buffer(128, 64)) // previous file now finalizing in the background
        first.endFile()
        second.endFile()
        await SlotRecorder.finishPendingFiles()
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 3)
        for file in files {
            let playable = try await AVURLAsset(url: file).load(.isPlayable)
            XCTAssertTrue(playable, file.lastPathComponent)
        }
    }
}
