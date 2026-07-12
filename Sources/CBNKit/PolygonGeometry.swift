import Foundation

/// Pure-geometry helpers for the closed polygon rings used by
/// `CBNRegion.path` (see CBNTemplate.swift). All rings are assumed to be
/// simple polygons without holes, encoded as an open list of vertices where
/// the last point implicitly connects back to the first.
///
/// Every function here handles degenerate input (fewer than 3 points)
/// without crashing, since malformed or in-progress pipeline data can
/// legitimately produce such rings before validation rejects them.
public enum PolygonGeometry {
    /// Signed area via the shoelace formula. Positive = counter-clockwise in
    /// a y-up frame (our templates are y-down screen coords, so CW there).
    public static func signedArea(of ring: [CBNPoint]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var sum = 0.0
        let count = ring.count
        for i in 0..<count {
            let p0 = ring[i]
            let p1 = ring[(i + 1) % count]
            sum += p0.x * p1.y - p1.x * p0.y
        }
        return sum / 2
    }

    /// Ray-casting point-in-polygon. Points exactly on an edge may return
    /// either value; callers never depend on edge cases.
    public static func contains(_ point: CBNPoint, in ring: [CBNPoint]) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let pi = ring[i]
            let pj = ring[j]
            if (pi.y > point.y) != (pj.y > point.y) {
                let xCrossing = (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x
                if point.x < xCrossing {
                    inside.toggle()
                }
            }
            j = i
        }
        return inside
    }

    /// Ramer–Douglas–Peucker simplification of a CLOSED ring (last point
    /// implicitly connects to first; input does NOT repeat the first point).
    /// tolerance is the max perpendicular deviation. Must never return fewer
    /// than 3 points for a valid input ring.
    ///
    /// A closed ring can't be fed straight into textbook RDP (which needs a
    /// fixed start/end), so we pick the two vertices farthest apart, split
    /// the ring into two open chains between them, simplify each chain with
    /// standard RDP, and rejoin — matching the approach commonly used for
    /// closed-loop simplification.
    public static func simplify(_ ring: [CBNPoint], tolerance: Double) -> [CBNPoint] {
        guard ring.count > 3 else { return ring }

        var maxDistanceSquared = -1.0
        var iFar = 0
        var jFar = 1
        for i in 0..<ring.count {
            for j in (i + 1)..<ring.count {
                let dx = ring[i].x - ring[j].x
                let dy = ring[i].y - ring[j].y
                let distanceSquared = dx * dx + dy * dy
                if distanceSquared > maxDistanceSquared {
                    maxDistanceSquared = distanceSquared
                    iFar = i
                    jFar = j
                }
            }
        }

        let chain1 = Array(ring[iFar...jFar])
        let chain2 = Array(ring[jFar...]) + Array(ring[0...iFar])

        let simplified1 = reduceChain(chain1, tolerance: tolerance)
        let simplified2 = reduceChain(chain2, tolerance: tolerance)

        var result = Array(simplified1.dropLast()) + Array(simplified2.dropLast())

        if result.count < 3 {
            // An extremely flat ring can collapse past a valid polygon (down
            // to the two split points). Rescue it by adding back whichever
            // original vertex deviates most from the iFar–jFar line, which
            // guarantees a non-degenerate triangle.
            var bestIndex = -1
            var bestDistance = -1.0
            for k in 0..<ring.count where k != iFar && k != jFar {
                let distance = perpendicularDistance(ring[k], from: ring[iFar], to: ring[jFar])
                if distance > bestDistance {
                    bestDistance = distance
                    bestIndex = k
                }
            }
            result = bestIndex >= 0 ? [ring[iFar], ring[bestIndex], ring[jFar]] : ring
        }

        return result
    }

    /// Pole of inaccessibility: the interior point farthest from every edge,
    /// i.e. the visual center — used to place a region's number label.
    /// Implements the Mapbox "polylabel" algorithm: a quadtree of square
    /// cells over the bbox, refined greedily by potential distance until the
    /// best cell's possible improvement drops below `precision`.
    public static func poleOfInaccessibility(of ring: [CBNPoint], precision: Double) -> CBNPoint {
        guard ring.count >= 3 else {
            return ring.first ?? CBNPoint(x: 0, y: 0)
        }

        let xs = ring.map(\.x)
        let ys = ring.map(\.y)
        let minX = xs.min()!
        let maxX = xs.max()!
        let minY = ys.min()!
        let maxY = ys.max()!
        let width = maxX - minX
        let height = maxY - minY

        guard width > 0, height > 0 else {
            return CBNPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        }

        let precision = max(precision, 1e-9)
        let cellSize = min(width, height)
        let h = cellSize / 2

        var queue: [Cell] = []
        var x = minX
        while x < maxX {
            var y = minY
            while y < maxY {
                queue.append(Cell(x: x + h, y: y + h, halfSize: h, ring: ring))
                y += cellSize
            }
            x += cellSize
        }

        var best = Cell(x: minX + width / 2, y: minY + height / 2, halfSize: 0, ring: ring)
        let centroid = centroidCell(of: ring)
        if centroid.distance > best.distance { best = centroid }
        for cell in queue where cell.distance > best.distance {
            best = cell
        }

        while !queue.isEmpty {
            var popIndex = 0
            for i in 1..<queue.count where queue[i].upperBound > queue[popIndex].upperBound {
                popIndex = i
            }
            let cell = queue.remove(at: popIndex)

            if cell.distance > best.distance {
                best = cell
            }

            guard cell.upperBound - best.distance > precision else { continue }

            let childHalfSize = cell.halfSize / 2
            guard childHalfSize > 0 else { continue }
            queue.append(Cell(x: cell.x - childHalfSize, y: cell.y - childHalfSize, halfSize: childHalfSize, ring: ring))
            queue.append(Cell(x: cell.x + childHalfSize, y: cell.y - childHalfSize, halfSize: childHalfSize, ring: ring))
            queue.append(Cell(x: cell.x - childHalfSize, y: cell.y + childHalfSize, halfSize: childHalfSize, ring: ring))
            queue.append(Cell(x: cell.x + childHalfSize, y: cell.y + childHalfSize, halfSize: childHalfSize, ring: ring))
        }

        return CBNPoint(x: best.x, y: best.y)
    }

    // MARK: - RDP helpers

    /// Standard open-chain RDP: `points` has fixed first/last endpoints that
    /// are always kept.
    private static func reduceChain(_ points: [CBNPoint], tolerance: Double) -> [CBNPoint] {
        guard points.count > 2 else { return points }

        let start = points[0]
        let end = points[points.count - 1]
        var maxDistance = 0.0
        var splitIndex = 0
        for i in 1..<(points.count - 1) {
            let distance = perpendicularDistance(points[i], from: start, to: end)
            if distance > maxDistance {
                maxDistance = distance
                splitIndex = i
            }
        }

        guard maxDistance > tolerance else { return [start, end] }

        let left = reduceChain(Array(points[0...splitIndex]), tolerance: tolerance)
        let right = reduceChain(Array(points[splitIndex...]), tolerance: tolerance)
        return left.dropLast() + right
    }

    /// Perpendicular distance from `point` to the infinite line through
    /// `start` and `end` (falls back to Euclidean distance to `start` if
    /// the two are coincident).
    private static func perpendicularDistance(_ point: CBNPoint, from start: CBNPoint, to end: CBNPoint) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        guard dx != 0 || dy != 0 else {
            let ddx = point.x - start.x
            let ddy = point.y - start.y
            return (ddx * ddx + ddy * ddy).squareRoot()
        }
        let numerator = abs(dy * point.x - dx * point.y + end.x * start.y - end.y * start.x)
        let denominator = (dx * dx + dy * dy).squareRoot()
        return numerator / denominator
    }

    // MARK: - polylabel helpers

    /// A square candidate cell in the polylabel quadtree search.
    private struct Cell {
        var x: Double
        var y: Double
        var halfSize: Double
        /// Signed distance from the cell center to the polygon boundary
        /// (positive when the center is inside).
        var distance: Double
        /// Upper bound on the distance any point within this cell could
        /// achieve — used to prioritize and to prune the search.
        var upperBound: Double

        init(x: Double, y: Double, halfSize: Double, ring: [CBNPoint]) {
            self.x = x
            self.y = y
            self.halfSize = halfSize
            self.distance = PolygonGeometry.signedDistance(from: CBNPoint(x: x, y: y), to: ring)
            self.upperBound = distance + halfSize * 2.0.squareRoot()
        }
    }

    private static func centroidCell(of ring: [CBNPoint]) -> Cell {
        var sumX = 0.0
        var sumY = 0.0
        for point in ring {
            sumX += point.x
            sumY += point.y
        }
        let count = Double(ring.count)
        return Cell(x: sumX / count, y: sumY / count, halfSize: 0, ring: ring)
    }

    /// Signed distance from `point` to the polygon boundary: the minimum
    /// distance to any edge segment, positive when `point` is inside.
    private static func signedDistance(from point: CBNPoint, to ring: [CBNPoint]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var minDistance = Double.greatestFiniteMagnitude
        var j = ring.count - 1
        for i in 0..<ring.count {
            let distance = pointToSegmentDistance(point, ring[j], ring[i])
            if distance < minDistance {
                minDistance = distance
            }
            j = i
        }
        return contains(point, in: ring) ? minDistance : -minDistance
    }

    private static func pointToSegmentDistance(_ point: CBNPoint, _ a: CBNPoint, _ b: CBNPoint) -> Double {
        var dx = b.x - a.x
        var dy = b.y - a.y
        if dx != 0 || dy != 0 {
            let t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / (dx * dx + dy * dy)
            if t > 1 {
                dx = point.x - b.x
                dy = point.y - b.y
            } else if t > 0 {
                dx = point.x - (a.x + dx * t)
                dy = point.y - (a.y + dy * t)
            } else {
                dx = point.x - a.x
                dy = point.y - a.y
            }
        } else {
            dx = point.x - a.x
            dy = point.y - a.y
        }
        return (dx * dx + dy * dy).squareRoot()
    }
}
