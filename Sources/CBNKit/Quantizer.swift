import Foundation

/// The image after color quantization: every pixel points into a small
/// fixed palette. This is the first "color by numbers shaped" artifact in
/// the pipeline.
public struct QuantizedImage: Sendable {
    public var width: Int
    public var height: Int
    /// Palette index per pixel, row-major.
    public var labels: [Int]
    /// sRGB palette entries as (r, g, b) bytes.
    public var palette: [(r: UInt8, g: UInt8, b: UInt8)]
}

/// Flat-art color quantizer.
///
/// Strategy — deliberately NOT k-means: flat artwork consists of a handful
/// of exact fill colors plus anti-aliasing blends along edges. K-means would
/// average those blends into the fills and muddy them. Instead:
///
/// 1. Histogram every distinct color.
/// 2. Walk colors by frequency; each becomes a new palette seed unless it
///    sits within `mergeThreshold` ΔE of an existing seed (AA blends and
///    JPEG noise collapse into their parent fill).
/// 3. Cap the palette at `maxColors`, keeping the most-used seeds; every
///    remaining color maps to its perceptually nearest seed.
///
/// Seeds keep their exact original color — a dominant fill is never
/// averaged with its own halo, so imported art keeps its crispness (and a
/// well-quantized CBN image passes through nearly unchanged, our
/// idempotence property).
public enum Quantizer {
    /// ΔE below which two colors are treated as the same fill. Flat-art
    /// fills that a human would call "different colors" are rarely closer
    /// than ~15; AA noise is rarely farther than ~8. Tuned via `cbnc tune`.
    static let mergeThreshold = 10.0

    public static func quantize(_ image: RasterImage, maxColors: Int) -> QuantizedImage {
        precondition(maxColors >= 1)

        // 1. Histogram. Alpha is ignored: load() already composited onto white.
        var histogram: [UInt32: Int] = [:]
        let pixelCount = image.width * image.height
        image.rgba.withUnsafeBufferPointer { buffer in
            for i in 0..<pixelCount {
                let base = i * 4
                let key = UInt32(buffer[base]) << 16
                    | UInt32(buffer[base + 1]) << 8
                    | UInt32(buffer[base + 2])
                histogram[key, default: 0] += 1
            }
        }

        // 2. Frequency-ordered greedy seeding.
        let byFrequency = histogram.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
        }

        struct Seed {
            var key: UInt32
            var lab: LabColor
            var weight: Int
        }
        var seeds: [Seed] = []
        var assignment: [UInt32: Int] = [:] // color key → seed index

        for (key, count) in byFrequency {
            let lab = LabColor(
                red: UInt8((key >> 16) & 0xFF),
                green: UInt8((key >> 8) & 0xFF),
                blue: UInt8(key & 0xFF)
            )
            var nearestIndex = -1
            var nearestDelta = Double.infinity
            for (index, seed) in seeds.enumerated() {
                let delta = lab.deltaE(to: seed.lab)
                if delta < nearestDelta {
                    nearestDelta = delta
                    nearestIndex = index
                }
            }
            if nearestIndex >= 0, nearestDelta < mergeThreshold {
                assignment[key] = nearestIndex
                seeds[nearestIndex].weight += count
            } else {
                seeds.append(Seed(key: key, lab: lab, weight: count))
                assignment[key] = seeds.count - 1
            }
        }

        // 3. Cap the palette: keep the heaviest seeds, remap the rest to
        // their nearest survivor.
        let keptOrder = seeds.indices.sorted { seeds[$0].weight > seeds[$1].weight }
        let kept = Array(keptOrder.prefix(maxColors))
        var seedToPalette = [Int: Int]()
        for (paletteIndex, seedIndex) in kept.enumerated() {
            seedToPalette[seedIndex] = paletteIndex
        }
        for seedIndex in seeds.indices where seedToPalette[seedIndex] == nil {
            var nearestKept = kept[0]
            var nearestDelta = Double.infinity
            for keptIndex in kept {
                let delta = seeds[seedIndex].lab.deltaE(to: seeds[keptIndex].lab)
                if delta < nearestDelta {
                    nearestDelta = delta
                    nearestKept = keptIndex
                }
            }
            seedToPalette[seedIndex] = seedToPalette[nearestKept]
        }

        let palette = kept.map { seedIndex -> (r: UInt8, g: UInt8, b: UInt8) in
            let key = seeds[seedIndex].key
            return (
                r: UInt8((key >> 16) & 0xFF),
                g: UInt8((key >> 8) & 0xFF),
                b: UInt8(key & 0xFF)
            )
        }

        // 4. Label every pixel through the two-level map.
        var labels = [Int](repeating: 0, count: pixelCount)
        image.rgba.withUnsafeBufferPointer { buffer in
            for i in 0..<pixelCount {
                let base = i * 4
                let key = UInt32(buffer[base]) << 16
                    | UInt32(buffer[base + 1]) << 8
                    | UInt32(buffer[base + 2])
                labels[i] = seedToPalette[assignment[key]!]!
            }
        }

        return QuantizedImage(
            width: image.width,
            height: image.height,
            labels: labels,
            palette: palette
        )
    }
}
