import Foundation
import Testing
@testable import CBNKit

// MARK: - Synthetic scenes

/// A flat 3-color scene (sky/ground/sun) — with only 3 real colors,
/// quantizing to the fewest candidate (6) loses essentially nothing, so the
/// fidelity elbow should land at the floor of the candidate grid.
private func threeColorScene() -> RasterImage {
    let width = 60
    let height = 60
    var rgba = [UInt8]()
    rgba.reserveCapacity(width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let color: (UInt8, UInt8, UInt8)
            if y < 20 {
                color = (135, 206, 235) // sky
            } else if x > width - 15 && y < 35 {
                color = (255, 220, 60) // sun
            } else {
                color = (80, 160, 70) // ground
            }
            rgba.append(contentsOf: [color.0, color.1, color.2, 255])
        }
    }
    return RasterImage(width: width, height: height, rgba: rgba)
}

/// A many-flat-color scene: a grid of distinctly-hued blocks, spread far
/// enough apart in Lab space (see `hsvToRGB`'s spacing) that quantizing to
/// few colors genuinely loses information — unlike `threeColorScene`, the
/// fidelity curve should keep improving well past the fewest candidate.
private func manyColorScene() -> RasterImage {
    let blockSize = 12
    let columns = 6
    let rowCount = 3 // 18 distinct hues, evenly spread around the wheel
    let width = blockSize * columns
    let height = blockSize * rowCount
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    var index = 0
    for row in 0..<rowCount {
        for col in 0..<columns {
            let hue = Double(index) / Double(columns * rowCount)
            let color = hsvToRGB(h: hue, s: 0.9, v: 0.9)
            for dy in 0..<blockSize {
                for dx in 0..<blockSize {
                    let x = col * blockSize + dx
                    let y = row * blockSize + dy
                    let base = (y * width + x) * 4
                    rgba[base] = color.0
                    rgba[base + 1] = color.1
                    rgba[base + 2] = color.2
                    rgba[base + 3] = 255
                }
            }
            index += 1
        }
    }
    return RasterImage(width: width, height: height, rgba: rgba)
}

private func hsvToRGB(h: Double, s: Double, v: Double) -> (UInt8, UInt8, UInt8) {
    let i = Int(h * 6) % 6
    let f = h * 6 - Double(Int(h * 6))
    let p = v * (1 - s)
    let q = v * (1 - f * s)
    let t = v * (1 - (1 - f) * s)
    let (r, g, b): (Double, Double, Double)
    switch i {
    case 0: (r, g, b) = (v, t, p)
    case 1: (r, g, b) = (q, v, p)
    case 2: (r, g, b) = (p, v, t)
    case 3: (r, g, b) = (p, q, v)
    case 4: (r, g, b) = (t, p, v)
    default: (r, g, b) = (v, p, q)
    }
    return (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))
}

// MARK: - ImportInference

@Test func inferredParametersOnFlatFewColorSceneInfersFewColors() {
    let parameters = ImportInference.inferredParameters(for: threeColorScene())
    #expect(parameters.colorCount <= 6)
    // Detail stays pinned regardless of the image — dormant parameter, see
    // ImportParameters.detail.
    #expect(parameters.detail == 1.0)
}

@Test func inferredParametersOnManyColorSceneInfersMoreColorsThanFlatScene() {
    let flat = ImportInference.inferredParameters(for: threeColorScene())
    let many = ImportInference.inferredParameters(for: manyColorScene())
    #expect(many.colorCount > flat.colorCount)
}

/// Same image in, same parameters out — no hidden randomness (dictionary
/// iteration order, concurrency, etc.) in the inference path.
@Test func inferredParametersIsDeterministic() {
    let image = manyColorScene()
    let first = ImportInference.inferredParameters(for: image)
    let second = ImportInference.inferredParameters(for: image)
    #expect(first == second)
}
