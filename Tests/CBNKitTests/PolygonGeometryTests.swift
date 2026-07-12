import Foundation
import Testing
@testable import CBNKit

// MARK: - Test fixtures

/// A 10x10 axis-aligned square, CCW in a y-up frame.
private let unitSquareCCW = [
    CBNPoint(x: 0, y: 0),
    CBNPoint(x: 10, y: 0),
    CBNPoint(x: 10, y: 10),
    CBNPoint(x: 0, y: 10),
]

private let unitSquareCW = Array(unitSquareCCW.reversed())

/// Same square as `unitSquareCCW` but with an extra, exactly collinear
/// midpoint inserted on every edge.
private let squareWithMidpoints = [
    CBNPoint(x: 0, y: 0),
    CBNPoint(x: 5, y: 0),
    CBNPoint(x: 10, y: 0),
    CBNPoint(x: 10, y: 5),
    CBNPoint(x: 10, y: 10),
    CBNPoint(x: 5, y: 10),
    CBNPoint(x: 0, y: 10),
    CBNPoint(x: 0, y: 5),
]

/// An L-shape made of two thin (width-1) bars: a bottom bar spanning
/// x:0-4, y:0-1 and a left bar spanning x:0-1, y:0-4. Its bounding-box
/// center (2, 2) — and even the plain vertex-average centroid — fall
/// squarely in the missing notch (x:1-4, y:1-4), i.e. outside the polygon.
private let lShape = [
    CBNPoint(x: 0, y: 0),
    CBNPoint(x: 4, y: 0),
    CBNPoint(x: 4, y: 1),
    CBNPoint(x: 1, y: 1),
    CBNPoint(x: 1, y: 4),
    CBNPoint(x: 0, y: 4),
]

/// Many-point approximation of a circle of the given radius, centered at
/// the origin.
private func circlePoints(radius: Double, count: Int) -> [CBNPoint] {
    (0..<count).map { i in
        let angle = 2 * Double.pi * Double(i) / Double(count)
        return CBNPoint(x: radius * cos(angle), y: radius * sin(angle))
    }
}

// MARK: - Local geometry helpers (kept separate from PolygonGeometry's
// private implementation so the tests exercise only the public API)

private func distance(_ a: CBNPoint, _ b: CBNPoint) -> Double {
    let dx = a.x - b.x
    let dy = a.y - b.y
    return (dx * dx + dy * dy).squareRoot()
}

private func pointToSegmentDistance(_ point: CBNPoint, _ a: CBNPoint, _ b: CBNPoint) -> Double {
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

/// Minimum unsigned distance from `point` to any edge of the closed `ring`.
private func minDistanceToEdges(_ point: CBNPoint, _ ring: [CBNPoint]) -> Double {
    var minDistance = Double.greatestFiniteMagnitude
    var j = ring.count - 1
    for i in 0..<ring.count {
        minDistance = min(minDistance, pointToSegmentDistance(point, ring[j], ring[i]))
        j = i
    }
    return minDistance
}

/// Signed distance (positive inside) computed independently of
/// PolygonGeometry's private implementation, using only its public
/// `contains(_:in:)`.
private func signedDistance(_ point: CBNPoint, _ ring: [CBNPoint]) -> Double {
    let unsigned = minDistanceToEdges(point, ring)
    return PolygonGeometry.contains(point, in: ring) ? unsigned : -unsigned
}

private func sortedByCoordinate(_ points: [CBNPoint]) -> [CBNPoint] {
    points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
}

// MARK: - signedArea

@Test func signedAreaOfCCWSquareIsPositive() {
    #expect(abs(PolygonGeometry.signedArea(of: unitSquareCCW) - 100) < 0.0001)
}

@Test func signedAreaOfCWSquareIsNegative() {
    #expect(abs(PolygonGeometry.signedArea(of: unitSquareCW) - (-100)) < 0.0001)
}

@Test func signedAreaOfDegenerateRingIsZero() {
    #expect(PolygonGeometry.signedArea(of: []) == 0)
    #expect(PolygonGeometry.signedArea(of: [CBNPoint(x: 0, y: 0)]) == 0)
    #expect(PolygonGeometry.signedArea(of: [CBNPoint(x: 0, y: 0), CBNPoint(x: 1, y: 1)]) == 0)
}

// MARK: - contains

@Test func containsFindsPointInsideSquare() {
    #expect(PolygonGeometry.contains(CBNPoint(x: 5, y: 5), in: unitSquareCCW))
}

@Test func containsRejectsPointOutsideSquare() {
    #expect(!PolygonGeometry.contains(CBNPoint(x: 15, y: 5), in: unitSquareCCW))
}

@Test func containsRejectsPointFarOutside() {
    #expect(!PolygonGeometry.contains(CBNPoint(x: 1000, y: -1000), in: unitSquareCCW))
}

@Test func containsHandlesConcaveLShapeWhereBoundingBoxCenterIsOutside() {
    let bboxCenter = CBNPoint(x: 2, y: 2) // bbox is x:0-4, y:0-4
    #expect(!PolygonGeometry.contains(bboxCenter, in: lShape))
    // Sanity: points actually within the two bars are inside.
    #expect(PolygonGeometry.contains(CBNPoint(x: 0.5, y: 0.5), in: lShape))
    #expect(PolygonGeometry.contains(CBNPoint(x: 3, y: 0.5), in: lShape))
    #expect(PolygonGeometry.contains(CBNPoint(x: 0.5, y: 3), in: lShape))
}

@Test func containsOnDegenerateRingIsFalse() {
    #expect(!PolygonGeometry.contains(CBNPoint(x: 0, y: 0), in: [CBNPoint(x: 0, y: 0), CBNPoint(x: 1, y: 1)]))
}

// MARK: - simplify

@Test func simplifySquareWithCollinearMidpointsReducesToFourCorners() {
    let simplified = PolygonGeometry.simplify(squareWithMidpoints, tolerance: 0.01)
    #expect(simplified.count == 4)
    #expect(sortedByCoordinate(simplified) == sortedByCoordinate(unitSquareCCW))
}

@Test func simplifyWithZeroToleranceKeepsNonCollinearVertices() {
    // An irregular pentagon; no three vertices are collinear.
    let pentagon = [
        CBNPoint(x: 0, y: 0),
        CBNPoint(x: 4, y: 1),
        CBNPoint(x: 5, y: 4),
        CBNPoint(x: 2, y: 6),
        CBNPoint(x: -1, y: 3),
    ]
    let simplified = PolygonGeometry.simplify(pentagon, tolerance: 0)
    #expect(simplified.count == pentagon.count)
}

@Test func simplifyCircleReducesPointCountAndStaysWithinTolerance() {
    let circle = circlePoints(radius: 50, count: 72)
    let tolerance = 1.0
    let simplified = PolygonGeometry.simplify(circle, tolerance: tolerance)

    #expect(simplified.count < circle.count)
    #expect(simplified.count >= 3)

    // Every original vertex should still be well-approximated by the
    // simplified ring (checked against a sample to keep the test cheap).
    let epsilon = 1e-6
    for i in stride(from: 0, to: circle.count, by: 7) {
        let original = circle[i]
        var minDistanceToSimplified = Double.greatestFiniteMagnitude
        var j = simplified.count - 1
        for k in 0..<simplified.count {
            minDistanceToSimplified = min(
                minDistanceToSimplified,
                pointToSegmentDistance(original, simplified[j], simplified[k])
            )
            j = k
        }
        #expect(minDistanceToSimplified <= tolerance + epsilon)
    }
}

@Test func simplifyNeverReturnsFewerThanThreePoints() {
    // A near-degenerate ring: essentially a thin sliver where every
    // interior point is close to collinear with the two farthest-apart
    // vertices.
    let sliver = [
        CBNPoint(x: 0, y: 0),
        CBNPoint(x: 1, y: 0.001),
        CBNPoint(x: 5, y: 0),
        CBNPoint(x: 10, y: 0.001),
    ]
    let simplified = PolygonGeometry.simplify(sliver, tolerance: 1000)
    #expect(simplified.count >= 3)
}

@Test func simplifyOfDegenerateRingReturnsInputUnchanged() {
    let tooShort = [CBNPoint(x: 0, y: 0), CBNPoint(x: 1, y: 1)]
    #expect(PolygonGeometry.simplify(tooShort, tolerance: 5) == tooShort)
    #expect(PolygonGeometry.simplify([], tolerance: 5) == [])
    let triangle = [CBNPoint(x: 0, y: 0), CBNPoint(x: 1, y: 0), CBNPoint(x: 0, y: 1)]
    #expect(PolygonGeometry.simplify(triangle, tolerance: 1000) == triangle)
}

// MARK: - poleOfInaccessibility

@Test func poleOfInaccessibilityOfSquareIsNearCenter() {
    let precision = 0.5
    let pole = PolygonGeometry.poleOfInaccessibility(of: unitSquareCCW, precision: precision)
    #expect(distance(pole, CBNPoint(x: 5, y: 5)) <= precision * 2)
}

@Test func poleOfInaccessibilityOfLShapeIsInsideAndBeatsNaiveCentroid() {
    let precision = 0.1
    let pole = PolygonGeometry.poleOfInaccessibility(of: lShape, precision: precision)

    // The property that actually matters: unlike the bbox center (or a
    // plain vertex-average centroid), the pole must land inside the shape.
    #expect(PolygonGeometry.contains(pole, in: lShape))

    let vertexAverageCentroid = CBNPoint(
        x: lShape.map(\.x).reduce(0, +) / Double(lShape.count),
        y: lShape.map(\.y).reduce(0, +) / Double(lShape.count)
    )
    #expect(!PolygonGeometry.contains(vertexAverageCentroid, in: lShape))

    // The pole's signed distance to the boundary (positive, since it's
    // interior) must exceed the naive centroid's (negative, since it's
    // outside) — i.e. the pole is a strictly better label position.
    #expect(signedDistance(pole, lShape) > signedDistance(vertexAverageCentroid, lShape))

    // Each bar is 1 unit wide, so the true inradius is 0.5; the pole
    // should get reasonably close to that optimum.
    #expect(signedDistance(pole, lShape) > 0.3)
}

@Test func poleOfInaccessibilityOfDegenerateRingReturnsSafeValue() {
    #expect(PolygonGeometry.poleOfInaccessibility(of: [], precision: 1) == CBNPoint(x: 0, y: 0))
    let single = [CBNPoint(x: 3, y: 4)]
    #expect(PolygonGeometry.poleOfInaccessibility(of: single, precision: 1) == CBNPoint(x: 3, y: 4))
}
