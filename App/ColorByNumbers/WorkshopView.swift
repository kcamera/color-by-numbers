import CBNKit
import SwiftUI
// `UIImage` (from `ThumbnailRenderer.image`, CommittedInk.swift) needs this
// explicit import here — unlike CanvasView.swift/StudioView.swift, this file
// never imports PencilKit for its own sake, so there's no other module in
// this file's import list that would expose UIKit types transitively.
import UIKit

/// The parent room behind the Workshop gate (DESIGN.md's agency model:
/// "parent curates, child creates"). Same desk material as the Studio, but
/// laid out as calm stacked groups rather than List chrome — this is a
/// workshop bench, not a settings screen. All three sections are real:
/// "Bring in a picture" (M4's import flow, `ImportFlowView.swift`),
/// "Pictures" (rename/archive/delete management, this file), and "Drawing"
/// (the per-mode ink width pickers).
struct WorkshopView: View {
    let library: CBNLibrary

    @Environment(\.dismiss) private var dismiss

    // `BringInPictureSection` and `PicturesSection` are separate sibling
    // views, each with their own private state — `PicturesSection` only
    // (re)reads the library on ITS OWN `.onAppear`, which a
    // `fullScreenCover` dismissal never re-fires (same root cause as the
    // Studio-not-reloading-after-Workshop bug from earlier in M4, just one
    // level deeper). Kevin's report: a completed import never showed up in
    // "Pictures" until leaving and re-entering the Workshop entirely. This
    // counter is the bridge: bumped whenever the import cover dismisses
    // (added or cancelled — reload is cheap and idempotent either way),
    // read by `PicturesSection` as a reload trigger.
    @State private var picturesReloadTrigger = 0

    var body: some View {
        ZStack {
            DeskStyle.deskColor.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    HStack {
                        Text("Workshop")
                            .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                            .foregroundStyle(DeskStyle.inkColor)
                        Spacer()
                        CloseControl { dismiss() }
                    }
                    .padding(.top, 8)

                    BringInPictureSection(library: library) {
                        picturesReloadTrigger += 1
                    }
                    PicturesSection(library: library, reloadTrigger: picturesReloadTrigger)
                    DrawingSection()
                }
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// A section's rounded header — plain text, no List/Form chrome, matching
/// this screen's "stacked groups" layout rather than a settings table.
private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(.title2, design: .rounded, weight: .semibold))
            .foregroundStyle(DeskStyle.inkColor)
    }
}

/// M4's real import entry point: presents `ImportFlowView` full-screen —
/// same "wholly separate room" rationale `WorkshopDoor` already uses for the
/// Gate→Workshop hop (StudioView.swift), and a fresh instance every
/// presentation, so a cancelled-out-of import never lingers with a stale
/// picked photo the next time this opens.
private struct BringInPictureSection: View {
    let library: CBNLibrary
    /// Fires once the import cover dismisses, added picture or not — lets
    /// `WorkshopView` tell the (unrelated, sibling) `PicturesSection` to
    /// reload without the two views knowing anything else about each other.
    let onImportFlowDismissed: () -> Void

    @State private var showingImportFlow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Bring in a picture")
            Button(action: { showingImportFlow = true }) {
                Text("Choose a photo")
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundStyle(DeskStyle.inkColor)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Capsule(style: .continuous).fill(Color.white.opacity(0.7)))
            }
            .buttonStyle(.plain)
        }
        .fullScreenCover(isPresented: $showingImportFlow, onDismiss: onImportFlowDismissed) {
            ImportFlowView(library: library)
        }
    }
}

/// M4's library management: one stacked card per library item (rename,
/// archive browsing, delete) — all Workshop-only per DESIGN.md's "nothing
/// destructive in the Studio." Parent space is different from kid space in
/// exactly the way DESIGN.md says: confirmations ARE allowed here, because
/// destruction is the point of "Remove"/"Forget" — but even here there's no
/// system alert chrome, just this section's own calm inline swaps.
private struct PicturesSection: View {
    let library: CBNLibrary
    let reloadTrigger: Int

    @State private var items: [CBNLibraryItem] = []
    /// Every attempt per item, NEWEST FIRST — `CBNLibrary.attempts(in:)`'s
    /// own sort contract. `.first` is always the CURRENT attempt (every
    /// fresh attempt is minted with a timestamp strictly past whatever came
    /// before it — see `newAttempt`/`restoreAttempt`'s shared
    /// `timestampStrictlyAfter` — so the newest one always sorts first),
    /// and everything after it is exactly the archive `CBNLibrary`'s ring
    /// buffer keeps, which is what "Earlier versions" reveals below.
    @State private var attemptsByItem: [String: [CBNAttempt]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Pictures")

            if items.isEmpty {
                Text("No pictures yet.")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(DeskStyle.inkColor.opacity(0.7))
            } else {
                VStack(spacing: 16) {
                    ForEach(items) { item in
                        let attempts = attemptsByItem[item.id] ?? []
                        PictureRow(
                            library: library,
                            item: item,
                            currentAttempt: attempts.first,
                            archivedAttempts: Array(attempts.dropFirst()),
                            onChange: reload
                        )
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: reloadTrigger) { _, _ in reload() }
    }

    /// Re-reads the library's full state — items plus every item's attempt
    /// history — on first appearance and after every mutation a row below
    /// can cause (rename, remove, restore, forget), per the M4 spec's
    /// "reload after every operation" contract. Whole-section re-read
    /// rather than incremental patching: this is a dense parent-only
    /// management list, not a hot path, and simple-and-correct beats
    /// keeping several caches in sync by hand.
    private func reload() {
        guard let loaded = try? library.items() else { return }
        items = loaded
        for item in loaded {
            attemptsByItem[item.id] = (try? library.attempts(in: item.id)) ?? []
        }
    }
}

/// One library item's management row: a small thumbnail (the shared
/// `ThumbnailRenderer` recipe, CommittedInk.swift — same honest outline+
/// fills+ink bitmap the Studio card shows for this same item), the title
/// (or an inline rename field), and Rename/Remove. Below, only when there's
/// archived history, the "Earlier versions" disclosure. `rowState` collapses
/// what would otherwise be several independent booleans into one enum, so
/// "renaming AND confirming removal at once" is unrepresentable rather than
/// merely avoided by convention.
private struct PictureRow: View {
    let library: CBNLibrary
    let item: CBNLibraryItem
    let currentAttempt: CBNAttempt?
    let archivedAttempts: [CBNAttempt]
    let onChange: () -> Void

    private enum RowState: Equatable {
        case normal
        case renaming
        case confirmingRemove
    }

    @State private var rowState: RowState = .normal
    /// Pre-filled with the CURRENT title the moment Rename is tapped (below)
    /// — this is an edit, not a naming, unlike `ImportFlowView`'s blank
    /// "New Picture" prompt.
    @State private var titleDraft = ""
    @State private var showingAttempts = false

    private var aspectRatio: Double {
        item.template.size.height > 0 ? item.template.size.width / item.template.size.height : 1
    }

    private var thumbnail: Image? {
        ThumbnailRenderer.image(template: item.template, attempt: currentAttempt, targetWidth: 120)
            .map { Image(uiImage: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                RowThumbnail(image: thumbnail, aspectRatio: aspectRatio, width: 90)
                rowContent
            }

            // Only when there's archived history to browse (the M4 spec's
            // "only when the item has MORE than one attempt" gate) — an item
            // with just its current attempt has nothing here worth a
            // disclosure at all.
            if !archivedAttempts.isEmpty {
                attemptsDisclosure
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: DeskStyle.cardCornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.7))
        )
    }

    @ViewBuilder
    private var rowContent: some View {
        switch rowState {
        case .normal:
            Text(item.template.title)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(DeskStyle.inkColor)
            Spacer()
            RowButton(title: "Rename", accessibilityLabel: "Rename \(item.template.title)") {
                titleDraft = item.template.title
                rowState = .renaming
            }
            RowButton(title: "Remove", accessibilityLabel: "Remove \(item.template.title)") {
                rowState = .confirmingRemove
            }

        case .renaming:
            TextField(item.template.title, text: $titleDraft)
                .accessibilityIdentifier("Rename field")
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(DeskStyle.inkColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule(style: .continuous).fill(Color.white.opacity(0.9)))
            Spacer()
            RowButton(title: "Save", accessibilityLabel: "Save \(item.template.title)") {
                saveRename()
            }

        case .confirmingRemove:
            // Inline confirm, not a system alert (parent space still keeps
            // this app's calm-material language — DESIGN.md) — the row's
            // own controls simply swap to state the consequence in words.
            Text("Remove this picture?")
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(DeskStyle.inkColor)
            Spacer()
            RowButton(title: "Keep", accessibilityLabel: "Keep \(item.template.title)") {
                rowState = .normal
            }
            RowButton(title: "Remove", accessibilityLabel: "Remove \(item.template.title)") {
                removeItem()
            }
        }
    }

    /// Only when there's more than one archived version worth naming this a
    /// "ring" — a lone entry still reads fine as a flat two-line list, and a
    /// bespoke plural/singular header isn't worth the complexity for a
    /// parent-only screen.
    private var attemptsDisclosure: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: { showingAttempts.toggle() }) {
                HStack(spacing: 6) {
                    Image(systemName: showingAttempts ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                    Text("Earlier versions")
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                }
                .foregroundStyle(DeskStyle.inkColor.opacity(0.7))
            }
            .buttonStyle(.plain)
            // Title-suffixed for the same reason Rename/Remove are below:
            // every item with archived history shows this control at once,
            // so "Earlier versions" alone would be ambiguous the moment two
            // pictures both have an archive.
            .accessibilityLabel("Earlier versions \(item.template.title)")

            if showingAttempts {
                VStack(spacing: 10) {
                    ForEach(archivedAttempts) { attempt in
                        ArchivedAttemptRow(library: library, item: item, attempt: attempt, onChange: onChange)
                    }
                }
                .padding(.leading, 20)
            }
        }
    }

    /// Falls back to the item's existing title on a blank save — this is an
    /// edit of an existing name, not a fresh naming (unlike ImportFlowView's
    /// "New Picture" default for a brand-new item), so an emptied field just
    /// means "no change" rather than inventing a new placeholder title.
    private func saveRename() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = trimmed.isEmpty ? item.template.title : trimmed
        try? library.renameItem(item.id, title: resolvedTitle)
        rowState = .normal
        onChange()
    }

    /// Starters reseed only into an EMPTY library (`CBNLibrary.seedIfEmpty`'s
    /// own guard) — so removing a starter here while other pictures remain
    /// is permanent, not a "reset to defaults" affordance. That's correct
    /// parent-zone behavior per this milestone's spec: the Workshop is where
    /// destruction is allowed to actually destroy.
    private func removeItem() {
        try? library.deleteItem(item.id)
        onChange()
    }
}

/// One archived attempt inside a picture's "Earlier versions" disclosure:
/// its own mini thumbnail (the FULL `ThumbnailRenderer` fills+ink recipe —
/// a fills-only shortcut here would lie about drawings, per the M4 spec),
/// its date, and Bring back / Forget. Forget gets the same inline-confirm
/// swap `PictureRow`'s Remove uses above, for the same calm-material reason.
private struct ArchivedAttemptRow: View {
    let library: CBNLibrary
    let item: CBNLibraryItem
    let attempt: CBNAttempt
    let onChange: () -> Void

    @State private var confirmingForget = false

    private var aspectRatio: Double {
        item.template.size.height > 0 ? item.template.size.width / item.template.size.height : 1
    }

    private var thumbnail: Image? {
        ThumbnailRenderer.image(template: item.template, attempt: attempt, targetWidth: 90)
            .map { Image(uiImage: $0) }
    }

    /// Disambiguates this attempt's controls from every other attempt in
    /// the same picture's archive (the M4 spec's "unambiguous for the
    /// driver" requirement) — guaranteed unique per item because every
    /// archived attempt's `createdAt` is strictly later than the one before
    /// it (`CBNLibrary.timestampStrictlyAfter`'s invariant), so no two
    /// entries in one item's archive can ever format to the same string.
    private var dateText: String {
        attempt.createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        HStack(spacing: 12) {
            RowThumbnail(image: thumbnail, aspectRatio: aspectRatio, width: 60)

            Text(dateText)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(DeskStyle.inkColor.opacity(0.8))

            Spacer()

            if confirmingForget {
                Text("Forget this version?")
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(DeskStyle.inkColor)
                RowButton(title: "Keep", accessibilityLabel: "Keep \(item.template.title) \(dateText)") {
                    confirmingForget = false
                }
                RowButton(title: "Forget", accessibilityLabel: "Forget \(item.template.title) \(dateText)") {
                    forget()
                }
            } else {
                RowButton(title: "Bring back", accessibilityLabel: "Bring back \(item.template.title) \(dateText)") {
                    restore()
                }
                RowButton(title: "Forget", accessibilityLabel: "Forget \(item.template.title) \(dateText)") {
                    confirmingForget = true
                }
            }
        }
    }

    /// The picture's current state becomes this archived version — a NEW
    /// current attempt (`CBNLibrary.restoreAttempt`), so the Studio picks it
    /// up via its existing cover-dismissal reload (`StudioView`'s
    /// `.onChange(of: showingWorkshop)`) once this Workshop closes, same as
    /// every other Pictures mutation here.
    private func restore() {
        try? library.restoreAttempt(attempt.id, in: item.id)
        onChange()
    }

    /// `CBNLibrary.deleteAttempt` itself refuses the CURRENT attempt, but
    /// this row is only ever built from `archivedAttempts` (`PictureRow`'s
    /// `attempts.dropFirst()`) — the current one is never offered here in
    /// the first place, so that refusal is a defensive backstop, not a path
    /// this UI can actually reach.
    private func forget() {
        try? library.deleteAttempt(attempt.id, in: item.id)
        onChange()
    }
}

/// A row's thumbnail: a small white "page" holding whatever
/// `ThumbnailRenderer` produced, same material as `StudioView.TemplateCard`
/// scaled down for this section's denser rows.
private struct RowThumbnail: View {
    let image: Image?
    let aspectRatio: Double
    let width: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white)
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .frame(width: width)
    }
}

/// A row-scoped quiet text button — same white capsule material as every
/// other quiet control in this app, sized down for a dense management row
/// rather than the Canvas/Studio's small-finger 64pt floor (this is
/// grown-up space, same "standard target" call `CloseControl` already
/// makes in WorkshopGateView.swift).
private struct RowButton: View {
    let title: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(DeskStyle.inkColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule(style: .continuous).fill(Color.white.opacity(0.9)))
        }
        .buttonStyle(.plain)
        // Spoken name for VoiceOver; also the UI-test driver's handle, same
        // dual purpose as every other control in this app.
        .accessibilityLabel(accessibilityLabel)
    }
}

/// The one real feature this milestone ships: two width pickers, one per
/// drawing mode that actually draws ink (tap-to-fill has no stroke width to
/// tune). Reads its starting selection from the same UserDefaults keys
/// `DrawingFeel.width(for:)` reads (CanvasView.swift) — that struct is the
/// single choke point both sides agree on, so this view never invents its
/// own key strings to drift out of sync.
private struct DrawingSection: View {
    private static let sizes: [CGFloat] = [4, 6, 8, 10, 14]

    @State private var freehandWidth = storedWidth(forKey: DrawingFeel.freehandWidthKey, fallback: 6)
    @State private var boundaryWidth = storedWidth(forKey: DrawingFeel.boundaryWidthKey, fallback: 10)

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "Drawing")

            WidthPicker(
                label: "Freehand ink",
                sizes: Self.sizes,
                selected: freehandWidth,
                accessibilityPrefix: "Freehand width"
            ) { width in
                freehandWidth = width
                UserDefaults.standard.set(Double(width), forKey: DrawingFeel.freehandWidthKey)
            }

            WidthPicker(
                label: "Stay-inside ink",
                sizes: Self.sizes,
                selected: boundaryWidth,
                accessibilityPrefix: "Lines width"
            ) { width in
                boundaryWidth = width
                UserDefaults.standard.set(Double(width), forKey: DrawingFeel.boundaryWidthKey)
            }
        }
    }
}

/// Mirrors `DrawingFeel.width(for:)`'s own "0 means no override yet" read —
/// duplicated rather than shared because `DrawingFeel.width(for:)` takes a
/// `CanvasMode`, and this call site only ever has a raw key + fallback
/// (there's no mode to hand it at the point either `@State` initializes).
private func storedWidth(forKey key: String, fallback: CGFloat) -> CGFloat {
    let stored = UserDefaults.standard.double(forKey: key)
    return stored > 0 ? CGFloat(stored) : fallback
}

/// One drawing mode's width row. Originally each choice was a filled circle
/// at that literal diameter, but a dot's size reads relative to its own
/// small button frame, not to the canvas the ink actually lands on — a 6pt
/// dot in a 64pt box looks bold, while the 6pt LINE it produces on a
/// page-sized canvas looks thin. That mismatch is what Kevin's M4-gate
/// feedback flagged as misleading. Fixed by drawing an actual ink LINE (a
/// stroke is a line, not a dot) at the literal width, and putting every
/// option on one shared paper card so the five widths compare directly
/// against each other in the same register real ink appears in — "thicker
/// choice, thicker line on the page" is now literally what's drawn.
private struct WidthPicker: View {
    let label: String
    let sizes: [CGFloat]
    let selected: CGFloat
    let accessibilityPrefix: String
    let onSelect: (CGFloat) -> Void

    private static let swatchLength: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(DeskStyle.inkColor)

            HStack(spacing: 4) {
                ForEach(sizes, id: \.self) { size in
                    let isSelected = selected == size
                    Button(action: { onSelect(size) }) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(isSelected ? DeskStyle.inkColor.opacity(0.12) : .clear)

                            Capsule()
                                .fill(DeskStyle.inkColor)
                                .frame(width: Self.swatchLength, height: size)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 72)
                    }
                    .buttonStyle(.plain)
                    // Spoken name doubles as the UI-test driver's handle;
                    // the `.isSelected` trait is what lets the test confirm
                    // the persisted choice survived a relaunch without
                    // having to read pixel state off a screenshot.
                    .accessibilityLabel("\(accessibilityPrefix) \(Int(size))")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DeskStyle.cardCornerRadius, style: .continuous)
                    .fill(Color.white)
                    .shadow(
                        color: DeskStyle.shadowColor,
                        radius: DeskStyle.shadowRadius,
                        x: 0,
                        y: DeskStyle.shadowYOffset
                    )
            )
        }
    }
}

#if DEBUG
#Preview(traits: .landscapeLeft) {
    WorkshopView(library: previewLibrary(seeding: [.previewSample]))
}
#endif
