#if DEBUG
import CBNKit
import Foundation

/// A tiny two-region template for SwiftUI previews only. Deliberately
/// inline rather than decoded from a bundled starter — the preview process
/// doesn't always resolve app-bundle resources the same way a running app
/// does, and previews should never fail because of that.
extension CBNTemplate {
    static let previewSample = CBNTemplate(
        title: "Preview Sample",
        size: CBNSize(width: 400, height: 300),
        palette: [
            CBNPaletteEntry(number: 1, name: "Sky", hex: "#BFE3F0"),
            CBNPaletteEntry(number: 2, name: "Grass", hex: "#9FD3A6"),
        ],
        regions: [
            CBNRegion(
                id: "sky",
                colorNumber: 1,
                path: [
                    CBNPoint(x: 0, y: 0), CBNPoint(x: 400, y: 0),
                    CBNPoint(x: 400, y: 180), CBNPoint(x: 0, y: 180),
                ],
                labelPoint: CBNPoint(x: 200, y: 90)
            ),
            CBNRegion(
                id: "grass",
                colorNumber: 2,
                path: [
                    CBNPoint(x: 0, y: 180), CBNPoint(x: 400, y: 180),
                    CBNPoint(x: 400, y: 300), CBNPoint(x: 0, y: 300),
                ],
                labelPoint: CBNPoint(x: 200, y: 240)
            ),
        ]
    )
}

/// A throwaway library in a fresh temp directory, seeded with `templates`,
/// for use only by `#Preview` blocks.
func previewLibrary(seeding templates: [CBNTemplate]) -> CBNLibrary {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("cbn-preview-\(UUID().uuidString)", isDirectory: true)
    let library = CBNLibrary(rootURL: root)
    _ = try? library.seedIfEmpty(with: templates)
    return library
}
#endif
