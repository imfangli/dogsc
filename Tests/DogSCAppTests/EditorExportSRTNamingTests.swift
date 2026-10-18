import Foundation
import RecorderCore
import XCTest
@testable import DogSCApp

final class EditorExportSRTNamingTests: XCTestCase {
    func testCompanionReservesSameBaseNameWithoutOverwritingExistingSRT() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let existing = folder.appendingPathComponent("作品.srt")
        try "已有字幕".write(to: existing, atomically: true, encoding: .utf8)
        let mediaOnly = try EditorExportRequestBuilder.makeOutputURL(
            in: folder, baseName: "作品", outputKind: .video
        )
        XCTAssertEqual(mediaOnly.lastPathComponent, "作品.mp4")
        let withSRT = try EditorExportRequestBuilder.makeOutputURL(
            in: folder, baseName: "作品", outputKind: .video, includesSRT: true
        )
        XCTAssertEqual(withSRT.lastPathComponent, "作品-2.mp4")
        XCTAssertEqual(EditorSubtitleExport.outputURL(for: withSRT).lastPathComponent, "作品-2.srt")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "已有字幕")
    }

    func testAudioAndVideoBothSkipOccupiedMediaAndSubtitleNames() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for file in ["作品.mp4", "作品.m4a", "作品-2.srt"] {
            try Data().write(to: folder.appendingPathComponent(file))
        }
        for kind in ExportOutputKind.allCases {
            let output = try EditorExportRequestBuilder.makeOutputURL(
                in: folder, baseName: "作品", outputKind: kind, includesSRT: true
            )
            XCTAssertEqual(output.lastPathComponent, "作品-3.\(kind.fileExtension)")
        }
    }

    func testDefaultFilenameKeepsFrameRateAndSharedSubtitleName() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("作品-60fps.srt"))
        let output = try EditorExportRequestBuilder.makeDefaultOutputURL(
            for: RecorderProject(title: "作品"), preferredProjectName: "作品",
            includesSRT: true, directoryURL: folder
        )
        XCTAssertEqual(output.lastPathComponent, "作品-60fps-2.mp4")
        XCTAssertEqual(EditorSubtitleExport.outputURL(for: output).lastPathComponent, "作品-60fps-2.srt")
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DogSC-SRT-Naming-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
