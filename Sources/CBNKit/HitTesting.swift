import Foundation

extension PolygonGeometry {
    /// Even-odd containment across a region's rings: inside the outer ring
    /// an odd number of ring-crossings deep. Equivalent to XOR of per-ring
    /// parity — a point inside the outer ring and inside one hole is out.
    public static func containsEvenOdd(_ point: CBNPoint, outer: [CBNPoint], holes: [[CBNPoint]]) -> Bool {
        var inside = contains(point, in: outer)
        for hole in holes where contains(point, in: hole) {
            inside.toggle()
        }
        return inside
    }
}

extension CBNTemplate {
    /// The region a tap at `point` (template coordinates) hits: the
    /// TOPMOST one in painter's order — regions is stored back-to-front,
    /// so scan from the END of the array and return the first region whose
    /// even-odd fill (path + holes) contains the point.
    public func region(at point: CBNPoint) -> CBNRegion? {
        for region in regions.reversed() {
            if PolygonGeometry.containsEvenOdd(point, outer: region.path, holes: region.holes) {
                return region
            }
        }
        return nil
    }
}
