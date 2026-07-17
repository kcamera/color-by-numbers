import Foundation

/// One entry in `CBNAttempt.actionLog` — which kind of thing the child did,
/// in the order it happened. A `strokes` entry is ONE drawing gesture:
/// boundary-assist clipping can bake a single gesture into several
/// `PKStroke`s (the line splits wherever it leaves the allowed area), and
/// undo must take back the whole gesture, so the entry carries how many
/// sub-strokes it produced. Persisted as a single readable string —
/// `"fill"`, `"stroke"` (one sub-stroke; also what early-M3 files already
/// contain), or `"strokes:N"` — so the JSON stays as legible as every other
/// Codable type in this package and old files keep decoding forever.
public enum CBNAttemptAction: Codable, Equatable, Sendable {
    case fill
    case strokes(Int)

    /// The common single-sub-stroke gesture, and the decoded form of the
    /// legacy `"stroke"` string.
    public static let stroke = CBNAttemptAction.strokes(1)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "fill":
            self = .fill
        case "stroke":
            self = .strokes(1)
        default:
            guard raw.hasPrefix("strokes:"), let count = Int(raw.dropFirst("strokes:".count)), count > 0 else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unrecognized attempt action '\(raw)'"
                ))
            }
            self = .strokes(count)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .fill: try container.encode("fill")
        // One sub-stroke encodes as the legacy spelling, so a freehand-only
        // attempt's JSON is byte-identical to what early M3 already wrote.
        case .strokes(1): try container.encode("stroke")
        case .strokes(let count): try container.encode("strokes:\(count)")
        }
    }

    /// True for any drawing-gesture entry, regardless of sub-stroke count —
    /// what undo dispatch and `undoLastStroke`'s precondition actually care
    /// about (`== .stroke` would wrongly reject a clipped multi-sub-stroke
    /// gesture).
    public var isStrokeGesture: Bool {
        if case .strokes = self { return true }
        return false
    }
}

/// One coloring session of one template. "Color it again" (docs/DESIGN.md's
/// agency model) creates a NEW attempt rather than resetting this one — old
/// attempts are kept, becoming a visible record of a child's growing motor
/// control over months. CBNLibrary is what actually keeps them around; this
/// type is just the per-session state.
public struct CBNAttempt: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Region ids filled so far, in the order the child filled them. An
    /// ordered array, not a Set, because order IS the undo stack.
    public var filledRegionIDs: [String]
    /// Opaque serialized-PencilKit-drawing blob for boundary-assist/freehand
    /// modes (DESIGN.md's skill ladder). CBNKit also builds for macOS (the
    /// cbnc CLI), so it must never import PencilKit or any UI framework —
    /// to CBNKit this is just bytes it persists untouched on the app's
    /// behalf. `Optional` rather than defaulting to empty `Data` so tap-to-fill
    /// attempts (which never draw) stay distinguishable from a drawing that's
    /// merely empty, and so it round-trips through Swift's synthesized
    /// Codable as an absent key rather than a required one — M2 attempt
    /// JSONs already on real iPads predate this field entirely and must
    /// still decode.
    public var drawingData: Data?
    /// The order fills and strokes happened in, across BOTH kinds — what
    /// lets one Undo button take back "the last thing that happened"
    /// regardless of which kind it was (M3's interleaved undo). `nil` means
    /// "written before this field existed": M2/early-M3 attempt JSONs
    /// already on real iPads have `filledRegionIDs` but no log at all, and
    /// must keep decoding forever, exactly the backward-compat contract
    /// `drawingData` documents above. Read `effectiveActionLog` instead of
    /// this directly — it's always populated. This stored form only
    /// materializes lazily, the moment `fill`/`recordStroke`/`undoLastFill`/
    /// `undoLastStroke` first needs a real array to mutate.
    public private(set) var actionLog: [CBNAttemptAction]?

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        filledRegionIDs: [String] = [],
        drawingData: Data? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.filledRegionIDs = filledRegionIDs
        self.drawingData = drawingData
    }

    /// `actionLog` if this attempt has one yet, else the correct
    /// reconstruction for a pre-log attempt: one `.fill` per entry of
    /// `filledRegionIDs`, in the same order — the only action a pre-log
    /// attempt could ever have taken (freehand didn't exist yet). Invariant
    /// preserved by every mutator below: the number of `.fill` entries in
    /// the effective log always equals `filledRegionIDs.count`.
    public var effectiveActionLog: [CBNAttemptAction] {
        actionLog ?? filledRegionIDs.map { _ in .fill }
    }

    /// Backfills `actionLog` from `effectiveActionLog` the first time a
    /// mutator needs a real array to append to or pop from, so a pre-log
    /// attempt's reconstructed history isn't discarded the moment it's
    /// touched again — called at the top of `fill`, `recordStroke`,
    /// `undoLastFill`, and `undoLastStroke`.
    private mutating func materializeActionLogIfNeeded() {
        if actionLog == nil {
            actionLog = effectiveActionLog
        }
    }

    /// Appends `regionID` to the fill order and bumps `updatedAt`. A total
    /// no-op if it's already filled — a second tap on an already-colored
    /// region is not a new action, and must not let a child duplicate an
    /// entry in the undo stack.
    ///
    /// `max(Date(), updatedAt)` — here and in every mutation — keeps
    /// `updatedAt` monotonic: `CBNLibrary.newAttempt` may stamp a fresh
    /// attempt up to a few seconds into the "future" (its whole-second
    /// collision bump), and a plain `Date()` on the child's very next
    /// action would drag `updatedAt` back BELOW `createdAt`, tying with
    /// the just-archived attempt and making "latest" ambiguous again.
    public mutating func fill(_ regionID: String) {
        guard !filledRegionIDs.contains(regionID) else { return }
        materializeActionLogIfNeeded()
        filledRegionIDs.append(regionID)
        actionLog?.append(.fill)
        updatedAt = max(Date(), updatedAt)
    }

    /// Removes the most recently filled region, if any — half of the undo
    /// button's implementation (the app calls this specific half only when
    /// `effectiveActionLog.last == .fill`; the other half is
    /// `undoLastStroke`). Generous, always-available undo (DESIGN.md) means
    /// this never needs a confirmation.
    public mutating func undoLastFill() {
        guard !filledRegionIDs.isEmpty else { return }
        materializeActionLogIfNeeded()
        assert(actionLog?.last == .fill, "undoLastFill called but the last action wasn't a fill")
        filledRegionIDs.removeLast()
        actionLog?.removeLast()
        updatedAt = max(Date(), updatedAt)
    }

    /// Records a completed freehand/boundary-assist drawing gesture:
    /// assigns the freshly re-serialized drawing, appends one `.strokes`
    /// entry to the log, and bumps `updatedAt` — the interactive canvas's
    /// autosave path (DESIGN.md "continuous autosave"), called once per
    /// completed gesture. `substrokes` is how many `PKStroke`s the gesture
    /// baked into (1 for freehand; boundary-assist clipping can split one
    /// gesture into several), so undo knows how many to remove together.
    public mutating func recordStroke(_ data: Data, substrokes: Int = 1) {
        materializeActionLogIfNeeded()
        drawingData = data
        actionLog?.append(.strokes(substrokes))
        updatedAt = max(Date(), updatedAt)
    }

    /// The other half of the undo button (see `undoLastFill`): the caller
    /// has already removed the last `PKStroke` from the live drawing and
    /// re-serialized what remains — `nil` when that removal emptied the
    /// canvas entirely — and this just records that outcome: assigns it,
    /// pops the trailing log entry, bumps `updatedAt`.
    public mutating func undoLastStroke(updatedDrawing: Data?) {
        materializeActionLogIfNeeded()
        guard actionLog?.isEmpty == false else { return }
        assert(actionLog?.last?.isStrokeGesture == true, "undoLastStroke called but the last action wasn't a stroke gesture")
        drawingData = updatedDrawing
        actionLog?.removeLast()
        updatedAt = max(Date(), updatedAt)
    }

    /// Assigns the drawing blob and bumps `updatedAt`, mirroring `fill` and
    /// `undoLastFill` — a boundary-assist/freehand stroke is exactly as
    /// autosave-worthy as a tap-to-fill (DESIGN.md's "continuous autosave").
    /// Passing `nil` is a legitimate assignment (clearing the drawing), not
    /// a no-op guard, since unlike `fill` there's no idempotency concern to
    /// protect the undo stack from. Deliberately log-agnostic (unlike
    /// `recordStroke`/`undoLastStroke`): the interactive canvas never calls
    /// this directly, it's for restore/tooling paths — reinstalling a saved
    /// drawing wholesale — where there's no single discrete action to log.
    public mutating func setDrawing(_ data: Data?) {
        drawingData = data
        updatedAt = max(Date(), updatedAt)
    }

    /// True when nothing has ever been colored here: no fills, no drawn
    /// strokes. "Color it again" cares (CBNLibrary.newAttempt): resetting a
    /// pristine attempt is a no-op, and a pristine attempt is never worth
    /// archiving — it carries zero information.
    public var isPristine: Bool {
        filledRegionIDs.isEmpty && (drawingData?.isEmpty ?? true)
    }

    public func isFilled(_ regionID: String) -> Bool {
        filledRegionIDs.contains(regionID)
    }

    /// True once every region in `template` has been filled. Compares by
    /// set membership, not count, so a template that (illegitimately) has
    /// duplicate region ids can't report false completion.
    public func isComplete(for template: CBNTemplate) -> Bool {
        let filled = Set(filledRegionIDs)
        return template.regions.allSatisfy { filled.contains($0.id) }
    }
}
