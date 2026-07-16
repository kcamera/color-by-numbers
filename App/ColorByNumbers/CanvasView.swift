import CBNKit
import SwiftUI

/// Owns one coloring session: the immutable template plus its mutable
/// attempt. Every mutation saves through `CBNLibrary` immediately —
/// DESIGN.md's continuous-autosave contract ("no save button, no prompts;
/// state survives anything") means saving isn't a user action here, it's a
/// property of every write.
@Observable
@MainActor
final class CanvasModel {
    let library: CBNLibrary
    let item: CBNLibraryItem
    private(set) var attempt: CBNAttempt
    /// The crayon the child currently holds. Selection is pure UI state, not
    /// attempt state (M3 active-color model) — it is never undoable and
    /// never persisted; a fresh session always starts on the first palette
    /// entry, same as picking up the first crayon in a new box.
    var selectedColorNumber: Int

    init(library: CBNLibrary, item: CBNLibraryItem) {
        self.library = library
        self.item = item
        // Every item has a latestAttempt in practice — `add`/`seedIfEmpty`
        // both create one before a card can ever appear in the Studio. A
        // read failure here is defensive only: fall back to a fresh attempt
        // so a library hiccup still lets the child color, rather than
        // failing the whole screen.
        if let loaded = try? library.latestAttempt(in: item.id) {
            attempt = loaded
        } else {
            attempt = CBNAttempt()
        }
        // The importer guarantees a non-empty palette; falling back to 0
        // rather than crashing keeps a malformed template from taking down
        // the whole screen (same defensiveness as the attempt load above).
        selectedColorNumber = item.template.palette.first?.number ?? 0
    }

    var template: CBNTemplate { item.template }

    /// A tap in TEMPLATE coordinate space (already mapped back through the
    /// view's fit transform). Fills the topmost region under the point if
    /// it exists, matches the held crayon, and isn't already filled;
    /// otherwise a silent no-op — a miss, a re-tap, and a wrong-color tap
    /// are all the same "nothing happened" per the calm contract (DESIGN.md
    /// — no error feedback, ever).
    func tap(at point: CBNPoint) {
        guard let region = template.region(at: point),
              region.colorNumber == selectedColorNumber,
              !attempt.isFilled(region.id)
        else { return }
        attempt.fill(region.id)
        save()
    }

    /// Swapping crayons never touches the attempt and is never undoable —
    /// there is nothing here for the calm contract's undo/safety story to
    /// guard (DESIGN.md).
    func selectColor(_ number: Int) {
        selectedColorNumber = number
    }

    /// Generous, always-available undo (DESIGN.md) — never a confirmation.
    /// A no-op at zero fills, so the button can stay tappable rather than
    /// disabled.
    func undo() {
        guard !attempt.filledRegionIDs.isEmpty else { return }
        attempt.undoLastFill()
        save()
    }

    private func save() {
        do {
            try library.saveAttempt(attempt, in: item.id)
        } catch {
            // A failed save must never crash the child's app (CLAUDE.md) —
            // the coloring already happened on screen; only the persistence
            // of it failed.
            assertionFailure("Failed to save attempt: \(error)")
        }
    }
}

/// Maps between view space (the page rect the artwork is drawn into) and the
/// template's own coordinate space, uniformly scaled and centered. The same
/// transform draws every region and interprets every tap back into template
/// space, so hit-testing and rendering can never disagree with each other.
private struct FitTransform {
    let scale: CGFloat
    /// Top-left of the scaled template, in view space.
    let origin: CGPoint

    init(templateSize: CBNSize, into rect: CGRect) {
        let widthScale = rect.width / max(templateSize.width, 1)
        let heightScale = rect.height / max(templateSize.height, 1)
        scale = min(widthScale, heightScale)

        let drawnWidth = templateSize.width * scale
        let drawnHeight = templateSize.height * scale
        origin = CGPoint(
            x: rect.minX + (rect.width - drawnWidth) / 2,
            y: rect.minY + (rect.height - drawnHeight) / 2
        )
    }

    func templateToView(_ point: CBNPoint) -> CGPoint {
        CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
    }

    func viewToTemplate(_ point: CGPoint) -> CBNPoint {
        CBNPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
    }
}

/// The coloring canvas: tap a region, it fills. Skill-ladder mode 1
/// (tap-to-fill) of DESIGN.md's three; boundary-assist and freehand arrive
/// later on this same document, same canvas.
struct CanvasView: View {
    @State private var model: CanvasModel
    @Environment(\.dismiss) private var dismiss

    init(library: CBNLibrary, item: CBNLibraryItem) {
        _model = State(initialValue: CanvasModel(library: library, item: item))
    }

    var body: some View {
        // Read the observed state once, up front, so Observation's
        // dependency tracking attaches to `body`'s own execution rather
        // than to Canvas's separate rendering closure.
        let template = model.template
        let filledIDs = Set(model.attempt.filledRegionIDs)
        let hasFills = !model.attempt.filledRegionIDs.isEmpty
        let isComplete = model.attempt.isComplete(for: template)

        ZStack {
            DeskStyle.deskColor.ignoresSafeArea()

            GeometryReader { proxy in
                let pageRect = CGRect(origin: .zero, size: proxy.size)
                let artworkRect = pageRect.insetBy(
                    dx: DeskStyle.canvasArtworkMargin,
                    dy: DeskStyle.canvasArtworkMargin
                )
                let fit = FitTransform(templateSize: template.size, into: artworkRect)

                ZStack {
                    RoundedRectangle(cornerRadius: DeskStyle.pageCornerRadius, style: .continuous)
                        .fill(Color.white)
                        .shadow(
                            color: DeskStyle.shadowColor,
                            radius: DeskStyle.shadowRadius,
                            x: 0,
                            y: DeskStyle.shadowYOffset
                        )

                    Canvas { context, _ in
                        draw(template: template, filledIDs: filledIDs, fit: fit, in: context)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    guard pageRect.contains(location) else { return }
                    model.tap(at: fit.viewToTemplate(location))
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 28)

            VStack {
                HStack {
                    BackControl { dismiss() }
                    Spacer()
                    if isComplete {
                        DoneBadge()
                    }
                }
                Spacer()
            }
            .padding(24)

            // Vertically centered so it can never collide with the
            // top-trailing DoneBadge or bottom-trailing UndoControl, which
            // both hug their corners — the two Spacers keep equal clearance
            // on either side regardless of screen height (M3 spec: inset
            // from those corners, not stacked alongside them).
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    PaletteRail(
                        palette: template.palette,
                        selectedColorNumber: model.selectedColorNumber
                    ) { number in
                        model.selectColor(number)
                    }
                }
                Spacer()
            }
            .padding(24)

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    UndoControl(hasFills: hasFills) { model.undo() }
                }
            }
            .padding(24)
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
    }

    /// Draws every region in stored painter's order: filled regions get
    /// their palette color, unfilled regions stay white with their number
    /// printed at the label point — mirroring TemplateRenderer's `.outline`
    /// + per-region fill, just interactive instead of baked into a bitmap.
    private func draw(
        template: CBNTemplate,
        filledIDs: Set<String>,
        fit: FitTransform,
        in context: GraphicsContext
    ) {
        // TemplateRenderer.outlineGray is `internal` to CBNKit and not
        // visible here, so this mirrors its literal value — warm dark gray
        // ink, never harsh black (DESIGN.md's soft-analog direction).
        let outlineColor = Color(red: 0.35, green: 0.33, blue: 0.31)
        let paletteByNumber = Dictionary(
            uniqueKeysWithValues: template.palette.map { ($0.number, $0.rgb) }
        )

        for region in template.regions {
            guard region.path.count >= 3 else { continue }

            var path = Path()
            for ring in [region.path] + region.holes where ring.count >= 3 {
                path.move(to: fit.templateToView(ring[0]))
                for point in ring.dropFirst() {
                    path.addLine(to: fit.templateToView(point))
                }
                path.closeSubpath()
            }

            let isFilled = filledIDs.contains(region.id)
            var fillColor = Color.white
            if isFilled, let rgb = paletteByNumber[region.colorNumber] ?? nil {
                fillColor = Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
            }

            context.fill(path, with: .color(fillColor), style: FillStyle(eoFill: true))
            context.stroke(path, with: .color(outlineColor), lineWidth: 1.2)

            if !isFilled {
                drawNumber(region: region, fit: fit, color: outlineColor, in: context)
            }
        }
    }

    /// Number sizing mirrors TemplateRenderer.drawNumber's formula exactly:
    /// diameter from net region area (outer ring minus holes), font size
    /// clamped to 9...40 TEMPLATE units, then scaled into view space by the
    /// same fit transform that drew the region. A final ~7pt display floor
    /// keeps a tiny region's number from vanishing once scaled down for a
    /// small canvas — TemplateRenderer has no such floor because it always
    /// renders at a chosen output scale, but the Canvas here can end up much
    /// smaller than template units.
    private func drawNumber(
        region: CBNRegion,
        fit: FitTransform,
        color: Color,
        in context: GraphicsContext
    ) {
        let netArea = max(
            abs(PolygonGeometry.signedArea(of: region.path))
                - region.holes.reduce(0) { $0 + abs(PolygonGeometry.signedArea(of: $1)) },
            1
        )
        let diameter = netArea.squareRoot()
        let templateFontSize = min(max(diameter * 0.22, 9), 40)
        let displaySize = max(templateFontSize * fit.scale, 7)

        let text = Text("\(region.colorNumber)")
            .font(.system(size: displaySize, design: .rounded))
            .foregroundStyle(color)
        context.draw(text, at: fit.templateToView(region.labelPoint), anchor: .center)
    }
}

/// Quiet top-leading return to the Studio. No save prompt — autosave makes
/// leaving mid-picture always safe (DESIGN.md).
private struct BackControl: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                Text("Studio")
            }
            .font(.system(.body, design: .rounded, weight: .medium))
            .foregroundStyle(DeskStyle.inkColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.7)))
        }
        .buttonStyle(.plain)
    }
}

/// A quiet statement of fact, not a celebration: when the last region is
/// filled, the word "Done" appears top-trailing in the same capsule material
/// as the back control, and simply stays. No animation, no sound, no color
/// shift (DESIGN.md: no rewards — the finished art itself is the moment).
/// It disappears again if undo re-opens a region, because it describes the
/// attempt's current state, not an achievement that was "earned".
private struct DoneBadge: View {
    var body: some View {
        Text("Done")
            .font(.system(.body, design: .rounded, weight: .medium))
            .foregroundStyle(DeskStyle.inkColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.7)))
    }
}

/// The undo button: always present (DESIGN.md — "stable furniture, no
/// popping in/out"). At zero fills it dims rather than disappearing or
/// disabling; `CanvasModel.undo()` is already a safe no-op with nothing to
/// undo, so there's no need to block the tap. ≥64pt hit target for small
/// fingers.
private struct UndoControl: View {
    let hasFills: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(DeskStyle.inkColor)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Color.white.opacity(0.7)))
        }
        .buttonStyle(.plain)
        .opacity(hasFills ? 1 : 0.35)
        // A symbol-only button needs a spoken name (VoiceOver); it also
        // serves as the UI-test driver's handle.
        .accessibilityLabel("Undo")
    }
}

/// The numbered crayon tray: one swatch per palette entry, in palette
/// order, along the trailing edge. Color-BY-NUMBER means the number
/// annotation is the point (DESIGN.md — the child matches crayon number to
/// region numbers), so every swatch shows both its color and its number,
/// never color alone. Our templates top out at 6 colors, so this is a
/// plain stack — no scrolling to build for a case that doesn't exist yet.
private struct PaletteRail: View {
    let palette: [CBNPaletteEntry]
    let selectedColorNumber: Int
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(spacing: 12) {
            ForEach(palette, id: \.number) { entry in
                PaletteSwatch(
                    entry: entry,
                    isSelected: entry.number == selectedColorNumber,
                    action: { onSelect(entry.number) }
                )
            }
        }
    }
}

/// One crayon: a palette-colored disc in the same white-ish capsule
/// material as Back/Undo, ringed when it's the held color. ≥64pt hit
/// target for small fingers (DESIGN.md), same floor as UndoControl.
private struct PaletteSwatch: View {
    let entry: CBNPaletteEntry
    let isSelected: Bool
    let action: () -> Void

    private var swatchColor: Color {
        guard let rgb = entry.rgb else { return .white }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// The number must stay legible on every palette color, from pale
    /// Sailcloth to dark Deep Sea — a fixed ink tone would vanish against
    /// half the palette, so pick light or dark text by swatch luminance.
    private var numberColor: Color {
        guard let rgb = entry.rgb else { return DeskStyle.inkColor }
        let luminance = 0.299 * rgb.red + 0.587 * rgb.green + 0.114 * rgb.blue
        return luminance > 0.6 ? DeskStyle.inkColor : .white
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.7))
                Circle()
                    .fill(swatchColor)
                    .padding(6)
                Text("\(entry.number)")
                    .font(.system(.callout, design: .rounded, weight: .bold))
                    .foregroundStyle(numberColor)
            }
            .overlay(
                // A quiet, calm selected state — a stronger ring, not a
                // color change or animation (DESIGN.md: no reward
                // circuitry). Function-first; the M6 polish pass owns the
                // final look.
                Circle()
                    .strokeBorder(DeskStyle.inkColor, lineWidth: isSelected ? 3 : 0)
            )
            .frame(width: 64, height: 64)
        }
        .buttonStyle(.plain)
        // Spoken name for VoiceOver; also the UI-test driver's handle for
        // "hold crayon N", same dual purpose as Undo's label.
        .accessibilityLabel("Color \(entry.number)")
    }
}

#Preview(traits: .landscapeLeft) {
    let library = previewLibrary(seeding: [.previewSample])
    let item = (try? library.items())?.first
    NavigationStack {
        if let item {
            CanvasView(library: library, item: item)
        }
    }
}
