import Foundation
import Testing
@testable import CBNKit

/// Locates the repo checkout from this source file's compile-time path, so
/// tests can read canonical files like Samples/ without duplicating them as
/// bundle resources. Valid because this package only ever builds from its
/// own repo checkout.
private var repoRoot: URL {
    URL(fileURLWithPath: #filePath)         // .../Tests/CBNKitTests/CBNTemplateTests.swift
        .deletingLastPathComponent()        // .../Tests/CBNKitTests
        .deletingLastPathComponent()        // .../Tests
        .deletingLastPathComponent()        // repo root
}

private func loadSailboat() throws -> CBNTemplate {
    let url = repoRoot
        .appendingPathComponent("Samples/LittleSailboat/template.json")
    return try JSONDecoder().decode(CBNTemplate.self, from: Data(contentsOf: url))
}

@Test func sailboatSampleDecodes() throws {
    let template = try loadSailboat()
    #expect(template.schemaVersion == 1)
    #expect(template.title == "Little Sailboat")
    #expect(template.palette.count == 5)
    #expect(template.regions.count == 6)
}

@Test func sailboatSampleIsValid() throws {
    let template = try loadSailboat()
    #expect(template.validate().isEmpty)
}

@Test func sailboatLabelPointsSitInsideRegionBounds() throws {
    // Cheap bounding-box check until real point-in-polygon lands with the
    // M1 geometry work; catches gross hand-authoring mistakes today.
    let template = try loadSailboat()
    for region in template.regions {
        let xs = region.path.map(\.x)
        let ys = region.path.map(\.y)
        let label = region.labelPoint
        #expect(label.x >= xs.min()! && label.x <= xs.max()!, "label outside \(region.id) x-bounds")
        #expect(label.y >= ys.min()! && label.y <= ys.max()!, "label outside \(region.id) y-bounds")
    }
}

@Test func pointRoundTripsThroughCompactArrayEncoding() throws {
    let original = CBNPoint(x: 12.5, y: 900)
    let data = try JSONEncoder().encode(original)
    #expect(String(data: data, encoding: .utf8) == "[12.5,900]")
    let decoded = try JSONDecoder().decode(CBNPoint.self, from: data)
    #expect(decoded == original)
}

@Test func pointRejectsWrongArityArrays() {
    for malformed in ["[1]", "[1,2,3]"] {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CBNPoint.self, from: Data(malformed.utf8))
        }
    }
}

@Test func hexColorsParse() {
    let color = CBNColor(hex: "#3E6E8E")
    #expect(color != nil)
    #expect(abs(color!.red - Double(0x3E) / 255) < 0.0001)
    #expect(CBNColor(hex: "3e6e8e") != nil)   // bare lowercase is fine
    #expect(CBNColor(hex: "#12345") == nil)   // wrong length
    #expect(CBNColor(hex: "#GGGGGG") == nil)  // not hex
}

@Test func validatorCatchesStructuralProblems() {
    let broken = CBNTemplate(
        title: "Broken",
        size: CBNSize(width: 100, height: 100),
        palette: [
            CBNPaletteEntry(number: 1, name: "Dup", hex: "#FF0000"),
            CBNPaletteEntry(number: 1, name: "Dup again", hex: "not-a-color"),
        ],
        regions: [
            CBNRegion(
                id: "bad",
                colorNumber: 9,
                path: [CBNPoint(x: 0, y: 0), CBNPoint(x: 1, y: 1)],
                labelPoint: CBNPoint(x: 0, y: 0)
            )
        ]
    )
    let issues = broken.validate()
    #expect(issues.contains(.duplicatePaletteNumber(1)))
    #expect(issues.contains(.malformedPaletteHex(number: 1, hex: "not-a-color")))
    #expect(issues.contains(.unknownColorNumber(regionID: "bad", colorNumber: 9)))
    #expect(issues.contains(.degeneratePath(regionID: "bad", pointCount: 2)))
}
