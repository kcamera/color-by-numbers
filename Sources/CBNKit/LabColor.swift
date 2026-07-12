import Foundation

/// CIELAB color value. The pipeline quantizes in Lab rather than RGB because
/// Euclidean distance in Lab approximates how *different two colors look*,
/// which is the question quantization is actually asking.
struct LabColor: Sendable {
    var l: Double
    var a: Double
    var b: Double

    /// sRGB bytes → Lab, D65 white point.
    init(red: UInt8, green: UInt8, blue: UInt8) {
        func linearize(_ channel: UInt8) -> Double {
            let c = Double(channel) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = linearize(red)
        let g = linearize(green)
        let bl = linearize(blue)

        // Linear sRGB → XYZ (D65)
        let x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * bl
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * bl
        let z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * bl

        // XYZ → Lab
        func f(_ t: Double) -> Double {
            t > 0.008856 ? cbrt(t) : (7.787 * t) + (16.0 / 116.0)
        }
        let fx = f(x / 0.95047)
        let fy = f(y / 1.0)
        let fz = f(z / 1.08883)

        l = 116 * fy - 16
        a = 500 * (fx - fy)
        b = 200 * (fy - fz)
    }

    /// CIE76 ΔE — plain Euclidean distance in Lab. Good enough for telling
    /// "same fill color" from "different fill color" in flat artwork; the
    /// fancier ΔE2000 isn't worth its complexity here.
    func deltaE(to other: LabColor) -> Double {
        let dl = l - other.l
        let da = a - other.a
        let db = b - other.b
        return (dl * dl + da * da + db * db).squareRoot()
    }
}
