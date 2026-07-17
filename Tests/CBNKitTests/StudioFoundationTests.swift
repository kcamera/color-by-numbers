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

@Test func attemptSetDrawingAssignsBlobAndBumpsUpdatedAt() {
    var attempt = CBNAttempt()
    let created = attempt.updatedAt
    let blob = Data([0x01, 0x02, 0x03])

    attempt.setDrawing(blob)
    #expect(attempt.drawingData == blob)
    #expect(attempt.updatedAt > created)

    let afterFirstSet = attempt.updatedAt
    attempt.setDrawing(nil)
    #expect(attempt.drawingData == nil)
    #expect(attempt.updatedAt > afterFirstSet)
}

/// A raw v1 attempt JSON — exactly what M2 wrote to real iPads, before
/// `drawingData` existed: id/createdAt/updatedAt/filledRegionIDs only,
/// ISO-8601 whole-second dates, sorted keys (matching `CBNLibrary`'s
/// encoder). Those devices' on-disk attempts must keep decoding forever;
/// this fixture is the regression guard for that promise.
private let v1AttemptJSON = """
{"createdAt":"2026-01-01T00:00:00Z","filledRegionIDs":["r0"],"id":"v1-attempt","updatedAt":"2026-01-01T00:00:05Z"}
"""

@Test func attemptDecodesV1JSONMissingDrawingDataAsNil() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let attempt = try decoder.decode(CBNAttempt.self, from: Data(v1AttemptJSON.utf8))

    #expect(attempt.id == "v1-attempt")
    #expect(attempt.filledRegionIDs == ["r0"])
    #expect(attempt.drawingData == nil)
}

// MARK: - CBNAttempt.actionLog (M3 interleaved undo)

/// The action strings are a persistence contract: "fill" and "stroke" are
/// already on real iPads from early M3, and "strokes:N" joins them for
/// boundary-assist's clipped gestures. All three must decode; the
/// single-sub-stroke case must keep ENCODING as the legacy "stroke" so
/// freehand-only attempts stay byte-identical.
@Test func attemptActionStringsRoundTripAllThreeSpellings() throws {
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(
        [CBNAttemptAction].self,
        from: Data(#"["fill","stroke","strokes:4","clipped:3"]"#.utf8)
    )
    #expect(decoded == [.fill, .strokes(1), .strokes(4), .clippedStrokes(3)])

    let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
    #expect(encoded == #"["fill","stroke","strokes:4","clipped:3"]"#)

    #expect(throws: DecodingError.self) {
        _ = try decoder.decode([CBNAttemptAction].self, from: Data(#"["strokes:0"]"#.utf8))
    }
    #expect(throws: DecodingError.self) {
        _ = try decoder.decode([CBNAttemptAction].self, from: Data(#"["scribble"]"#.utf8))
    }
}

/// A clipped gesture logs once with its sub-stroke count, and one undo
/// takes the WHOLE gesture back — the child made one gesture, undo removes
/// one gesture (the caller drops that many PKStrokes; the model just pops
/// the single log entry).
@Test func attemptMultiSubstrokeGestureLogsOnceAndUndoesOnce() {
    var attempt = CBNAttempt()
    attempt.fill("r0")
    attempt.recordStroke(Data([0x01]), substrokes: 3, clipped: true)
    #expect(attempt.effectiveActionLog == [.fill, .clippedStrokes(3)])
    #expect(attempt.effectiveActionLog.last?.substrokeCount == 3)
    #expect(attempt.effectiveActionLog.last?.isStrokeGesture == true)

    attempt.undoLastStroke(updatedDrawing: nil)
    #expect(attempt.effectiveActionLog == [.fill])
    #expect(attempt.drawingData == nil)
}

/// Same v1 fixture as above, missing `actionLog` entirely (it predates the
/// field just as much as `drawingData` does): decodes with a nil stored log,
/// and `effectiveActionLog` must reconstruct the only history a pre-log
/// attempt could have — one `.fill` per filled region, in order.
@Test func attemptDecodesV1JSONMissingActionLogAsNilWithReconstructedEffectiveLog() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let attempt = try decoder.decode(CBNAttempt.self, from: Data(v1AttemptJSON.utf8))

    #expect(attempt.actionLog == nil)
    #expect(attempt.effectiveActionLog == [.fill])
}

/// A brand-new attempt also starts with a nil stored log (materialized only
/// on first touch) but an empty effective one — no fills, no strokes, no
/// history yet.
@Test func attemptFreshEffectiveActionLogIsEmpty() {
    let attempt = CBNAttempt()
    #expect(attempt.actionLog == nil)
    #expect(attempt.effectiveActionLog.isEmpty)
}

/// The whole point of the log: fills and strokes interleaved must come back
/// out in the exact order they happened, not grouped by kind.
@Test func attemptInterleavedFillAndStrokeLogPreservesOrder() {
    var attempt = CBNAttempt()
    attempt.fill("r0")
    attempt.recordStroke(Data([0x01]))
    attempt.fill("r1")

    #expect(attempt.effectiveActionLog == [.fill, .stroke, .fill])
    #expect(attempt.filledRegionIDs == ["r0", "r1"])
    #expect(attempt.drawingData == Data([0x01]))
}

/// `undoLastFill` pops the log's trailing entry along with the region,
/// leaving the stroke in between untouched.
@Test func attemptUndoLastFillPopsTrailingLogEntry() {
    var attempt = CBNAttempt()
    attempt.fill("r0")
    attempt.recordStroke(Data([0x01]))
    attempt.fill("r1")

    attempt.undoLastFill()

    #expect(attempt.filledRegionIDs == ["r0"])
    #expect(attempt.effectiveActionLog == [.fill, .stroke])
}

/// `undoLastStroke` pops the log's trailing entry and installs the caller's
/// re-serialized drawing (here, `nil` — the caller removed the only stroke).
@Test func attemptUndoLastStrokePopsTrailingLogEntryAndAssignsDrawing() {
    var attempt = CBNAttempt()
    attempt.fill("r0")
    attempt.recordStroke(Data([0x01, 0x02]))

    attempt.undoLastStroke(updatedDrawing: nil)

    #expect(attempt.drawingData == nil)
    #expect(attempt.effectiveActionLog == [.fill])
}

/// `recordStroke` bumps `updatedAt` monotonically, mirroring `fill`.
@Test func attemptRecordStrokeBumpsUpdatedAt() {
    var attempt = CBNAttempt()
    let created = attempt.updatedAt
    attempt.recordStroke(Data([0xFF]))
    #expect(attempt.updatedAt > created)
}

/// `recordStroke` round-trips through `CBNLibrary` exactly like `setDrawing`
/// already does — the log is part of the same JSON blob, no separate path.
@Test func libraryRecordStrokeRoundTripsActionLogThroughSaveAttemptAndLatestAttempt() throws {
    let (library, root) = makeTempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }

    let item = try library.add(sampleTemplate(title: "Drawn With Log"))
    // Bump `updatedAt` comfortably past "now" AFTER the mutations that would
    // otherwise set it there themselves — same race `librarySaveAttemptAndLatestAttemptRoundTrip`
    // avoids: `add` also seeds an empty attempt at "now", and `.iso8601`'s
    // whole-second resolution can tie the two, leaving `latestAttempt`'s tie
    // -break to fall back to comparing UUIDs (a coin flip, not this test's
    // concern).
    var attempt = CBNAttempt()
    attempt.fill("r0")
    attempt.recordStroke(Data([0xDE, 0xAD, 0xBE, 0xEF]))
    attempt.updatedAt = Date().addingTimeInterval(60)
    try library.saveAttempt(attempt, in: item.id)

    let latest = try library.latestAttempt(in: item.id)
    #expect(latest?.drawingData == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    #expect(latest?.effectiveActionLog == [.fill, .stroke])
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

@Test func libraryDrawingDataRoundTripsThroughSaveAttemptAndLatestAttempt() throws {
    let (library, root) = makeTempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }

    let item = try library.add(sampleTemplate(title: "Drawn"))
    // Explicitly-later dates: `add` seeds an attempt in the same wall-clock
    // second, and a same-encoded-second tie would fall through latestAttempt's
    // deterministic-but-arbitrary final tie-break (lexicographic UUID) — a
    // coin flip per run. Same rationale as libraryAttemptsOrdersNewestFirst.
    let later = Date().addingTimeInterval(10)
    var attempt = CBNAttempt(createdAt: later, updatedAt: later)
    attempt.setDrawing(Data([0xDE, 0xAD, 0xBE, 0xEF]))
    try library.saveAttempt(attempt, in: item.id)

    let latest = try library.latestAttempt(in: item.id)
    #expect(latest?.drawingData == Data([0xDE, 0xAD, 0xBE, 0xEF]))
}

@Test func libraryAttemptsOrdersNewestFirstByCreatedAt() throws {
    let (library, root) = makeTempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }

    // `add` already seeds one empty attempt; explicit, seconds-apart
    // `createdAt`/`updatedAt` (rather than back-to-back `Date()` calls) is
    // what makes the ordering deterministic despite `.iso8601`'s
    // whole-second resolution — same rationale as `libraryItemsOrdersNewestFirst`.
    let item = try library.add(sampleTemplate(title: "Replayed"))
    let seeded = try library.latestAttempt(in: item.id)!

    let now = Date()
    let middle = CBNAttempt(id: "middle", createdAt: now, updatedAt: now)
    let newest = CBNAttempt(
        id: "newest",
        createdAt: now.addingTimeInterval(10),
        updatedAt: now.addingTimeInterval(10)
    )
    try library.saveAttempt(middle, in: item.id)
    try library.saveAttempt(newest, in: item.id)

    let attempts = try library.attempts(in: item.id)
    #expect(attempts.map(\.id) == [newest.id, middle.id, seeded.id])
}

@Test func libraryNewAttemptBecomesLatestAndKeepsPriorAttemptIntact() throws {
    let (library, root) = makeTempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }

    let item = try library.add(sampleTemplate(title: "Again"))
    var priorAttempt = try library.latestAttempt(in: item.id)!
    priorAttempt.fill("r0")
    try library.saveAttempt(priorAttempt, in: item.id)

    let fresh = try library.newAttempt(in: item.id)

    #expect(fresh.id != priorAttempt.id)
    #expect(fresh.filledRegionIDs.isEmpty)

    // `newAttempt` must win even when it lands in the same encoded
    // wall-clock second as the prior attempt's `updatedAt` — the whole
    // reason it bumps its own timestamp strictly past the prior one.
    let latest = try library.latestAttempt(in: item.id)
    #expect(latest?.id == fresh.id)

    // "Color it again" never deletes or overwrites — the prior attempt and
    // its fills must still be sitting on disk afterward.
    let all = try library.attempts(in: item.id)
    #expect(all.count == 2)
    let stillThere = all.first { $0.id == priorAttempt.id }
    #expect(stillThere?.filledRegionIDs == ["r0"])
}

/// Forces the same-second collision rather than hoping to dodge it: several
/// resets inside one wall-clock second must still produce strictly
/// increasing on-disk timestamps (via the synthetic +1s bump), so "latest"
/// never degrades to directory iteration order. Each attempt gets a fill
/// first — a pristine attempt would just be returned as-is.
@Test func libraryRapidNewAttemptsStayStrictlyOrderedOnDisk() throws {
    let (library, root) = makeTempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }

    let item = try library.add(sampleTemplate(title: "Rapid"))
    var first = try library.latestAttempt(in: item.id)!
    first.fill("r0")
    try library.saveAttempt(first, in: item.id)

    let second = try library.newAttempt(in: item.id)
    var secondFilled = second
    secondFilled.fill("r0")
    try library.saveAttempt(secondFilled, in: item.id)

    let third = try library.newAttempt(in: item.id)
    #expect(second.createdAt < third.createdAt)

    // Decoded-from-disk order must match, and the very last creation must
    // be the unambiguous latest.
    let all = try library.attempts(in: item.id)
    #expect(all.count == 3)
    #expect(all.map(\.id).first == third.id)
    #expect(zip(all, all.dropFirst()).allSatisfy { $0.createdAt > $1.createdAt })
    #expect(try library.latestAttempt(in: item.id)?.id == third.id)
}

/// Button-mash protection: "color it again" on an untouched canvas is a
/// no-op — the pristine attempt is returned as-is and nothing new lands on
/// disk, no matter how many times the button is hit.
@Test func libraryNewAttemptOnPristineCanvasIsANoOp() throws {
    let (library, root) = makeTempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }

    let item = try library.add(sampleTemplate(title: "Mash"))
    let seeded = try library.latestAttempt(in: item.id)!

    for _ in 1...5 {
        let result = try library.newAttempt(in: item.id)
        #expect(result.id == seeded.id)
    }
    #expect(try library.attempts(in: item.id).count == 1)
}

/// The archive is a ring buffer, not a landfill: cycling fill→reset more
/// times than the cap leaves exactly current + cap attempts on disk, with
/// the OLDEST ones rolled off — the newest archive entry (the work just
/// reset) is always among the survivors.
@Test func libraryNewAttemptRollsOldestArchivedAttemptsOffTheRing() throws {
    let (library, root) = makeTempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }

    let item = try library.add(sampleTemplate(title: "Cycle"))
    var archivedIDs: [String] = []
    for cycle in 1...5 {
        var current = try library.latestAttempt(in: item.id)!
        current.fill("r\(cycle)")
        try library.saveAttempt(current, in: item.id)
        archivedIDs.append(current.id)
        try library.newAttempt(in: item.id)
    }

    let survivors = try library.attempts(in: item.id)
    #expect(survivors.count == CBNLibrary.archivedAttemptCap + 1)
    let survivorIDs = Set(survivors.map(\.id))
    // Newest three archives survive; the two oldest rolled off.
    #expect(survivorIDs.isSuperset(of: archivedIDs.suffix(3)))
    #expect(survivorIDs.isDisjoint(with: archivedIDs.prefix(2)))
    // The current (pristine, post-reset) attempt is the latest.
    #expect(try library.latestAttempt(in: item.id)?.isPristine == true)
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
