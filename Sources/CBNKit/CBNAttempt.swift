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

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        filledRegionIDs: [String] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.filledRegionIDs = filledRegionIDs
    }

    /// Appends `regionID` to the fill order and bumps `updatedAt`. A total
    /// no-op if it's already filled — a second tap on an already-colored
    /// region is not a new action, and must not let a child duplicate an
    /// entry in the undo stack.
    public mutating func fill(_ regionID: String) {
        guard !filledRegionIDs.contains(regionID) else { return }
        filledRegionIDs.append(regionID)
        updatedAt = Date()
    }

    /// Removes the most recently filled region, if any — the undo button's
    /// entire implementation. Generous, always-available undo (DESIGN.md)
    /// means this never needs a confirmation.
    public mutating func undoLastFill() {
        guard !filledRegionIDs.isEmpty else { return }
        filledRegionIDs.removeLast()
        updatedAt = Date()
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
