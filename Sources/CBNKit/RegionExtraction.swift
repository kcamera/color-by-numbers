import Foundation

/// A labeled map of contiguous same-color regions, after merging away
/// regions too small to color. The bridge between "quantized pixels" and
/// "vector template".
public struct RegionMap: Sendable {
    public var width: Int
    public var height: Int
    /// Region id per pixel, row-major, ids dense in 0..<regionCount.
    public var regionIDs: [Int]
    public var regionCount: Int
    /// Palette index for each region id.
    public var regionColors: [Int]
    /// Pixel count for each region id.
    public var regionAreas: [Int]
}

public enum RegionExtractor {
    /// Two-pass connected-component labeling with union-find,
    /// 4-connectivity. 4 rather than 8 so that regions touching only at a
    /// corner stay separate — diagonal "leaks" produce untraceable
    /// boundaries.
    public static func extractRegions(from quantized: QuantizedImage) -> RegionMap {
        let width = quantized.width
        let height = quantized.height
        let labels = quantized.labels

        var parent = [Int](0..<(width * height))

        func find(_ i: Int) -> Int {
            var root = i
            while parent[root] != root { root = parent[root] }
            // Path compression.
            var current = i
            while parent[current] != root {
                let next = parent[current]
                parent[current] = root
                current = next
            }
            return root
        }
        func union(_ a: Int, _ b: Int) {
            let rootA = find(a)
            let rootB = find(b)
            if rootA != rootB { parent[max(rootA, rootB)] = min(rootA, rootB) }
        }

        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                if x > 0, labels[i] == labels[i - 1] { union(i, i - 1) }
                if y > 0, labels[i] == labels[i - width] { union(i, i - width) }
            }
        }

        // Densify root ids into 0..<count.
        var rootToRegion = [Int: Int]()
        var regionIDs = [Int](repeating: 0, count: width * height)
        var regionColors = [Int]()
        var regionAreas = [Int]()
        for i in 0..<(width * height) {
            let root = find(i)
            if let region = rootToRegion[root] {
                regionIDs[i] = region
                regionAreas[region] += 1
            } else {
                let region = regionColors.count
                rootToRegion[root] = region
                regionIDs[i] = region
                regionColors.append(labels[i])
                regionAreas.append(1)
            }
        }

        return RegionMap(
            width: width,
            height: height,
            regionIDs: regionIDs,
            regionCount: regionColors.count,
            regionColors: regionColors,
            regionAreas: regionAreas
        )
    }

    /// Absorbs every region smaller than `minArea` pixels into whichever
    /// neighbor shares the longest border with it. This is what removes
    /// anti-aliasing halo slivers and unpaintable specks — a region too
    /// small for a small finger is a pipeline bug, not a user error
    /// (docs/DESIGN.md).
    ///
    /// Iterates smallest-first until stable, so chains of slivers collapse
    /// into their true parent instead of into each other.
    public static func mergeSmallRegions(in map: RegionMap, minArea: Int) -> RegionMap {
        var map = map
        // Bounded loop: every pass either merges something (reducing the
        // small-region count) or stops. The bound is defensive only.
        for _ in 0..<64 {
            let small = (0..<map.regionCount)
                .filter { map.regionAreas[$0] < minArea }
                .sorted { map.regionAreas[$0] < map.regionAreas[$1] }
            guard !small.isEmpty, map.regionCount > 1 else { break }

            // Shared-border lengths between adjacent region pairs.
            var borders = [Int: [Int: Int]]() // region → neighbor → length
            let width = map.width
            for y in 0..<map.height {
                for x in 0..<width {
                    let i = y * width + x
                    let a = map.regionIDs[i]
                    if x + 1 < width {
                        let b = map.regionIDs[i + 1]
                        if a != b {
                            borders[a, default: [:]][b, default: 0] += 1
                            borders[b, default: [:]][a, default: 0] += 1
                        }
                    }
                    if y + 1 < map.height {
                        let b = map.regionIDs[i + width]
                        if a != b {
                            borders[a, default: [:]][b, default: 0] += 1
                            borders[b, default: [:]][a, default: 0] += 1
                        }
                    }
                }
            }

            var remap = [Int](0..<map.regionCount)
            func resolve(_ r: Int) -> Int {
                var current = r
                while remap[current] != current { current = remap[current] }
                return current
            }

            var mergedAny = false
            for region in small {
                guard resolve(region) == region else { continue } // already absorbed
                guard let neighbors = borders[region], !neighbors.isEmpty else { continue }
                // Longest shared border wins; resolve through this pass's
                // earlier merges so we attach to the surviving region.
                let target = neighbors.max {
                    $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
                }!.key
                let survivor = resolve(target)
                guard survivor != region else { continue }
                remap[region] = survivor
                mergedAny = true
            }
            guard mergedAny else { break }

            // Rebuild dense ids after this round of merges.
            var oldToNew = [Int: Int]()
            var newColors = [Int]()
            var newAreas = [Int]()
            var newIDs = [Int](repeating: 0, count: map.regionIDs.count)
            for i in 0..<map.regionIDs.count {
                let old = resolve(map.regionIDs[i])
                if let new = oldToNew[old] {
                    newIDs[i] = new
                    newAreas[new] += 1
                } else {
                    let new = newColors.count
                    oldToNew[old] = new
                    newIDs[i] = new
                    newColors.append(map.regionColors[old])
                    newAreas.append(1)
                }
            }
            map = RegionMap(
                width: map.width,
                height: map.height,
                regionIDs: newIDs,
                regionCount: newColors.count,
                regionColors: newColors,
                regionAreas: newAreas
            )
        }
        return map
    }

    /// Pixel bounding box per region id, computed in one pass. Used to keep
    /// per-region hole extraction local instead of image-sized.
    public static func boundingBoxes(
        in map: RegionMap
    ) -> [(minX: Int, minY: Int, maxX: Int, maxY: Int)] {
        var boxes = [(minX: Int, minY: Int, maxX: Int, maxY: Int)](
            repeating: (Int.max, Int.max, Int.min, Int.min),
            count: map.regionCount
        )
        for y in 0..<map.height {
            let rowBase = y * map.width
            for x in 0..<map.width {
                let region = map.regionIDs[rowBase + x]
                if x < boxes[region].minX { boxes[region].minX = x }
                if y < boxes[region].minY { boxes[region].minY = y }
                if x > boxes[region].maxX { boxes[region].maxX = x }
                if y > boxes[region].maxY { boxes[region].maxY = y }
            }
        }
        return boxes
    }

    /// A representative "safe to label" point per region — the pixel
    /// farthest (by 4-connected BFS distance) from any other region's
    /// pixels or the image edge, indexed by region id.
    ///
    /// This is deliberately computed from the pixel mask, not from a
    /// region's traced polygons: a ring-shaped region's *outer* path looks
    /// like a full disk, and placing a label via that disk's pole of
    /// inaccessibility puts every concentric ring's number at the same
    /// shared center. The pixel mask has no such ambiguity — a hole is
    /// just pixels belonging to a different region — so this handles
    /// rings, nested shapes, and stroke-like outline meshes with no
    /// special-casing (and no dependence on how boundaries get traced).
    public static func labelPoints(for map: RegionMap) -> [CBNPoint] {
        let width = map.width
        let height = map.height
        let ids = map.regionIDs
        let pixelCount = width * height

        // Multi-source BFS: every pixel touching a differently-labeled
        // neighbor, or the image edge, starts at distance 0. One pass
        // computes "distance from this pixel's own region boundary" for
        // every pixel in the image at once.
        var distance = [Int](repeating: -1, count: pixelCount)
        var queue: [Int] = []
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let id = ids[i]
                let onEdge = x == 0 || y == 0 || x == width - 1 || y == height - 1
                let touchesOther = !onEdge && (
                    ids[i - 1] != id || ids[i + 1] != id
                        || ids[i - width] != id || ids[i + width] != id
                )
                if onEdge || touchesOther {
                    distance[i] = 0
                    queue.append(i)
                }
            }
        }

        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            let x = i % width, y = i / width
            let next = distance[i] + 1
            if x > 0, distance[i - 1] == -1 { distance[i - 1] = next; queue.append(i - 1) }
            if x < width - 1, distance[i + 1] == -1 { distance[i + 1] = next; queue.append(i + 1) }
            if y > 0, distance[i - width] == -1 { distance[i - width] = next; queue.append(i - width) }
            if y < height - 1, distance[i + width] == -1 { distance[i + width] = next; queue.append(i + width) }
        }

        var bestIndex = [Int](repeating: -1, count: map.regionCount)
        var bestDistance = [Int](repeating: -1, count: map.regionCount)
        for i in 0..<pixelCount {
            let region = ids[i]
            if distance[i] > bestDistance[region] {
                bestDistance[region] = distance[i]
                bestIndex[region] = i
            }
        }

        return (0..<map.regionCount).map { region in
            let i = bestIndex[region] // always set: every region has ≥1 pixel
            return CBNPoint(x: Double(i % width), y: Double(i / width))
        }
    }
}
