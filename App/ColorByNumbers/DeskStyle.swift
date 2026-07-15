import SwiftUI

/// Shared visual tokens for the "soft analog craft table" aesthetic
/// (docs/DESIGN.md's aesthetic north star): paper-warm surfaces, a desk the
/// artwork sits on, soft shadows. One place to hold these, since M6's
/// tuning pass will want to touch them without hunting across every view —
/// same rationale the old StudioPlaceholderView called out for its two
/// colors, extended to cover corner radii and shadow now that there's more
/// than one screen.
///
/// These are first guesses, not final values. Expect them to move.
enum DeskStyle {
    /// The desk/table surface every screen sits on.
    static let deskColor = Color(red: 0.96, green: 0.94, blue: 0.90)
    /// Ink for text, icons, and quiet controls — warm dark gray, never
    /// harsh black, matching TemplateRenderer's outline tone.
    static let inkColor = Color(red: 0.36, green: 0.32, blue: 0.28)

    /// Corner radius for a Studio library card (a "page" resting on the desk).
    static let cardCornerRadius: CGFloat = 18
    /// Corner radius for the Canvas's large centered page.
    static let pageCornerRadius: CGFloat = 22

    /// One soft shadow recipe, shared by every "paper on desk" surface.
    static let shadowColor = Color.black.opacity(0.18)
    static let shadowRadius: CGFloat = 10
    static let shadowYOffset: CGFloat = 6

    /// Margin between the Canvas page's edge and the artwork it frames —
    /// keeps the template from touching the page's rounded corners.
    static let canvasArtworkMargin: CGFloat = 28
}
