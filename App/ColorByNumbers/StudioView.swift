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
    /// Whether the Workshop door's full-screen cover is up. Its content is
    /// a single `WorkshopDoor` instance (below) that internally swaps Gate
    /// for Workshop on a correct code — a fresh instance every presentation
    /// means the Gate always starts locked again, never remembering a
    /// previous session's unlock.
    @State private var showingWorkshop = false

    /// Identifies "this item's thumbnail as of this attempt state." Two
    /// fields, not one, because the template alone never changes (immutable
    /// per CBNTemplate's doc comment) but the attempt does on every mark —
    /// `updatedAt` is the cheap, already-persisted proxy for "the paint
    /// changed" without diffing `tapFillRegionIDs` arrays or drawing blobs.
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

                // The Workshop door (DESIGN.md's agency model: ONE parental
                // gate). Top-trailing, same white "material" as every other
                // quiet control here, but no color and no badge — it must
                // read as furniture, not a toy inviting a tap.
                VStack {
                    HStack {
                        Spacer()
                        WorkshopDoorControl { showingWorkshop = true }
                    }
                    Spacer()
                }
                .padding(24)
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
            // Full-screen rather than a sheet: the app is landscape-only
            // (Fixed constraints, DESIGN.md), so there's no compact-width
            // sheet presentation to prefer, and the Workshop is a wholly
            // separate "room" from the Studio, not a peek-and-pop panel.
            .fullScreenCover(isPresented: $showingWorkshop) {
                WorkshopDoor(library: library)
            }
            // A cover dismissal does NOT re-fire the content's `.onAppear`
            // (unlike a navigation pop — the content never "disappeared"),
            // so returning from the Workshop needs its own reload: imports
            // add cards, management renames/deletes them, and the grid must
            // reflect all of it the moment the cover drops.
            .onChange(of: showingWorkshop) { _, isShowing in
                if !isShowing {
                    loadItems()
                }
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

    /// Renders the outline-and-fills-and-ink bitmap via the shared
    /// `ThumbnailRenderer` (CommittedInk.swift) — DESIGN.md's honest-
    /// thumbnail rule: the Studio grid must reflect what she actually drew,
    /// not just where she tapped. Cache invalidation needs no changes here:
    /// `ThumbnailKey` is keyed on `updatedAt`, and `recordStroke` already
    /// bumps that exactly like `fill` does, so a stroke-only change still
    /// misses the cache.
    private func renderThumbnail(for item: CBNLibraryItem, attempt: CBNAttempt?, key: ThumbnailKey) {
        guard let uiImage = ThumbnailRenderer.image(template: item.template, attempt: attempt, targetWidth: 360)
        else { return }
        thumbnails[key] = Image(uiImage: uiImage)
    }
}

/// The Workshop door itself: a quiet, colorless control that reads as
/// furniture rather than a toy — `wrench.and.screwdriver` is a placeholder
/// (M6 polish owns the real icon). Same white "material" fill as every
/// other quiet control in the app (`BackControl`, `UndoControl`, etc., in
/// CanvasView.swift).
private struct WorkshopDoorControl: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(DeskStyle.inkColor)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.white.opacity(0.7)))
        }
        .buttonStyle(.plain)
        // Spoken name for VoiceOver; also the UI-test driver's handle.
        .accessibilityLabel("Workshop")
    }
}

/// Bridges the door's two stops — Gate, then Workshop — inside ONE
/// full-screen cover. Unlocking swaps content in place (a local `@State`
/// flip) rather than dismissing the Gate's cover to present a second one:
/// back-to-back full-screen covers from the same presenter fight each
/// other on iOS, and this sidesteps that entirely. Because a fresh instance
/// of this view is created every time `showingWorkshop` above flips true,
/// `unlocked` always starts `false` — dismissing the Gate without the code,
/// or leaving the Workshop, both return here to a locked door next time
/// (DESIGN.md: ONE parental gate, no way to linger past it unlocked).
private struct WorkshopDoor: View {
    let library: CBNLibrary

    @State private var unlocked = false

    var body: some View {
        if unlocked {
            WorkshopView(library: library)
        } else {
            WorkshopGateView(onUnlocked: { unlocked = true })
        }
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

#if DEBUG
#Preview(traits: .landscapeLeft) {
    StudioView(library: previewLibrary(seeding: [.previewSample]))
}
#endif
