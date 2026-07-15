import Foundation
import Testing
@testable import CBNKit

// MARK: - Tiny synthetic raster (local copy of ImportPipelineTests' private
// helper — that one is private to its own file, so scenes built through the
// real pipeline here need their own copy).

private func raster(_ rows: [String], colors: [Character: (UInt8, UInt8, UInt8)]) -> RasterImage {
    let height = rows.count
    let width = rows[0].count
    var rgba = [UInt8]()
    rgba.reserveCapacity(width * height * 4)
    for row in rows {
        for code in row {
            let (r, g, b) = colors[code]!
            rgba.append(contentsOf: [r, g, b, 255])
        }
    }
    return RasterImage(width: width, height: height, rgba: rgba)
}

// MARK: - Hit testing

/// The eye scene from ImportPipelineTests's `attachedPupilSurvivesRendering`:
/// a ring+spur+pupil dark region with one hole (the eye white), imported
/// through the real pipeline so hit-testing exercises actual traced,
/// simplified, even-odd polygons — not hand-authored ones.
private func eyeSceneTemplate() -> CBNTemplate {
    let image = raster(
        ["wwwwwwwwwwwwwwww",
         "wkkkkkkkkkkkkkkw",
         "wkrrrrrrkrrrrrkw",
         "wkrrrrrrkrrrrrkw",
         "wkrrrrrkkkrrrrkw",
         "wkrrrrrkkkrrrrkw",
         "wkrrrrrrrrrrrrkw",
         "wkkkkkkkkkkkkkkw",
         "wwwwwwwwwwwwwwww"],
        colors: [
            "w": (250, 250, 250),
            "k": (20, 20, 20),
            "r": (200, 40, 40),
        ]
    )
    return ImportPipeline.importTemplate(
        from: image,
        title: "eye",
        parameters: ImportParameters(colorCount: 8, minRegionMM: 2, detail: 1.0)
    )
}

/// The concentric-squares scene from `concentricRegionsGetDistinctLabelPoints`
/// — three nested rings, a good check that hit testing picks the topmost
/// (innermost-drawn) region rather than being fooled by the outer rings'
/// holes.
private func concentricSquaresTemplate() -> CBNTemplate {
    let image = raster(
        ["aaaaaaa",
         "abbbbba",
         "abcccba",
         "abcccba",
         "abcccba",
         "abbbbba",
         "aaaaaaa"],
        colors: [
            "a": (200, 40, 40),
            "b": (40, 160, 60),
            "c": (40, 80, 200),
        ]
    )
    return ImportPipeline.importTemplate(
        from: image,
        title: "rings",
        parameters: ImportParameters(colorCount: 8, minRegionMM: 2, detail: 0.9)
    )
}

private func region(ofHex hex: String, in template: CBNTemplate) -> CBNRegion {
    let number = template.palette.first { $0.hex == hex }!.number
    return template.regions.first { $0.colorNumber == number }!
}

@Test func hitTestPupilCenterFindsDarkRegion() {
    let template = eyeSceneTemplate()
    let hit = template.region(at: CBNPoint(x: 8, y: 4.5))
    #expect(hit?.id == region(ofHex: "#141414", in: template).id)
}

@Test func hitTestEyeWhiteFindsRedRegion() {
    let template = eyeSceneTemplate()
    let hit = template.region(at: CBNPoint(x: 4, y: 4.5))
    #expect(hit?.id == region(ofHex: "#C82828", in: template).id)
}

@Test func hitTestBackgroundCornerFindsWhiteRegion() {
    let template = eyeSceneTemplate()
    let hit = template.region(at: CBNPoint(x: 0.4, y: 0.4))
    #expect(hit?.id == region(ofHex: "#FAFAFA", in: template).id)
}

@Test func hitTestOutsideCanvasFindsNothing() {
    let template = eyeSceneTemplate()
    #expect(template.region(at: CBNPoint(x: -5, y: -5)) == nil)
}

@Test func hitTestConcentricSquaresDeadCenterFindsInnermostRegion() {
    let template = concentricSquaresTemplate()
    let hit = template.region(at: CBNPoint(x: 3.5, y: 3.5))
    #expect(hit?.id == region(ofHex: "#2850C8", in: template).id)
}

@Test func hitTestConcentricSquaresMiddleBandFindsMiddleRegion() {
    let template = concentricSquaresTemplate()
    let hit = template.region(at: CBNPoint(x: 1.5, y: 1.5))
    #expect(hit?.id == region(ofHex: "#28A03C", in: template).id)
}

// MARK: - CBNAttempt

/// A minimal two-region template, hand-authored (no pipeline needed) —
/// `CBNAttempt.isComplete` only cares about region ids.
private func twoRegionTemplate() -> CBNTemplate {
    CBNTemplate(
        title: "Two Regions",
        size: CBNSize(width: 10, height: 10),
        palette: [CBNPaletteEntry(number: 1, name: "Red", hex: "#FF0000")],
        regions: [
            CBNRegion(
                id: "r0", colorNumber: 1,
                path: [CBNPoint(x: 0, y: 0), CBNPoint(x: 5, y: 0), CBNPoint(x: 5, y: 5), CBNPoint(x: 0, y: 5)],
                labelPoint: CBNPoint(x: 2, y: 2)
            ),
            CBNRegion(
                id: "r1", colorNumber: 1,
                path: [CBNPoint(x: 5, y: 5), CBNPoint(x: 10, y: 5), CBNPoint(x: 10, y: 10), CBNPoint(x: 5, y: 10)],
                labelPoint: CBNPoint(x: 7, y: 7)
            ),
        ]
    )
}

@Test func attemptFillAppendsInOrder() {
    var attempt = CBNAttempt()
    attempt.fill("r0")
    attempt.fill("r1")
    #expect(attempt.filledRegionIDs == ["r0", "r1"])
}

@Test func attemptDoubleFillOfSameIDIsANoOp() {
    var attempt = CBNAttempt()
    attempt.fill("r0")
    let afterFirstFill = attempt.updatedAt
    attempt.fill("r0")
    #expect(attempt.filledRegionIDs == ["r0"])
    #expect(attempt.updatedAt == afterFirstFill)
}

@Test func attemptUndoLastFillRemovesOnlyTheLast() {
    var attempt = CBNAttempt()
    attempt.fill("r0")
    attempt.fill("r1")
    attempt.undoLastFill()
    #expect(attempt.filledRegionIDs == ["r0"])
}

@Test func attemptUndoLastFillOnEmptyAttemptIsANoOp() {
    var attempt = CBNAttempt()
    attempt.undoLastFill()
    #expect(attempt.filledRegionIDs.isEmpty)
}

@Test func attemptIsFilledReflectsFillState() {
    var attempt = CBNAttempt()
    #expect(!attempt.isFilled("r0"))
    attempt.fill("r0")
    #expect(attempt.isFilled("r0"))
    #expect(!attempt.isFilled("r1"))
}

@Test func attemptIsCompleteFlipsExactlyWhenEveryRegionIsFilled() {
    let template = twoRegionTemplate()
    var attempt = CBNAttempt()
    #expect(!attempt.isComplete(for: template))
    attempt.fill("r0")
    #expect(!attempt.isComplete(for: template))
    attempt.fill("r1")
    #expect(attempt.isComplete(for: template))
}

@Test func attemptFillAndUndoBumpUpdatedAt() {
    var attempt = CBNAttempt()
    let created = attempt.updatedAt

    attempt.fill("r0")
    #expect(attempt.updatedAt > created)
    let afterFill = attempt.updatedAt

    attempt.undoLastFill()
    #expect(attempt.updatedAt > afterFill)
}

// MARK: - CBNLibrary

/// A fresh, uniquely-named temp directory per call — tests never share
/// library state and always clean up after themselves.
private func makeTempLibrary() -> (library: CBNLibrary, root: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CBNLibraryTests-\(UUID().uuidString)", isDirectory: true)
    return (CBNLibrary(rootURL: root), root)
}

private func sampleTemplate(title: String) -> CBNTemplate {
    CBNTemplate(
        title: title,
        size: CBNSize(width: 4, height: 4),
        palette: [CBNPaletteEntry(number: 1, name: "Blue", hex: "#0000FF")],
        regions: [
            CBNRegion(
                id: "r0", colorNumber: 1,
                path: [CBNPoint(x: 0, y: 0), CBNPoint(x: 4, y: 0), CBNPoint(x: 4, y: 4), CBNPoint(x: 0, y: 4)],
                labelPoint: CBNPoint(x: 2, y: 2)
            )
        ]
    )
}

@Test func libraryAddAndItemsRoundTripsTemplateContent() throws {
    let (library, root) = makeTempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }

    let template = sampleTemplate(title: "Roundtrip")
    let added = try library.add(template)

    let items = try library.items()
    #expect(items.count == 1)
    #expect(items[0].id == added.id)
    #expect(items[0].template == template)
}

@Test func libraryItemsOrdersNewestFirst() throws {
    let (library, root) = makeTempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }

    // Explicit, seconds-apart addedAt via the internal test hook — `.iso8601`
    // is whole-second, so two back-to-back public `add()` calls could
    // otherwise land in the same encoded second; real "distinct addedAt"
    // gaps in the app come from separate import sessions, not tight loops.
    let now = Date()
    let older = try library.addItem(sampleTemplate(title: "Older"), addedAt: now)
    let newer = try library.addItem(sampleTemplate(title: "Newer"), addedAt: now.addingTimeInterval(5))

    let items = try library.items()
    #expect(items.map(\.id) == [newer.id, older.id])
}

@Test func librarySaveAttemptAndLatestAttemptRoundTrip() throws {
    let (library, root) = makeTempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }

    let item = try library.add(sampleTemplate(title: "Colorable"))
    // `add` already seeds one empty attempt. `fill` bumps `updatedAt` to
    // "now" itself, so set the comfortably-later timestamp (real play
    // sessions are seconds to minutes apart, not sub-millisecond) AFTER
    // filling — otherwise `fill` would clobber it right back to "now" and
    // reintroduce the exact race this is trying to avoid.
    var attempt = CBNAttempt()
    attempt.fill("r0")
    attempt.updatedAt = Date().addingTimeInterval(60)
    try library.saveAttempt(attempt, in: item.id)

    // Not a bit-exact `==`: `.iso8601` is whole-second, so a round trip
    // through disk can shift `updatedAt` by a fraction of a second — that's
    // expected lossiness, not a bug. Content and near-enough timing are
    // what actually matter here.
    let latest = try library.latestAttempt(in: item.id)
    #expect(latest?.id == attempt.id)
    #expect(latest?.filledRegionIDs == attempt.filledRegionIDs)
    #expect(abs((latest?.updatedAt ?? .distantPast).timeIntervalSince(attempt.updatedAt)) < 1)
}

@Test func librarySeedIfEmptySeedsOnceThenBecomesANoOp() throws {
    let (library, root) = makeTempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }

    let first = sampleTemplate(title: "First")
    let second = sampleTemplate(title: "Second")

    let didSeed = try library.seedIfEmpty(with: [first, second])
    #expect(didSeed)
    let seededItems = try library.items()
    #expect(seededItems.count == 2)
    // Documented seeding contract: the FIRST template in the input array
    // ends up newest, i.e. at the front of the Studio grid.
    #expect(seededItems.first?.template.title == "First")

    let didSeedAgain = try library.seedIfEmpty(with: [first, second])
    #expect(!didSeedAgain)
    let itemsAfter = try library.items()
    #expect(itemsAfter.count == 2)
}

@Test func libraryItemsSkipsGarbageSubdirectoryWithoutThrowing() throws {
    let (library, root) = makeTempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try library.add(sampleTemplate(title: "Real"))

    let garbageDirectory = root.appendingPathComponent("not-a-real-item", isDirectory: true)
    try FileManager.default.createDirectory(at: garbageDirectory, withIntermediateDirectories: true)
    try Data("not valid json".utf8).write(to: garbageDirectory.appendingPathComponent("template.json"))

    let items = try library.items()
    #expect(items.count == 1)
    #expect(items[0].template.title == "Real")
}
