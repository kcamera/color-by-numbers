import Foundation

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
        filledRegionIDs.append(regionID)
        updatedAt = max(Date(), updatedAt)
    }

    /// Removes the most recently filled region, if any — the undo button's
    /// entire implementation. Generous, always-available undo (DESIGN.md)
    /// means this never needs a confirmation.
    public mutating func undoLastFill() {
        guard !filledRegionIDs.isEmpty else { return }
        filledRegionIDs.removeLast()
        updatedAt = max(Date(), updatedAt)
    }

    /// Assigns the drawing blob and bumps `updatedAt`, mirroring `fill` and
    /// `undoLastFill` — a boundary-assist/freehand stroke is exactly as
    /// autosave-worthy as a tap-to-fill (DESIGN.md's "continuous autosave").
    /// Passing `nil` is a legitimate assignment (clearing the drawing), not
    /// a no-op guard, since unlike `fill` there's no idempotency concern to
    /// protect the undo stack from.
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
