import Foundation

/// Gives palette entries friendly, kid-readable names ("Deep Blue",
/// "Light Red") for legends and the paper exports. Best-effort: names only
/// need to be *distinguishable and sayable*, not colorimetrically profound.
enum ColorNamer {
    static func name(r: UInt8, g: UInt8, b: UInt8) -> String {
        let rf = Double(r) / 255
        let gf = Double(g) / 255
        let bf = Double(b) / 255
        let maxC = max(rf, gf, bf)
        let minC = min(rf, gf, bf)
        let delta = maxC - minC
        let lightness = (maxC + minC) / 2

        // Achromatic first.
        if delta < 0.08 {
            switch lightness {
            case ..<0.12: return "Black"
            case ..<0.35: return "Dark Gray"
            case ..<0.65: return "Gray"
            case ..<0.92: return "Light Gray"
            default: return "White"
            }
        }

        var hue: Double
        if maxC == rf {
            hue = ((gf - bf) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxC == gf {
            hue = (bf - rf) / delta + 2
        } else {
            hue = (rf - gf) / delta + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }

        let base: String
        switch hue {
        case ..<15: base = "Red"
        case ..<40: base = "Orange"
        case ..<65: base = "Yellow"
        case ..<160: base = "Green"
        case ..<200: base = "Teal"
        case ..<250: base = "Blue"
        case ..<290: base = "Purple"
        case ..<335: base = "Pink"
        default: base = "Red"
        }

        // Browns masquerade as dark orange.
        if base == "Orange", lightness < 0.4 { return "Brown" }

        switch lightness {
        case ..<0.3: return "Deep \(base)"
        case ..<0.7: return base
        default: return "Light \(base)"
        }
    }
}
