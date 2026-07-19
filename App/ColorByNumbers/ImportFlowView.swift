import CBNKit
import PhotosUI
import SwiftUI

/// The M4 "bring in a picture" flow — DESIGN.md's "co-op couch ritual" and
/// "The transformation experience" (amended at the M1 gate): PhotosPicker,
/// then ONE live preview of the actual picture as a coloring page, two knobs
/// with inferred + resettable defaults. Deliberately NOT preset cards and NOT
/// a reveal moment — both were cut at M1. Presented full-screen from
/// WorkshopView's "Bring in a picture" section, same "wholly separate room"
/// rationale as the Workshop door itself (StudioView.swift's `WorkshopDoor`
/// doc comment).
struct ImportFlowView: View {
    let library: CBNLibrary

    @Environment(\.dismiss) private var dismiss

    @State private var pickerItem: PhotosPickerItem?
    /// Presents the system picker. Auto-raised on first appearance: the
    /// parent already said "choose a photo" in the Workshop to get here —
    /// making them find and tap a second, identically-worded button inside
    /// this flow was one tap of pure friction (and ambiguous for the UI
    /// test driver to boot). Cancelling the picker lands on the flow's
    /// empty state, which offers the button again.
    @State private var pickerPresented = false
    /// The picked photo, already downscaled (`ImportSizing.maxLongEdge`) —
    /// the SAME raster every preview render and the final `Add to Studio`
    /// import both run against, per the M4 spec ("full downscaled raster,
    /// same one previewed").
    @State private var rasterImage: RasterImage?
    /// This image's one-time inferred starting point (`ImportInference`).
    /// Kept separately from the live knob values so the reset control has
    /// something to compare against and restore.
    @State private var inferred: ImportParameters?
    @State private var colorCount = ImportFlowView.colorRange.lowerBound
    @State private var minRegionMM = ImportFlowView.mmTiers[0]
    /// Starts EMPTY with "New Picture" as placeholder prompt, not as
    /// pre-filled text: pre-filled text must be selected-and-cleared before
    /// typing a real name — friction for the parent and a reliably flaky
    /// dance for the UI test. `addToStudio` falls back to "New Picture"
    /// when this is left blank, so the default still lands.
    @State private var title = ""

    @State private var previewImage: Image?
    /// True while a preview render is in flight — drives the calm 0.85
    /// opacity dip (DESIGN.md's calm contract: no spinners popping in and
    /// out). The previous preview stays fully visible underneath.
    @State private var isRecomputing = false
    /// True only once the actual pipeline is running — a strict subset of
    /// `isRecomputing`'s window (which also spans the ~300ms debounce
    /// sleep). Locks the knobs/reset control so a parent can't lose track
    /// of whether a tap registered (Kevin's report) without ALSO blocking
    /// the rapid-tap-to-target flow the debounce exists for: taps during
    /// the debounce window still land freely and coalesce into one render,
    /// same as before this lock existed; only the real ~1s pipeline run
    /// itself is what visibly locks the controls.
    @State private var isRenderingPipeline = false
    @State private var isAdding = false
    /// Bumped on every knob change; a completed render only takes effect if
    /// it's still the newest one requested (see `renderPreview`) — the
    /// "simple generation counter, stale results dropped" the spec asks for.
    @State private var previewGeneration = 0
    /// Owns the in-flight debounce sleep so a fast second knob tap can
    /// cancel it outright before the (comparatively expensive) pipeline
    /// even starts, rather than letting a superseded render run to
    /// completion just to be discarded.
    @State private var debounceTask: Task<Void, Never>?

    /// Colors knob range (M4 spec: 4...16 — wider than
    /// `ImportInference.colorCandidates`, which only seeds the inferred
    /// starting point; the live knob itself steps by one across the whole
    /// range).
    private static let colorRange = 4...16
    /// Smallest-piece mm tiers (M4 spec, matching
    /// `ImportInference.minRegionMMTiers` by value — duplicated rather than
    /// shared because that array is `package`-visibility inside CBNKit, not
    /// reachable from the app target).
    private static let mmTiers: [Double] = [3, 5, 8, 12]
    private static let previewDebounceNanoseconds: UInt64 = 300_000_000

    private var hasPicture: Bool { rasterImage != nil }

    private var isAtInferred: Bool {
        guard let inferred else { return true }
        return colorCount == inferred.colorCount && minRegionMM == inferred.minRegionMM
    }

    private var mmTierIndex: Int {
        Self.mmTiers.firstIndex(of: minRegionMM) ?? 0
    }

    private var previewAspectRatio: Double {
        guard let rasterImage, rasterImage.height > 0 else { return 4.0 / 3.0 }
        return Double(rasterImage.width) / Double(rasterImage.height)
    }

    var body: some View {
        ZStack {
            DeskStyle.deskColor.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    header

                    PreviewCard(image: previewImage, isRecomputing: isRecomputing, aspectRatio: previewAspectRatio)
                        .frame(maxWidth: 560)
                        .overlay {
                            if !hasPicture {
                                Button {
                                    pickerPresented = true
                                } label: {
                                    Text("Choose a photo")
                                        .font(.system(.body, design: .rounded, weight: .medium))
                                        .foregroundStyle(DeskStyle.inkColor)
                                        .padding(.horizontal, 24)
                                        .padding(.vertical, 14)
                                        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.9)))
                                }
                                .buttonStyle(.plain)
                            }
                        }

                    // Gated on the INFERENCE being done, not just the
                    // picture existing: the knobs' starting values ARE the
                    // inferred ones, and showing them earlier (initialized
                    // to arbitrary floor values) invites the parent to
                    // start adjusting — only to have the inference land a
                    // moment later and clobber their taps. No controls
                    // until the suggestion exists; the preview card carries
                    // the "working on it" state alone.
                    if inferred != nil {
                        knobsRow
                        resetControl
                        namingRow
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .photosPicker(isPresented: $pickerPresented, selection: $pickerItem, matching: .images)
        .onAppear {
            if rasterImage == nil {
                pickerPresented = true
            }
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await loadPickedImage(newItem) }
        }
    }

    private var header: some View {
        HStack {
            Text("Bring in a picture")
                .font(.system(.title, design: .rounded, weight: .semibold))
                .foregroundStyle(DeskStyle.inkColor)
            Spacer()
            // A quiet way to swap photos without leaving the flow — the kid
            // points at a different one, the parent taps here, same
            // `$pickerItem` binding re-runs the whole load/infer/preview
            // sequence below via `onChange`.
            if hasPicture {
                Button {
                    pickerPresented = true
                } label: {
                    Text("Choose a different photo")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(DeskStyle.inkColor.opacity(0.7))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
            }
            CloseControl { dismiss() }
        }
    }

    private var knobsRow: some View {
        HStack(spacing: 24) {
            StepperRow(
                label: "Colors",
                valueText: "\(colorCount) colors",
                decreaseLabel: "Fewer colors",
                increaseLabel: "More colors",
                canDecrease: colorCount > Self.colorRange.lowerBound && !isRenderingPipeline,
                canIncrease: colorCount < Self.colorRange.upperBound && !isRenderingPipeline,
                onDecrease: decreaseColorCount,
                onIncrease: increaseColorCount
            )
            StepperRow(
                label: "Smallest piece",
                valueText: "\(Int(minRegionMM)) mm",
                decreaseLabel: "Smaller pieces",
                increaseLabel: "Bigger pieces",
                canDecrease: mmTierIndex > 0 && !isRenderingPipeline,
                canIncrease: mmTierIndex < Self.mmTiers.count - 1 && !isRenderingPipeline,
                onDecrease: decreaseMinRegion,
                onIncrease: increaseMinRegion
            )
        }
    }

    /// Visible only when the parent has actually moved a knob (M4 spec) —
    /// the app never recommends mid-flow, so this is the only way back to
    /// the inferred starting point, and it hides itself the instant there's
    /// nothing to reset.
    @ViewBuilder
    private var resetControl: some View {
        if !isAtInferred {
            Button(action: resetToInferred) {
                Text("Back to suggested")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(DeskStyle.inkColor.opacity(0.6))
                    .underline()
            }
            .buttonStyle(.plain)
            .disabled(isRenderingPipeline)
            .opacity(isRenderingPipeline ? 0.4 : 1)
        }
    }

    private var namingRow: some View {
        HStack(spacing: 16) {
            TextField("New Picture", text: $title)
                .accessibilityIdentifier("Title")
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(DeskStyle.inkColor)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Capsule(style: .continuous).fill(Color.white.opacity(0.7)))
                .frame(maxWidth: 280)

            Button(action: addToStudio) {
                Text("Add to Studio")
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(Capsule(style: .continuous).fill(DeskStyle.inkColor))
            }
            .buttonStyle(.plain)
            // Disabled until a picture exists (M4 spec) — `isAdding` also
            // guards a double-tap from firing the import twice.
            .disabled(!hasPicture || isAdding)
            .opacity(hasPicture ? 1 : 0.4)
        }
    }

    // MARK: - Picking

    /// Decodes the picked photo, downscales it, infers a starting point, and
    /// kicks off the first preview render. Everything past the initial
    /// `loadTransferable` (itself already async/off-main) runs inside
    /// `Task.detached` — `RasterImage` and `ImportParameters` are `Sendable`
    /// (CBNKit doc comments), so this never touches the main actor until the
    /// results land.
    @MainActor
    private func loadPickedImage(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            // No error UI (DESIGN.md's calm contract has no room for a
            // failure dialog) — just leave the flow exactly as it was, and
            // clear the selection so picking the same photo again still
            // fires `onChange`.
            pickerItem = nil
            return
        }

        let raster = await Task.detached(priority: .userInitiated) { () -> RasterImage? in
            guard let cgImage = ImportFlowView.downscaledCGImage(from: data) else { return nil }
            return try? RasterImage(cgImage: cgImage)
        }.value

        guard let raster else {
            pickerItem = nil
            return
        }

        rasterImage = raster
        previewImage = nil

        let inferredParameters = await Task.detached(priority: .userInitiated) {
            ImportInference.inferredParameters(for: raster)
        }.value

        inferred = inferredParameters
        colorCount = inferredParameters.colorCount
        minRegionMM = inferredParameters.minRegionMM
        schedulePreviewUpdate()
    }

    /// Decodes `data` and, if its long edge exceeds `ImportSizing.maxLongEdge`,
    /// redraws it into a smaller CG-interpolated bitmap — a phone photo can
    /// be several thousand pixels on a side, which would make every knob
    /// change noticeably slower to re-preview for no visible benefit (the
    /// pipeline's own region floor is mm-based and already coarser than
    /// this resolution).
    /// `nonisolated`: `ImportFlowView` is a SwiftUI `View` and therefore
    /// implicitly MainActor-isolated, but this is a pure `Data -> CGImage?`
    /// function with no view state to touch — it needs to be callable from
    /// inside `Task.detached` in `loadPickedImage`, off the main actor.
    private nonisolated static func downscaledCGImage(from data: Data) -> CGImage? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let longEdge = max(cgImage.width, cgImage.height)
        guard longEdge > ImportSizing.maxLongEdge else { return cgImage }

        let scale = Double(ImportSizing.maxLongEdge) / Double(longEdge)
        let width = max(1, Int((Double(cgImage.width) * scale).rounded()))
        let height = max(1, Int((Double(cgImage.height) * scale).rounded()))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return cgImage }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? cgImage
    }

    // MARK: - Knobs

    private func decreaseColorCount() {
        guard colorCount > Self.colorRange.lowerBound else { return }
        colorCount -= 1
        schedulePreviewUpdate()
    }

    private func increaseColorCount() {
        guard colorCount < Self.colorRange.upperBound else { return }
        colorCount += 1
        schedulePreviewUpdate()
    }

    private func decreaseMinRegion() {
        let index = mmTierIndex
        guard index > 0 else { return }
        minRegionMM = Self.mmTiers[index - 1]
        schedulePreviewUpdate()
    }

    private func increaseMinRegion() {
        let index = mmTierIndex
        guard index < Self.mmTiers.count - 1 else { return }
        minRegionMM = Self.mmTiers[index + 1]
        schedulePreviewUpdate()
    }

    private func resetToInferred() {
        guard let inferred else { return }
        colorCount = inferred.colorCount
        minRegionMM = inferred.minRegionMM
        schedulePreviewUpdate()
    }

    // MARK: - Live preview

    /// Debounces ~300ms so a rapid run of stepper taps only pays for one
    /// pipeline run, not one per tap — cancelling the prior sleep outright
    /// (rather than letting it complete and then discarding the result) is
    /// what keeps a fast tapper from ever waiting on stale work.
    private func schedulePreviewUpdate() {
        guard let rasterImage else { return }
        debounceTask?.cancel()
        previewGeneration += 1
        let generation = previewGeneration
        let parameters = ImportParameters(colorCount: colorCount, minRegionMM: minRegionMM, detail: 1.0)
        isRecomputing = true
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: Self.previewDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await renderPreview(image: rasterImage, parameters: parameters, generation: generation)
        }
    }

    /// Runs the actual pipeline + outline render off-main, then applies the
    /// result only if `generation` is still the newest one requested — the
    /// generation counter is a second guard behind the debounce-cancel
    /// above, catching the (rarer) case where two renders end up briefly
    /// in flight at once.
    private func renderPreview(image: RasterImage, parameters: ImportParameters, generation: Int) async {
        isRenderingPipeline = true
        let rendered = await Task.detached(priority: .userInitiated) { () -> Image? in
            let template = ImportPipeline.importTemplate(from: image, title: "", parameters: parameters)
            guard let cgImage = TemplateRenderer.render(template, mode: .outline, scale: 1) else { return nil }
            return Image(decorative: cgImage, scale: 1)
        }.value
        isRenderingPipeline = false

        guard generation == previewGeneration else { return }
        if let rendered {
            previewImage = rendered
        }
        isRecomputing = false
    }

    // MARK: - Adding

    /// Runs the pipeline once more at the CURRENT knob values against the
    /// same downscaled raster the preview has been showing all along, adds
    /// it to the library, and dismisses back to the Workshop. `StudioView`'s
    /// own `.onAppear` reload (StudioView.swift) is what makes the new card
    /// show up once this cover closes — nothing to reinvent here.
    private func addToStudio() {
        guard let rasterImage else { return }
        isAdding = true
        let parameters = ImportParameters(colorCount: colorCount, minRegionMM: minRegionMM, detail: 1.0)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = trimmedTitle.isEmpty ? "New Picture" : trimmedTitle

        Task {
            let template = await Task.detached(priority: .userInitiated) {
                ImportPipeline.importTemplate(from: rasterImage, title: resolvedTitle, parameters: parameters)
            }.value
            do {
                try library.add(template)
            } catch {
                // A device I/O failure, not a per-photo quirk — matches
                // ColorByNumbersApp's own debug-loud/release-silent pattern
                // for library writes gone wrong.
                assertionFailure("Could not add imported template: \(error)")
            }
            dismiss()
        }
    }
}

/// Downscale sizing for a picked photo, isolated as a clearly-named constant
/// per the M4 spec rather than a bare literal at the call site.
enum ImportSizing {
    static let maxLongEdge = 1200
}

/// The live preview's white page card — same material recipe as
/// StudioView's `TemplateCard` (white rounded rect, soft shadow). Shows the
/// most recent successful render even while a newer one is computing,
/// dipped to 0.85 opacity rather than replaced by a spinner (DESIGN.md's
/// calm contract) — one dip, commented once, reused everywhere this needs
/// to say "working on it" without popping anything in or out.
private struct PreviewCard: View {
    let image: Image?
    let isRecomputing: Bool
    let aspectRatio: Double

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DeskStyle.cardCornerRadius, style: .continuous)
                .fill(Color.white)
                .shadow(
                    color: DeskStyle.shadowColor,
                    radius: DeskStyle.shadowRadius,
                    x: 0,
                    y: DeskStyle.shadowYOffset
                )

            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(16)
                    .opacity(isRecomputing ? 0.85 : 1)
            }
            // No image yet: the card stays blank. ImportFlowView already
            // overlays a "Choose a photo" button dead center for this same
            // state — a second, separate invitation ("Pick a photo to see
            // it as a coloring page.") used to render right underneath it,
            // and the two centered texts overlapped illegibly (Kevin's
            // report). One call-to-action is enough.
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
    }
}

/// One knob's row: minus/value/plus in capsule material, generous 44pt
/// targets (this is grown-up space — same "standard, not small-finger" call
/// `CloseControl` already makes in WorkshopGateView.swift). The value itself
/// is plain `Text`, so VoiceOver reads it for free ("value readable" per the
/// M4 spec) without any extra accessibility wiring.
private struct StepperRow: View {
    let label: String
    let valueText: String
    let decreaseLabel: String
    let increaseLabel: String
    let canDecrease: Bool
    let canIncrease: Bool
    let onDecrease: () -> Void
    let onIncrease: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(label)
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(DeskStyle.inkColor.opacity(0.7))

            HStack(spacing: 20) {
                StepperButton(systemName: "minus", accessibilityLabel: decreaseLabel, enabled: canDecrease, action: onDecrease)

                Text(valueText)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(DeskStyle.inkColor)
                    .frame(minWidth: 96)

                StepperButton(systemName: "plus", accessibilityLabel: increaseLabel, enabled: canIncrease, action: onIncrease)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.7)))
    }
}

private struct StepperButton: View {
    let systemName: String
    let accessibilityLabel: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DeskStyle.inkColor)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.white.opacity(0.9)))
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
        .accessibilityLabel(accessibilityLabel)
    }
}

#if DEBUG
#Preview(traits: .landscapeLeft) {
    ImportFlowView(library: previewLibrary(seeding: [.previewSample]))
}
#endif
