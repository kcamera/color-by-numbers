import Foundation

/// One entry in `CBNAttempt.actionLog` — which kind of thing the child did,
/// in the order it happened. A `strokes` entry is ONE drawing gesture: a
/// gesture may span several `PKStroke`s (however PencilKit chose to store
/// it), and undo must take back the whole gesture, so the entry carries how
/// many sub-strokes it produced. Persisted as a single readable string —
/// `"fill"`, `"stroke"` (one sub-stroke), or `"strokes:N"` — so the JSON
/// stays as legible as every other Codable type in this package.
public enum CBNAttemptAction: Codable, Equatable, Sendable {
    /// A tap fill: flat paint laid over one region (the id lives in
    /// `CBNAttempt.tapFillRegionIDs`, in log order).
    case fill
    case strokes(Int)
    /// A boundary-assist gesture: RENDERERS must mask its paint to the
    /// crayon's allowed regions — that render-time mask is the SOLE
    /// enforcement of boundary-assist's promise; the stored strokes are the
    /// child's gesture verbatim (the wet/dry fidelity fix), so rendered
    /// unmasked they would paint past every outline they crossed.
    case clippedStrokes(Int)

    /// The common single-sub-stroke gesture, and the decoded form of the
    /// compact `"stroke"` spelling.
    public static let stroke = CBNAttemptAction.strokes(1)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "fill":
            self = .fill
        case "stroke":
            self = .strokes(1)
        default:
            if raw.hasPrefix("strokes:"), let count = Int(raw.dropFirst("strokes:".count)), count > 0 {
                self = .strokes(count)
            } else if raw.hasPrefix("clipped:"), let count = Int(raw.dropFirst("clipped:".count)), count > 0 {
                self = .clippedStrokes(count)
            } else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unrecognized attempt action '\(raw)'"
                ))
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .fill: try container.encode("fill")
        // One sub-stroke encodes as the compact spelling.
        case .strokes(1): try container.encode("stroke")
        case .strokes(let count): try container.encode("strokes:\(count)")
        case .clippedStrokes(let count): try container.encode("clipped:\(count)")
        }
    }

    /// How many `PKStroke`s this gesture spans in the drawing, regardless
    /// of kind — what undo and the committed-ink renderer both walk by.
    public var substrokeCount: Int? {
        switch self {
        case .fill: nil
        case .strokes(let count), .clippedStrokes(let count): count
        }
    }

    /// True for any drawing-gesture entry, regardless of sub-stroke count —
    /// what undo dispatch and `undoLastStroke`'s precondition actually care
    /// about (`== .stroke` would wrongly reject a multi-sub-stroke gesture).
    public var isStrokeGesture: Bool {
        substrokeCount != nil
    }
}

/// One coloring session of one template. "Color it again" (docs/DESIGN.md's
/// agency model) creates a NEW attempt rather than resetting this one — old
/// attempts are kept, becoming a visible record of a child's growing motor
/// control over months. CBNLibrary is what actually keeps them around; this
/// type is just the per-session state.
///
/// This type records PAINT, never judgments: tap fills and stroke gestures
/// are the two kinds of marks a child can make, and both live here as
/// facts about what she did. Whether a region "is colored" is a question
/// about PIXELS — the app measures it from the rendered composite of both
/// kinds of paint (InkCoverage) — and deliberately has no answer here: a
/// stroke-colored region is exactly as colored as a tap-filled one, and any
/// list-based answer would say otherwise.
public struct CBNAttempt: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Region ids the child TAP-FILLED, in the order she tapped them — a
    /// record of flat paint laid down (renderers paint each listed region
    /// solid in its palette color), NOT a "which regions are colored"
    /// answer. Ordered because order recovers each `.fill` log entry's
    /// region: the log's `.fill` entries and this array correspond 1:1, in
    /// the same order — the invariant every mutator below preserves.
    public var tapFillRegionIDs: [String]
    /// Opaque serialized-PencilKit-drawing blob for boundary-assist/freehand
    /// modes (DESIGN.md's skill ladder). CBNKit also builds for macOS (the
    /// cbnc CLI), so it must never import PencilKit or any UI framework —
    /// to CBNKit this is just bytes it persists untouched on the app's
    /// behalf. `Optional` rather than defaulting to empty `Data` so
    /// tap-to-fill attempts (which never draw) stay distinguishable from a
    /// drawing that's merely empty.
    public var drawingData: Data?
    /// The order tap fills and stroke gestures happened in, across BOTH
    /// kinds — what lets one Undo button take back "the last thing that
    /// happened" regardless of which kind it was (M3's interleaved undo),
    /// and what lets `CommittedInkRenderer` replay paint in true
    /// chronological order (a late tap fill paints OVER an earlier
    /// scribble).
    public private(set) var actionLog: [CBNAttemptAction]

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        tapFillRegionIDs: [String] = [],
        drawingData: Data? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tapFillRegionIDs = tapFillRegionIDs
        self.drawingData = drawingData
        // A fresh attempt built with pre-seeded tap fills (tests, tooling)
        // still needs a log that honors the 1:1 `.fill` invariant.
        self.actionLog = tapFillRegionIDs.map { _ in .fill }
    }

    /// Builds a fresh attempt carrying another attempt's coloring history
    /// verbatim — `CBNLibrary.restoreAttempt`'s building block for "bring an
    /// archived attempt back as the current one" (M4 Workshop). A new id and
    /// caller-supplied timestamps (restoring makes a NEW current attempt;
    /// `source` — the archived one — is untouched and stays exactly where it
    /// was), but `tapFillRegionIDs`, `drawingData`, and the full `actionLog`
    /// all copy across as-is — a restored attempt must keep its real gesture
    /// history, not a flattened stand-in. This initializer lives in the same
    /// file as `actionLog`'s `private(set)` precisely so it's the one place
    /// allowed to assign it wholesale instead of appending to it.
    init(restoring source: CBNAttempt, id: String = UUID().uuidString, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tapFillRegionIDs = source.tapFillRegionIDs
        self.drawingData = source.drawingData
        self.actionLog = source.actionLog
    }

    /// Records a tap fill: appends `regionID` to the tap-fill paint record
    /// and bumps `updatedAt`. A total no-op if the region already has a tap
    /// fill — a second tap on the same region is not a new mark, and must
    /// not let a child duplicate an entry in the undo stack.
    ///
    /// `max(Date(), updatedAt)` — here and in every mutation — keeps
    /// `updatedAt` monotonic: `CBNLibrary.newAttempt` may stamp a fresh
    /// attempt up to a few seconds into the "future" (its whole-second
    /// collision bump), and a plain `Date()` on the child's very next
    /// action would drag `updatedAt` back BELOW `createdAt`, tying with
    /// the just-archived attempt and making "latest" ambiguous again.
    public mutating func recordTapFill(_ regionID: String) {
        guard !tapFillRegionIDs.contains(regionID) else { return }
        tapFillRegionIDs.append(regionID)
        actionLog.append(.fill)
        updatedAt = max(Date(), updatedAt)
    }

    /// Removes the most recent tap fill, if any — half of the undo button's
    /// implementation (the app calls this specific half only when
    /// `actionLog.last == .fill`; the other half is `undoLastStroke`).
    /// Generous, always-available undo (DESIGN.md) means this never needs a
    /// confirmation.
    public mutating func undoLastTapFill() {
        guard !tapFillRegionIDs.isEmpty else { return }
        assert(actionLog.last == .fill, "undoLastTapFill called but the last action wasn't a fill")
        tapFillRegionIDs.removeLast()
        actionLog.removeLast()
        updatedAt = max(Date(), updatedAt)
    }

    /// Records a completed freehand/boundary-assist drawing gesture:
    /// assigns the freshly re-serialized drawing, appends one `.strokes`
    /// entry to the log, and bumps `updatedAt` — the interactive canvas's
    /// autosave path (DESIGN.md "continuous autosave"), called once per
    /// completed gesture. `substrokes` is how many `PKStroke`s the gesture
    /// spans in the drawing (virtually always 1 — however PencilKit stored
    /// it), so undo knows how many to remove together. `clipped` marks a
    /// boundary-assist gesture, so renderers know to mask that stroke
    /// slice's PAINT to the crayon's regions (see
    /// `CBNAttemptAction.clippedStrokes`).
    public mutating func recordStroke(_ data: Data, substrokes: Int = 1, clipped: Bool = false) {
        drawingData = data
        actionLog.append(clipped ? .clippedStrokes(substrokes) : .strokes(substrokes))
        updatedAt = max(Date(), updatedAt)
    }

    /// The other half of the undo button (see `undoLastTapFill`): the
    /// caller has already removed the last gesture's `PKStroke`s from the
    /// live drawing and re-serialized what remains — `nil` when that
    /// removal emptied the canvas entirely — and this just records that
    /// outcome: assigns it, pops the trailing log entry, bumps `updatedAt`.
    public mutating func undoLastStroke(updatedDrawing: Data?) {
        guard !actionLog.isEmpty else { return }
        assert(actionLog.last?.isStrokeGesture == true, "undoLastStroke called but the last action wasn't a stroke gesture")
        drawingData = updatedDrawing
        actionLog.removeLast()
        updatedAt = max(Date(), updatedAt)
    }

    /// Assigns the drawing blob and bumps `updatedAt`, mirroring
    /// `recordTapFill` and `undoLastTapFill` — a boundary-assist/freehand
    /// stroke is exactly as autosave-worthy as a tap fill (DESIGN.md's
    /// "continuous autosave"). Passing `nil` is a legitimate assignment
    /// (clearing the drawing), not a no-op guard, since unlike
    /// `recordTapFill` there's no idempotency concern to protect the undo
    /// stack from. Deliberately log-agnostic (unlike
    /// `recordStroke`/`undoLastStroke`): the interactive canvas never calls
    /// this directly, it's for restore/tooling paths — reinstalling a saved
    /// drawing wholesale — where there's no single discrete action to log.
    public mutating func setDrawing(_ data: Data?) {
        drawingData = data
        updatedAt = max(Date(), updatedAt)
    }

    /// True when nothing has ever been colored here: no tap fills, no drawn
    /// strokes. "Color it again" cares (CBNLibrary.newAttempt): resetting a
    /// pristine attempt is a no-op, and a pristine attempt is never worth
    /// archiving — it carries zero information.
    public var isPristine: Bool {
        tapFillRegionIDs.isEmpty && (drawingData?.isEmpty ?? true)
    }

    /// Whether this region already carries a TAP FILL — a paint-record
    /// question (`tap`'s idempotency guard), never a "is this region
    /// colored" question; a region solidly covered by strokes returns
    /// false here, by design.
    public func hasTapFill(_ regionID: String) -> Bool {
        tapFillRegionIDs.contains(regionID)
    }
}
