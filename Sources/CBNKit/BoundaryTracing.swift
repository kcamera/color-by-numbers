import Foundation

/// Extracts each region's outer boundary as a polygon.
///
/// Holes are handled by painter's order, not by polygon holes: regions are
/// emitted largest-first, so a sky containing a sun is drawn as a full sky
/// polygon with the sun's polygon painted over it. That keeps the document
/// format (and the M2 tap-to-fill hit testing) radically simpler than
/// even-odd path fills — hit testing walks the region list back-to-front.
public enum BoundaryTracer {
    /// Radial-sweep contour tracing (Moore neighborhood, stop on returning
    /// to the start pixel) of the region's outer contour, returning
    /// pixel-center coordinates. The half-pixel error versus true pixel
    /// edges is invisible at template scale and vanishes entirely under
    /// path simplification.
    public static func traceOuterBoundary(of region: Int, in map: RegionMap) -> [CBNPoint] {
        let width = map.width
        let height = map.height
        let ids = map.regionIDs

        func isInside(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && x < width && y >= 0 && y < height && ids[y * width + x] == region
        }

        // Start pixel: topmost, then leftmost — its west neighbor is
        // guaranteed outside, giving a valid initial backtrack direction.
        var start: (x: Int, y: Int)? = nil
        outer: for y in 0..<height {
            for x in 0..<width where ids[y * width + x] == region {
                start = (x, y)
                break outer
            }
        }
        guard let start else { return [] }

        // Moore neighborhood in clockwise order starting from west.
        let neighborhood: [(dx: Int, dy: Int)] = [
            (-1, 0), (-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1),
        ]

        var contour: [CBNPoint] = []
        var current = start
        // Index into `neighborhood` of the backtrack direction (where we
        // "came from"); scanning clockwise from just past it finds the next
        // boundary pixel. Initial backtrack is west (index 0).
        var backtrack = 0

        repeat {
            contour.append(CBNPoint(x: Double(current.x), y: Double(current.y)))
            var found = false
            for step in 1...8 {
                let direction = (backtrack + step) % 8
                let candidate = (
                    x: current.x + neighborhood[direction].dx,
                    y: current.y + neighborhood[direction].dy
                )
                if isInside(candidate.x, candidate.y) {
                    // Radial sweep: from the new pixel, the next clockwise
                    // scan starts just past the direction pointing back at
                    // the pixel we came from.
                    backtrack = (direction + 4) % 8
                    current = candidate
                    found = true
                    break
                }
            }
            if !found { break } // isolated single pixel
        } while !(current.x == start.x && current.y == start.y) && contour.count <= width * height

        return contour
    }
}
