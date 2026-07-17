import CBNKit
import PencilKit
import SwiftUI

/// Which coloring tool is live — DESIGN.md's full skill ladder, in
/// declaration order = switch order: tap-to-fill (toddler), boundary-assist
/// (preschool: real drawing, ink only lands where the held crayon's number
/// lives), freehand (elementary). `CaseIterable` + `Hashable` so every
/// switch/`ForEach` over `CanvasMode` in this file picks a new case up by
/// construction.
enum CanvasMode: CaseIterable, Hashable {
    case tapFill
    case boundaryAssist
    case freehand
}

private extension CanvasMode {
    /// Doubles as the UI-test driver's handle, same dual purpose as
    /// "Undo" and "Color N" elsewhere in this file.
    var accessibilityLabel: String {
        switch self {
        case .tapFill: "Tap mode"
        case .boundaryAssist: "Lines mode"
        case .freehand: "Draw mode"
        }
    }
}

/// Placeholder glyphs (M3): Kevin's real icons — fingertip, squiggle being
/// clipped BY a shape, squiggle escaping a shape — are M6 polish; until
/// then the middle mode is literally a squiggle held inside a shape and
/// freehand the same squiggle unboxed, honest pictures of the behaviors.
private struct ModeIcon: View {
    let mode: CanvasMode

    var body: some View {
        switch mode {
        case .tapFill:
            Image(systemName: "hand.point.up.left")
                .font(.system(size: 24, weight: .medium))
        case .boundaryAssist:
            Image(systemName: "scribble")
                .font(.system(size: 17, weight: .medium))
                .padding(5)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(lineWidth: 1.5))
        case .freehand:
            Image(systemName: "scribble")
                .font(.system(size: 24, weight: .medium))
        }
    }
}

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
    /// Which coloring tool is live. Session state, like `selectedColorNumber`
    /// above — never undoable, never persisted; a fresh session always
    /// starts on tap-to-fill, the skill ladder's floor (DESIGN.md).
    var mode: CanvasMode = .tapFill
    /// The live PencilKit drawing, mirrored from `attempt.drawingData` at
    /// load and kept in lockstep with it by `strokeChanged`/`undo`
    /// afterward. CBNKit stores the drawing as opaque `Data` and must never
    /// import PencilKit (CBNAttempt.swift) — this app-side `PKDrawing` is
    /// the only place those bytes get interpreted as strokes.
    var drawing: PKDrawing

    init(library: CBNLibrary, item: CBNLibraryItem) {
        self.library = library
        self.item = item
        // Every item has a latestAttempt in practice — `add`/`seedIfEmpty`
        // both create one before a card can ever appear in the Studio. A
        // read failure here is defensive only: fall back to a fresh attempt
        // so a library hiccup still lets the child color, rather than
        // failing the whole screen.
        //
        // Held in a local rather than read back off `self.attempt` below:
        // Swift's two-phase init won't allow reading ANY property off
        // `self` until every stored property has a value, and `drawing`
        // (below) still needs one.
        let loadedAttempt = (try? library.latestAttempt(in: item.id)) ?? CBNAttempt()
        attempt = loadedAttempt
        // The importer guarantees a non-empty palette; falling back to 0
        // rather than crashing keeps a malformed template from taking down
        // the whole screen (same defensiveness as the attempt load above).
        selectedColorNumber = item.template.palette.first?.number ?? 0
        // Restore whatever was drawn last session. A decode failure (or no
        // drawing at all) falls back to a blank canvas rather than failing
        // the screen — same defensiveness as the attempt load above.
        if let data = loadedAttempt.drawingData, let restored = try? PKDrawing(data: data) {
            drawing = restored
        } else {
            drawing = PKDrawing()
        }
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

    /// Switching tools, like swapping crayons, never touches the attempt
    /// and is never undoable.
    func setMode(_ mode: CanvasMode) {
        self.mode = mode
    }

    /// `DrawingCanvas`'s per-gesture autosave path: the live canvas hands
    /// over the finished gesture's strokes — already clipped by the view in
    /// boundary-assist mode — and clears itself; committed ink lives here,
    /// in `drawing`. An empty `landed` (a boundary gesture made entirely
    /// outside the held crayon's regions) is the calm no-op: the in-flight
    /// mask already showed no ink, so nothing appears and nothing is
    /// logged. Mirrors `tap`'s save-through contract (DESIGN.md's
    /// continuous autosave).
    func gestureCompleted(landing landed: [PKStroke], clipped: Bool) {
        guard !landed.isEmpty else { return }
        drawing = PKDrawing(strokes: drawing.strokes + landed)
        attempt.recordStroke(drawing.dataRepresentation(), substrokes: landed.count, clipped: clipped)
        save()
    }

    /// Generous, always-available undo (DESIGN.md), unified across both
    /// action kinds (M3): consults which kind of thing happened last and
    /// takes back exactly that, rather than always assuming a fill. A
    /// stroke entry undoes as a whole GESTURE — boundary-assist may have
    /// baked one gesture into several sub-strokes, and the child undoes
    /// what she did, not what the clipper did. A no-op when nothing has
    /// ever happened in this attempt, so the button can stay tappable
    /// rather than disabled.
    func undo() {
        switch attempt.effectiveActionLog.last {
        case .fill:
            attempt.undoLastFill()
            save()
        case .strokes(let count), .clippedStrokes(let count):
            var strokes = drawing.strokes
            strokes.removeLast(min(count, strokes.count))
            let updated = PKDrawing(strokes: strokes)
            drawing = updated
            attempt.undoLastStroke(updatedDrawing: strokes.isEmpty ? nil : updated.dataRepresentation())
            save()
        case nil:
            break
        }
    }

    /// DESIGN.md's amended "Color it again feels like reset": archives the
    /// attempt she's walking away from — invisibly, ring-buffered — and
    /// starts a fresh one (`CBNLibrary.newAttempt`'s pristine no-op guard
    /// means button-mashing an already-blank canvas archives nothing).
    /// `selectedColorNumber` and `mode` are deliberately left untouched —
    /// the child keeps her held crayon and tool, same as picking up a
    /// fresh page at the same desk rather than being sent back to the
    /// start of the skill ladder. A thrown error leaves state unchanged,
    /// same defensiveness as `save()` — kid space must never crash over a
    /// persistence hiccup.
    func colorItAgain() {
        do {
            attempt = try library.newAttempt(in: item.id)
            drawing = PKDrawing()
        } catch {
            assertionFailure("Failed to color it again: \(error)")
        }
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

/// One region's outer ring + hole rings as a single even-odd Path in view
/// space — shared by the fills renderer (`CanvasView.draw`) and the
/// boundary-assist mask (`BoundaryMask`) so the two can never disagree
/// about where a region is.
private func regionPath(_ region: CBNRegion, fit: FitTransform) -> Path {
    var path = Path()
    for ring in [region.path] + region.holes where ring.count >= 3 {
        path.move(to: fit.templateToView(ring[0]))
        for point in ring.dropFirst() {
            path.addLine(to: fit.templateToView(point))
        }
        path.closeSubpath()
    }
    return path
}

/// Alpha mask of "where the held crayon's ink may land": the VISIBLE area
/// of regions matching the selected number, in painter's order — a matching
/// region masks in, and any region drawn later masks back OUT
/// (`.destinationOut`), so a sky-colored stroke can't paint through the
/// sails stacked on top of the sky polygon. View-level and current-color
/// only: it exists for the in-flight stroke's feel; committed strokes are
/// clipped in their DATA (StrokeClipper) and never pass through this.
private struct BoundaryMask: View {
    let template: CBNTemplate
    let selectedColorNumber: Int
    let fit: FitTransform

    var body: some View {
        Canvas { context, _ in
            for region in template.regions where region.path.count >= 3 {
                context.blendMode = region.colorNumber == selectedColorNumber ? .normal : .destinationOut
                context.fill(
                    regionPath(region, fit: fit),
                    with: .color(.white),
                    style: FillStyle(eoFill: true)
                )
            }
        }
    }
}

/// Bakes boundary-assist's promise into the stroke DATA: sample the
/// finished gesture finely, keep only the samples where ink is allowed, and
/// rebuild the survivors as separate strokes wherever the gesture left the
/// allowed area. Data-level rather than a view mask because committed
/// strokes from DIFFERENT crayons must coexist — a view mask fits only one
/// color at a time and would re-clip old ink on every crayon change.
@MainActor
private enum StrokeClipper {
    /// Sample step along the path, in view points: fine enough that a fast
    /// flick can't tunnel across a thin forbidden band between two allowed
    /// regions.
    static let sampleStep: CGFloat = 2

    static func clip(_ stroke: PKStroke, allowedAt: (CGPoint) -> Bool) -> [PKStroke] {
        var runs: [[PKStrokePoint]] = []
        var current: [PKStrokePoint] = []
        for point in stroke.path.interpolatedPoints(by: .distance(sampleStep)) {
            if allowedAt(point.location.applying(stroke.transform)) {
                current.append(point)
            } else if !current.isEmpty {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }

        // A one-sample run is a sampling artifact at a border crossing, not
        // something the child meaningfully drew — dropping it beats leaving
        // stray dots along region edges.
        return runs.filter { $0.count >= 2 }.map { run in
            PKStroke(
                ink: stroke.ink,
                path: PKStrokePath(controlPoints: run, creationDate: stroke.path.creationDate),
                transform: stroke.transform,
                mask: stroke.mask
            )
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

    /// The view→template mapping as an affine transform, for whole-
    /// PKDrawing conversion at gesture end. Strokes PERSIST in template
    /// space — the document's own coordinate system, like every region
    /// path — never in view points: view space is an accident of one
    /// session's canvas size, and a drawing saved in it would silently
    /// misregister on any other size (a different iPad, a future layout
    /// tweak) and couldn't be composited into Studio thumbnails at all.
    /// (Display goes the other way by RENDERING in template space and
    /// letting SwiftUI size the bitmap — see the committed-ink layer.)
    var viewToTemplateTransform: CGAffineTransform {
        CGAffineTransform(translationX: -origin.x, y: -origin.y)
            .concatenating(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
    }
}

/// The coloring canvas: tap a region, it fills. Skill-ladder mode 1
/// (tap-to-fill) of DESIGN.md's three; boundary-assist and freehand arrive
/// later on this same document, same canvas.
struct CanvasView: View {
    @State private var model: CanvasModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    init(library: CBNLibrary, item: CBNLibraryItem) {
        _model = State(initialValue: CanvasModel(library: library, item: item))
    }

    var body: some View {
        // Read the observed state once, up front, so Observation's
        // dependency tracking attaches to `body`'s own execution rather
        // than to Canvas's separate rendering closure.
        let template = model.template
        let filledIDs = Set(model.attempt.filledRegionIDs)
        let drawing = model.drawing
        let actionLog = model.attempt.effectiveActionLog
        let mode = model.mode
        let selectedColorNumber = model.selectedColorNumber
        // M3: the log, not the fill count, is what Undo dims on — an
        // attempt that's all strokes and no fills still has something to
        // take back.
        let canUndo = !model.attempt.effectiveActionLog.isEmpty
        let isComplete = model.attempt.isComplete(for: template)
        let isPristine = model.attempt.isPristine

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

                    // COMMITTED ink: every completed gesture, rendered from
                    // the single source of truth (model.drawing). A separate
                    // layer from the live PKCanvasView below so boundary-
                    // assist's in-flight mask can never re-clip strokes made
                    // earlier with a DIFFERENT crayon — those were clipped
                    // at the data level when their gesture ended, and render
                    // here mask-free.
                    // Rendered in template space by the shared renderer
                    // (which is what enforces boundary-assist's pixel
                    // promise on committed ink), then framed to the
                    // artwork's on-screen size — the ZStack centers it,
                    // and the fit transform centers the artwork, so the
                    // two agree by construction.
                    if let ink = CommittedInkRenderer.image(
                        drawing: drawing,
                        actionLog: actionLog,
                        template: template,
                        scale: fit.scale,
                        screenScale: displayScale
                    ) {
                        Image(uiImage: ink)
                            .resizable()
                            .frame(
                                width: template.size.width * fit.scale,
                                height: template.size.height * fit.scale
                            )
                            .allowsHitTesting(false)
                    }

                    // LIVE ink: only ever the in-flight gesture; hands its
                    // strokes up on completion and clears itself. Above the
                    // fills and committed ink, below every control layer.
                    DrawingCanvas(
                        isActive: mode != .tapFill,
                        inkColor: paletteColor(for: selectedColorNumber, in: template),
                        inkWidth: DrawingFeel.width(for: mode)
                    ) { gestureStrokes in
                        let landed: [PKStroke]
                        if mode == .boundaryAssist {
                            // Data-level clip: keep the samples where the
                            // topmost region under the pen matches the held
                            // crayon — occlusion for free, since "visible
                            // region at a point" IS the hit test.
                            landed = gestureStrokes.flatMap { stroke in
                                StrokeClipper.clip(stroke) { location in
                                    guard let region = template.region(at: fit.viewToTemplate(location))
                                    else { return false }
                                    return region.colorNumber == selectedColorNumber
                                }
                            }
                        } else {
                            landed = gestureStrokes
                        }
                        // Persist in template space, the document's own
                        // coordinate system — view points are an accident
                        // of this session's canvas size. `clipped` rides
                        // into the action log so renderers know to mask
                        // this gesture's PAINT, not just its center line
                        // (CommittedInkRenderer — the ink-width bloom fix).
                        model.gestureCompleted(
                            landing: PKDrawing(strokes: landed)
                                .transformed(using: fit.viewToTemplateTransform)
                                .strokes,
                            clipped: mode == .boundaryAssist
                        )
                    }
                    .mask {
                        // In-flight feel for boundary-assist: while the
                        // finger is still down, ink only shows where the
                        // held crayon may land (the data clip then makes
                        // that permanent at gesture end). Other modes get
                        // full visibility.
                        if mode == .boundaryAssist {
                            BoundaryMask(
                                template: template,
                                selectedColorNumber: selectedColorNumber,
                                fit: fit
                            )
                        } else {
                            Rectangle()
                        }
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
                    // Leading side of the Done badge in this same HStack,
                    // per M3 spec. Hidden on a pristine attempt: resetting
                    // nothing would be a no-op anyway (CBNLibrary.newAttempt's
                    // mash-guard), and hiding it here keeps the top edge
                    // quiet on first open (DESIGN.md's calm contract).
                    HStack(spacing: 12) {
                        if !isPristine {
                            ColorItAgainControl { model.colorItAgain() }
                        }
                        if isComplete {
                            DoneBadge()
                        }
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
                    UndoControl(canUndo: canUndo) { model.undo() }
                }
            }
            .padding(24)

            // Bottom-LEADING: balances UndoControl at bottom-trailing,
            // stays clear of the trailing PaletteRail and the top edge
            // where the Pencil docks (DESIGN.md's aesthetic north star).
            VStack {
                Spacer()
                HStack {
                    ModeSwitch(mode: model.mode) { model.setMode($0) }
                    Spacer()
                }
            }
            .padding(24)
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
    }

    /// The held crayon's color, for `DrawingCanvas`'s ink — ink follows the
    /// held crayon (M3 spec), same lookup `PaletteSwatch.swatchColor` and
    /// `draw`'s `paletteByNumber` use, just for one entry instead of the
    /// whole palette. Falls back to ink-gray rather than crashing if the
    /// selected number somehow isn't in the palette (same defensiveness as
    /// `CanvasModel.init`'s palette fallback).
    private func paletteColor(for number: Int, in template: CBNTemplate) -> Color {
        guard let entry = template.palette.first(where: { $0.number == number }),
              let rgb = entry.rgb
        else { return DeskStyle.inkColor }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
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
            let path = regionPath(region, fit: fit)
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

/// A quiet text capsule, same material and typography as `BackControl` —
/// DESIGN.md's amended "Color it again feels like reset": to the child
/// it's a fresh page (canvas clears in place), no dialog, no animation, no
/// sound; the archive underneath (`CanvasModel.colorItAgain`) is invisible.
/// `CanvasView.body` shows this only while the attempt is non-pristine.
private struct ColorItAgainControl: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Color it again")
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(DeskStyle.inkColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule(style: .continuous).fill(Color.white.opacity(0.7)))
        }
        .buttonStyle(.plain)
        // Spoken name for VoiceOver; also the UI-test driver's handle.
        .accessibilityLabel("Color it again")
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
/// popping in/out"). At an empty action log it dims rather than
/// disappearing or disabling; `CanvasModel.undo()` is already a safe no-op
/// with nothing to undo, so there's no need to block the tap. Dims on the
/// LOG being empty, not on fill count (M3): an attempt that's all strokes
/// and no fills still has something to take back. ≥64pt hit target for
/// small fingers.
private struct UndoControl: View {
    let canUndo: Bool
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
        .opacity(canUndo ? 1 : 0.35)
        // A symbol-only button needs a spoken name (VoiceOver); it also
        // serves as the UI-test driver's handle.
        .accessibilityLabel("Undo")
    }
}

/// The skill-ladder mode switch (DESIGN.md): a quiet three-position control
/// in the same white-capsule material as Back/Done, one button per
/// `CanvasMode` case. Selected state mirrors `PaletteSwatch`'s ring — a
/// stronger stroke, not a color change (no reward circuitry).
private struct ModeSwitch: View {
    let mode: CanvasMode
    let onSelect: (CanvasMode) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ForEach(CanvasMode.allCases, id: \.self) { candidate in
                Button(action: { onSelect(candidate) }) {
                    ModeIcon(mode: candidate)
                        .foregroundStyle(DeskStyle.inkColor)
                        .frame(width: 64, height: 64)
                        .overlay(
                            Circle().strokeBorder(DeskStyle.inkColor, lineWidth: candidate == mode ? 3 : 0)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(candidate.accessibilityLabel)
            }
        }
        .padding(4)
        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.7)))
    }
}

/// Stroke-feel tuning constants for freehand/boundary-assist drawing,
/// deliberately isolated here — `[design-sensitive]` per docs/PLAN.md's M3
/// gate. First guesses, not a final answer: marker-style ink at a medium
/// width, meant to be tuned in review without hunting through view code.
/// `@MainActor`: `PKInkingTool.InkType` isn't `Sendable`, and every use site
/// (`DrawingCanvas`'s UIViewRepresentable methods) is main-actor-isolated
/// already, so this just states that truth to the Swift 6 checker.
@MainActor
private enum DrawingFeel {
    /// `.monoline` — a round, constant-width line regardless of speed,
    /// pressure, or direction. Kevin's M3 gate feedback: `.marker` renders
    /// as a chisel tip whose width varies with stroke direction, which read
    /// as "calligraphy" rather than a kid's crayon line.
    static let inkType: PKInkingTool.InkType = .monoline

    /// Per-mode width (Kevin's gate feedback, second round): freehand is
    /// line DRAWING, where a finer tip is easier to control; boundary-
    /// assist is coloring-in, where a broader crayon fills faster and the
    /// clip guards the edges anyway. A parent-adjustable width belongs in
    /// the Workshop (M4+) — these are the defaults it will start from.
    static func width(for mode: CanvasMode) -> CGFloat {
        mode == .freehand ? 6 : 10
    }
}

/// PencilKit's real canvas, wrapped for SwiftUI — but deliberately holding
/// ONLY the in-flight gesture, never the whole picture. On completion the
/// gesture's strokes are handed up (`onGesture`) and the canvas clears
/// itself; committed ink is `CanvasModel.drawing`, rendered by the separate
/// committed-image layer in `CanvasView.body`. The split is what makes
/// boundary-assist coherent across crayon changes: the live layer wears the
/// current crayon's mask, while committed strokes — already data-clipped to
/// whatever crayon made them — render mask-free.
private struct DrawingCanvas: UIViewRepresentable {
    /// Tap-to-fill mode must not have this layer intercept touches at all
    /// (M3 spec) — the tap gesture on the `Canvas` beneath is naturally
    /// occluded once this becomes interactive.
    let isActive: Bool
    let inkColor: Color
    let inkWidth: CGFloat
    let onGesture: ([PKStroke]) -> Void

    /// PencilKit registers an ink color as a light/dark appearance PAIR,
    /// derived from the trait collection current at CREATION, then renders
    /// whichever half matches the canvas's traits. If creation happens
    /// under dark or unspecified traits — which UIViewRepresentable
    /// callbacks can hit on a real device before the view joins a window —
    /// the palette color registers as the DARK variant and PencilKit paints
    /// its lightness-FLIPPED light counterpart: pale crayons drew olive and
    /// near-black ink on the real iPad (M3 gate find). Pinning creation to
    /// an explicit light trait makes "the color she picked" the variant
    /// that paints, always; the app is also forced light app-wide
    /// (Info.plist), so no renderer ever asks for the dark half.
    private func makeTool() -> PKInkingTool {
        var tool = PKInkingTool(DrawingFeel.inkType)
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            tool = PKInkingTool(DrawingFeel.inkType, color: UIColor(inkColor), width: inkWidth)
        }
        return tool
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let view = PKCanvasView()
        // Finger/Pencil parity (DESIGN.md) — no separate finger-drawing
        // toggle anywhere in this app.
        view.drawingPolicy = .anyInput
        view.isOpaque = false
        view.backgroundColor = .clear
        // No ruler, no stock tool picker — the only tool offered is the
        // held crayon, applied below.
        view.isRulerActive = false
        view.tool = makeTool()
        view.isUserInteractionEnabled = isActive
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        uiView.isUserInteractionEnabled = isActive
        uiView.tool = makeTool()
        // The gesture handler captures mode/crayon/fit from the CURRENT
        // body evaluation — refresh it every update, or the coordinator
        // would clip tomorrow's strokes with yesterday's crayon.
        context.coordinator.onGesture = onGesture
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onGesture: onGesture)
    }

    /// `PKCanvasViewDelegate` bridge. `canvasViewDrawingDidChange` fires for
    /// programmatic assignment too — including this coordinator's own
    /// clear-after-handoff — so the clear is wrapped in a reentrancy flag.
    /// Because the live canvas is empty between gestures, any non-empty,
    /// non-clearing change IS the completed gesture: hand it up first, then
    /// clear; both land in the same SwiftUI transaction as the model update,
    /// so the ink moves from the live layer to the committed image without
    /// a visible gap.
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var onGesture: ([PKStroke]) -> Void
        private var isClearing = false

        init(onGesture: @escaping ([PKStroke]) -> Void) {
            self.onGesture = onGesture
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isClearing else { return }
            let strokes = canvasView.drawing.strokes
            guard !strokes.isEmpty else { return }
            onGesture(strokes)
            isClearing = true
            canvasView.drawing = PKDrawing()
            isClearing = false
        }
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
