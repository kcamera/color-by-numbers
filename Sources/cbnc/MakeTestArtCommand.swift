import ArgumentParser
import CBNKit
import CoreGraphics
import Foundation

/// Generates the deterministic synthetic test-art corpus. Synthetic rather
/// than downloaded: fully license-clean, reproducible byte-for-byte, and
/// each image stresses one specific pipeline behavior. Real public-domain
/// art can join TestArt/ alongside these at any time.
struct MakeTestArtCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "make-testart",
        abstract: "Generate the synthetic TestArt corpus."
    )

    @Option(name: .shortAndLong, help: "Output directory.")
    var output: String = "TestArt"

    @Option(help: "Path to the Little Sailboat sample template.")
    var sample: String = "Samples/LittleSailboat/template.json"

    func run() throws {
        let outputURL = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        try write(banner(), name: "banner.png", to: outputURL)
        try write(rings(), name: "rings.png", to: outputURL)
        try write(confetti(), name: "confetti.png", to: outputURL)

        // The sailboat: our own sample rendered filled WITH anti-aliasing —
        // the idempotence reference (CBN-shaped input should survive the
        // pipeline roughly unchanged) and the realistic AA-halo test.
        let template = try TemplateIO.read(sample)
        guard let boat = TemplateRenderer.render(template, mode: .filled, scale: 0.5) else {
            throw ValidationError("Could not render \(sample)")
        }
        try RasterImage.writePNG(boat, to: outputURL.appendingPathComponent("sailboat.png"))

        print("TestArt corpus written to \(outputURL.path): banner, rings, confetti, sailboat")
    }

    private func write(_ image: CGImage?, name: String, to directory: URL) throws {
        guard let image else { throw ValidationError("Could not draw \(name)") }
        try RasterImage.writePNG(image, to: directory.appendingPathComponent(name))
    }

    private func makeContext(_ width: Int, _ height: Int, antialias: Bool) -> CGContext? {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setShouldAntialias(antialias)
        return context
    }

    private func fill(_ context: CGContext, _ r: Double, _ g: Double, _ b: Double) {
        context.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
    }

    /// Hard-edged color blocks, no AA: the trivial base case. Exact colors,
    /// exact region counts — if this ever regresses, the pipeline is
    /// fundamentally broken.
    private func banner() -> CGImage? {
        guard let ctx = makeContext(600, 400, antialias: false) else { return nil }
        fill(ctx, 0.95, 0.90, 0.80); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        fill(ctx, 0.75, 0.25, 0.20); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 400))
        fill(ctx, 0.20, 0.45, 0.70); ctx.fill(CGRect(x: 400, y: 0, width: 200, height: 400))
        fill(ctx, 0.95, 0.80, 0.30); ctx.fill(CGRect(x: 250, y: 150, width: 100, height: 100))
        return ctx.makeImage()
    }

    /// Concentric circles with AA: the nesting / painter's-order test, plus
    /// anti-aliasing halos between strongly contrasting rings.
    private func rings() -> CGImage? {
        guard let ctx = makeContext(500, 500, antialias: true) else { return nil }
        fill(ctx, 0.93, 0.93, 0.88); ctx.fill(CGRect(x: 0, y: 0, width: 500, height: 500))
        let colors: [(Double, Double, Double)] = [
            (0.20, 0.40, 0.65), (0.90, 0.85, 0.60), (0.70, 0.30, 0.30), (0.30, 0.55, 0.35),
        ]
        for (index, color) in colors.enumerated() {
            let inset = CGFloat(50 + index * 55)
            fill(ctx, color.0, color.1, color.2)
            ctx.fillEllipse(in: CGRect(x: inset, y: inset, width: 500 - inset * 2, height: 500 - inset * 2))
        }
        return ctx.makeImage()
    }

    /// Many small dots on a field: the small-region-merge stress test.
    /// Deterministic via a fixed-seed LCG — the corpus must be
    /// byte-reproducible.
    private func confetti() -> CGImage? {
        guard let ctx = makeContext(600, 400, antialias: true) else { return nil }
        fill(ctx, 0.88, 0.92, 0.90); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        fill(ctx, 0.45, 0.60, 0.80)
        ctx.fillEllipse(in: CGRect(x: 150, y: 100, width: 300, height: 200))

        var state: UInt64 = 0x5EED_CB01
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 33) / Double(UInt32.max)
        }
        let dotColors: [(Double, Double, Double)] = [
            (0.75, 0.25, 0.20), (0.95, 0.80, 0.30), (0.30, 0.55, 0.35),
        ]
        for i in 0..<120 {
            let color = dotColors[i % dotColors.count]
            fill(ctx, color.0, color.1, color.2)
            let diameter = 3 + next() * 6 // 3–9px: all below sane min-region size
            ctx.fillEllipse(in: CGRect(
                x: next() * 580, y: next() * 380, width: diameter, height: diameter
            ))
        }
        return ctx.makeImage()
    }
}
