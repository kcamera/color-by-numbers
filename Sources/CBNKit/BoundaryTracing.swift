import Foundation

/// Extracts each region's boundaries as polygons: one outer contour, plus
/// one contour per hole.
///
/// Holes are traced explicitly and filled with the even-odd rule. The
/// earlier painter's-order-only design (largest region drawn first, nested
/// regions painted over it) could not represent real line art: an eye
/// outline with an attached pupil is a single connected region that both
/// *surrounds* the eye white and has a piece *inside* it — no draw order
/// is correct for such a region, but outer-ring-plus-holes paints exactly
/// its own pixels regardless of order.
public enum BoundaryTracer {
    /// Radial-sweep contour tracing (Moore neighborhood, stop on returning
    /// to the start pixel) of the region's outer contour, returning
    /// pixel-center coordinates. The half-pixel error versus true pixel
    /// edges is invisible at template scale and vanishes entirely under
    /// path simplification.
    public static func traceOuterBoundary(of region: Int, in map: RegionMap) -> [CBNPoint] {
        let width = map.width
        let ids = map.regionIDs

        // Start pixel: topmost, then leftmost — its west neighbor is
        // guaranteed outside, giving a valid initial backtrack direction.
        guard let startIndex = ids.firstIndex(of: region) else { return [] }
        return mooreTrace(
            startX: startIndex % width,
            startY: startIndex / width,
            width: width,
            height: map.height
        ) { x, y in
            x >= 0 && x < width && y >= 0 && y < map.height && ids[y * width + x] == region
        }
    }

    /// Traces the boundary of every hole in `region` — each connected
    /// pocket of non-region pixels fully enclosed by it. Returned contours
    /// follow hole-pixel centers, which coincide with the outer-boundary
    /// trace of whatever regions fill the pocket, so fills meet exactly.
    ///
    /// `bounds` is the region's pixel bounding box (see
    /// `RegionExtractor.boundingBoxes`), used to keep the flood fill local.
    /// The complement is flooded with 8-connectivity — the topological dual
    /// of the 4-connectivity regions are built with — so a diagonal pinch
    /// in the region wall correctly reads as "leaks outside", not a hole.
    public static func traceHoleBoundaries(
        of region: Int,
        in map: RegionMap,
        bounds: (minX: Int, minY: Int, maxX: Int, maxY: Int)
    ) -> [[CBNPoint]] {
        // A region needs at least a 3×3 bounding box to enclose anything.
        guard bounds.maxX - bounds.minX >= 2, bounds.maxY - bounds.minY >= 2 else { return [] }

        // Local grid: the bounding box plus a one-cell pad so the outside
        // flood can wrap around the region from any side.
        let localWidth = bounds.maxX - bounds.minX + 3
        let localHeight = bounds.maxY - bounds.minY + 3
        let offsetX = bounds.minX - 1
        let offsetY = bounds.minY - 1

        // Cell states: 0 = unknown, 1 = region, 2 = outside, 3+ = hole id.
        var state = [Int](repeating: 0, count: localWidth * localHeight)
        for y in bounds.minY...bounds.maxY {
            let rowBase = y * map.width
            let localBase = (y - offsetY) * localWidth - offsetX
            for x in bounds.minX...bounds.maxX where map.regionIDs[rowBase + x] == region {
                state[localBase + x] = 1
            }
        }

        // Flood "outside" from the pad corner over every non-region cell,
        // 8-connected.
        var stack = [0]
        state[0] = 2
        while let cell = stack.popLast() {
            let cx = cell % localWidth
            let cy = cell / localWidth
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = cx + dx, ny = cy + dy
                    guard nx >= 0, nx < localWidth, ny >= 0, ny < localHeight else { continue }
                    let n = ny * localWidth + nx
                    if state[n] == 0 {
                        state[n] = 2
                        stack.append(n)
                    }
                }
            }
        }

        // Whatever is still unknown is enclosed: label each hole component
        // (8-connected, matching the outside flood) and trace it. Row-major
        // scan order means the first cell found in a component is its
        // topmost-then-leftmost pixel — a valid Moore start.
        var contours: [[CBNPoint]] = []
        var nextHole = 3
        for cell in 0..<state.count where state[cell] == 0 {
            let hole = nextHole
            nextHole += 1
            state[cell] = hole
            var fill = [cell]
            while let c = fill.popLast() {
                let cx = c % localWidth
                let cy = c / localWidth
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = cx + dx, ny = cy + dy
                        guard nx >= 0, nx < localWidth, ny >= 0, ny < localHeight else { continue }
                        let n = ny * localWidth + nx
                        if state[n] == 0 {
                            state[n] = hole
                            fill.append(n)
                        }
                    }
                }
            }

            let contour = mooreTrace(
                startX: cell % localWidth,
                startY: cell / localWidth,
                width: localWidth,
                height: localHeight
            ) { x, y in
                x >= 0 && x < localWidth && y >= 0 && y < localHeight
                    && state[y * localWidth + x] == hole
            }
            contours.append(contour.map {
                CBNPoint(x: $0.x + Double(offsetX), y: $0.y + Double(offsetY))
            })
        }
        return contours
    }

    /// The shared radial-sweep core. `startX/startY` must be the component's
    /// topmost-then-leftmost pixel so the west neighbor is guaranteed
    /// outside (the initial backtrack direction).
    private static func mooreTrace(
        startX: Int,
        startY: Int,
        width: Int,
        height: Int,
        isInside: (Int, Int) -> Bool
    ) -> [CBNPoint] {
        // Moore neighborhood in clockwise order starting from west.
        let neighborhood: [(dx: Int, dy: Int)] = [
            (-1, 0), (-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1),
        ]

        var contour: [CBNPoint] = []
        var current = (x: startX, y: startY)
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
        } while !(current.x == startX && current.y == startY) && contour.count <= width * height

        return contour
    }
}
