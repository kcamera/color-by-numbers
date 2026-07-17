import SwiftUI

/// The parent room behind the Workshop gate (DESIGN.md's agency model:
/// "parent curates, child creates"). Same desk material as the Studio, but
/// laid out as calm stacked groups rather than List chrome — this is a
/// workshop bench, not a settings screen. Three sections for now: "Bring in
/// a picture" and "Pictures" are placeholders another agent wires up (M4's
/// import/management flows); "Drawing" is the one real feature shipped
/// here — parent-adjustable ink width for the two drawing modes.
struct WorkshopView: View {
    @Environment(\.dismiss) private var dismiss

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

                    BringInPictureSection()
                    PicturesSection()
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

/// Placeholder: another agent delivers the actual import flow. Disabled so
/// it reads as "not yet," not as a dead end a parent might poke at
/// wondering why nothing happens.
private struct BringInPictureSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Bring in a picture")
            Button(action: {}) {
                Text("Choose a photo")
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundStyle(DeskStyle.inkColor)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Capsule(style: .continuous).fill(Color.white.opacity(0.7)))
            }
            .buttonStyle(.plain)
            .disabled(true)
            .opacity(0.5)
        }
    }
}

/// Placeholder: another agent delivers picture management (rename, archive,
/// delete — all Workshop-only per DESIGN.md's "nothing destructive in the
/// Studio").
private struct PicturesSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Pictures")
            Text("Picture management is coming soon.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(DeskStyle.inkColor.opacity(0.7))
        }
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

/// One drawing mode's width row: a size picker a parent groks instantly —
/// each choice IS a filled circle of that literal diameter, so "bigger
/// circle, thicker line" needs no legend. Selected state reuses
/// `PaletteSwatch`'s recipe exactly (white-material backing circle, a
/// stronger ink ring, no color change) — same calm "no reward circuitry"
/// rule, same visual language, just picking a width instead of a crayon.
private struct WidthPicker: View {
    let label: String
    let sizes: [CGFloat]
    let selected: CGFloat
    let accessibilityPrefix: String
    let onSelect: (CGFloat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(DeskStyle.inkColor)

            HStack(spacing: 20) {
                ForEach(sizes, id: \.self) { size in
                    let isSelected = selected == size
                    Button(action: { onSelect(size) }) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.7))
                            Circle()
                                .fill(DeskStyle.inkColor)
                                .frame(width: size, height: size)
                        }
                        .overlay(
                            Circle().strokeBorder(DeskStyle.inkColor, lineWidth: isSelected ? 3 : 0)
                        )
                        .frame(width: 64, height: 64)
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
        }
    }
}

#Preview(traits: .landscapeLeft) {
    WorkshopView()
}
