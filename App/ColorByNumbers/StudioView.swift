import CBNKit
import PencilKit
import SwiftUI

/// The kid's library — DESIGN.md's "Studio": a grid of coloring pages, tap
/// one to start coloring. Nothing here is destructive and nothing here is a
/// setting; deletion, renaming, import, and export all live in the Workshop
/// (M4), behind its own parental gate. The Studio's safety comes from what
/// simply isn't reachable from it, not from confirmation dialogs.
struct StudioView: View {
    let library: CBNLibrary

    @State private var items: [CBNLibraryItem] = []
    /// Each item's latest attempt, loaded alongside `items` — this is what
    /// makes a thumbnail honest (DESIGN.md: the Studio grid must reflect
    /// autosaved progress, not a pristine outline) rather than a second copy
    /// of the template.
    @State private var latestAttempts: [String: CBNAttempt] = [:]
    /// Outline thumbnails, keyed by `ThumbnailKey` (item id + the attempt's
    /// `updatedAt`) and kept here — TemplateRenderer is CPU rasterization,
    /// not something to redo on every body evaluation. Keying on `updatedAt`
    /// rather than just item id is what makes the cache self-invalidating:
    /// a stale-keyed entry (coloring happened since it was rendered) simply
    /// misses and gets regenerated, so returning from the canvas refreshes
    /// exactly the cards that changed and nothing else.
    @State private var thumbnails: [ThumbnailKey: Image] = [:]

    /// Identifies "this item's thumbnail as of this attempt state." Two
    /// fields, not one, because the template alone never changes (immutable
    /// per CBNTemplate's doc comment) but the attempt does on every fill —
    /// `updatedAt` is the cheap, already-persisted proxy for "the fills
    /// changed" without diffing `filledRegionIDs` arrays.
    private struct ThumbnailKey: Hashable {
        let itemID: String
        let attemptUpdatedAt: Date
    }

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 28)]

    var body: some View {
        NavigationStack {
            ZStack {
                DeskStyle.deskColor.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Color by Numbers")
                            .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                            .foregroundStyle(DeskStyle.inkColor)
                            .padding(.top, 8)

                        LazyVGrid(columns: columns, spacing: 28) {
                            ForEach(items) { item in
                                NavigationLink {
                                    CanvasView(library: library, item: item)
                                } label: {
                                    TemplateCard(item: item, thumbnail: thumbnails[key(for: item)])
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(32)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            // `.onAppear` rather than `.task`, and on the stack's root
            // CONTENT rather than on the NavigationStack itself: the stack
            // container never disappears during a push (it hosts the push),
            // so a modifier out there fires once per launch and the grid
            // would show stale fills after coloring. The content view is
            // what gets covered by CanvasView and re-appears on pop — the
            // exact "re-check on return" moment this reload exists for.
            .onAppear {
                loadItems()
            }
        }
    }

    /// The cache key for `item`'s thumbnail as of its latest known attempt.
    /// `.distantPast` for an item not yet in `latestAttempts` just means "no
    /// cache hit yet" — `loadItems` populates both together, so this never
    /// causes an item to render with a wrong (too-fresh) key.
    private func key(for item: CBNLibraryItem) -> ThumbnailKey {
        ThumbnailKey(itemID: item.id, attemptUpdatedAt: latestAttempts[item.id]?.updatedAt ?? .distantPast)
    }

    private func loadItems() {
        guard let loaded = try? library.items() else { return }
        items = loaded
        for item in loaded {
            let attempt = try? library.latestAttempt(in: item.id)
            latestAttempts[item.id] = attempt
            let key = ThumbnailKey(itemID: item.id, attemptUpdatedAt: attempt?.updatedAt ?? .distantPast)
            // A cache hit means nothing changed since the last render for
            // this exact attempt state — skip the (comparatively expensive)
            // CPU rasterization entirely.
            guard thumbnails[key] == nil else { continue }
            renderThumbnail(for: item, attempt: attempt, key: key)
        }
    }

    /// Renders the outline-and-fills bitmap (`TemplateRenderer`), then, if
    /// the attempt has a drawing, composites her strokes on top — DESIGN.md's
    /// honest-thumbnail rule: the Studio grid must reflect what she actually
    /// drew, not just where she tapped. Strokes persist in TEMPLATE
    /// coordinates (see `FitTransform.viewToTemplateTransform`'s doc comment,
    /// CanvasView.swift), so `PKDrawing.image(from:scale:)` at this same
    /// `scale` lines up with `TemplateRenderer`'s bitmap pixel-for-pixel —
    /// no view-space transform needed, unlike the live canvas. Cache
    /// invalidation needs no changes here: `ThumbnailKey` is keyed on
    /// `updatedAt`, and `recordStroke` already bumps that exactly like
    /// `fill` does, so a stroke-only change still misses the cache.
    private func renderThumbnail(for item: CBNLibraryItem, attempt: CBNAttempt?, key: ThumbnailKey) {
        let targetWidth = 360.0
        let scale = targetWidth / max(item.template.size.width, 1)
        // `.outline` + `filledRegionIDs`: the in-progress face of
        // TemplateRenderer (see its doc comment) — the same appearance the
        // child sees on the canvas, baked to a bitmap for the grid.
        guard let cgImage = TemplateRenderer.render(
            item.template, mode: .outline, scale: scale, filledRegionIDs: Set(attempt?.filledRegionIDs ?? [])
        ) else { return }

        guard let data = attempt?.drawingData,
              let drawing = try? PKDrawing(data: data),
              // The shared renderer applies boundary-assist's paint clip
              // per gesture (CommittedInkRenderer) — the thumbnail must
              // show exactly what the canvas shows, bloom included-out.
              let strokesImage = CommittedInkRenderer.image(
                  drawing: drawing,
                  actionLog: attempt?.effectiveActionLog ?? [],
                  template: item.template,
                  scale: scale
              )
        else {
            thumbnails[key] = Image(decorative: cgImage, scale: 1)
            return
        }

        let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)

        // Compositing with UIKit's own `draw(in:)`, never the raw
        // CGContext `draw(_:in:)`: both source images (TemplateRenderer's
        // CGImage and PencilKit's `drawing.image`) are already top-left-
        // origin, UIKit-convention images, and `UIGraphicsImageRenderer`'s
        // context is likewise flipped to match UIKit — drawing through
        // UIImage keeps that convention consistent throughout. The raw
        // CGContext API expects bottom-left-origin CGImages and would
        // silently flip one layer relative to the other. Verified visually
        // (see .claude/skills/verify) rather than assumed.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        let composited = renderer.image { _ in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: pixelSize))
            strokesImage.draw(in: CGRect(origin: .zero, size: pixelSize))
        }
        thumbnails[key] = Image(uiImage: composited)
    }
}

/// One library card: a white "page" with a soft shadow holding the
/// template's outline thumbnail, titled beneath in rounded type.
private struct TemplateCard: View {
    let item: CBNLibraryItem
    let thumbnail: Image?

    private var aspectRatio: Double {
        item.template.size.height > 0 ? item.template.size.width / item.template.size.height : 1
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: DeskStyle.cardCornerRadius, style: .continuous)
                    .fill(Color.white)
                    .shadow(
                        color: DeskStyle.shadowColor,
                        radius: DeskStyle.shadowRadius,
                        x: 0,
                        y: DeskStyle.shadowYOffset
                    )

                if let thumbnail {
                    thumbnail
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(16)
                }
            }
            .aspectRatio(aspectRatio, contentMode: .fit)

            Text(item.template.title)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(DeskStyle.inkColor)
        }
    }
}

#Preview(traits: .landscapeLeft) {
    StudioView(library: previewLibrary(seeding: [.previewSample]))
}
